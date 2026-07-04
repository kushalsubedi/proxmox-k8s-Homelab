# 11 — Network Storage with Samba

## Overview

This document configures the Proxmox host's 1 TB HDD (`/dev/sdb2`, NTFS) as persistent, reboot-safe network storage, shared via Samba (SMB) so it's accessible directly from macOS Finder — including Time Machine backup support. This is independent of the Kubernetes cluster; it uses the Proxmox host's own storage and network stack directly, not a Kubernetes `PersistentVolume` (that integration is a future roadmap item — see [15-Roadmap.md](15-Roadmap.md)).

---

## Why Samba (Not NFS) Here

| Consideration | Samba (SMB3) | NFS |
|---|---|---|
| macOS Finder integration | Native, first-class ("Connect to Server", mounts in Finder sidebar) | Supported but less integrated; no native Finder browsing UI |
| Time Machine support | Explicit, well-supported via `vfs_fruit` | Not supported for Time Machine at all |
| Windows/Linux client support | Excellent (SMB is the universal standard) | Excellent on Linux, requires extra tooling on Windows |
| NTFS filesystem underneath | Natural fit — Samba serves NTFS ACLs/permissions reasonably well via `ntfs-3g` | Less natural fit; NFS's permission model doesn't map as cleanly onto NTFS |

Since the primary client for this share is macOS, and the underlying filesystem is NTFS (a legacy choice carried over from the drive's prior use outside this homelab), Samba is the clear fit.

---

## Step 1: Mount the NTFS Partition on the Proxmox Host

```bash
apt install -y ntfs-3g
mkdir -p /mnt/storage
```

Identify the exact filesystem UUID (more reliable than the device name, which can shift if drives are added/removed):

```bash
blkid /dev/sdb2
```

**Example output:**

```
/dev/sdb2: UUID="A2B4C6D8E0F2..." TYPE="ntfs"
```

## Step 2: Configure `/etc/fstab` for a Persistent, Reboot-Safe Mount

```bash
cat <<EOF >> /etc/fstab
UUID=A2B4C6D8E0F2  /mnt/storage  ntfs-3g  defaults,uid=root,gid=root,umask=002,windows_names,nofail  0  0
EOF
```

| Option | Explanation |
|---|---|
| `UUID=...` | Mounts by filesystem UUID rather than `/dev/sdb2` directly — device names can change across reboots if drive enumeration order shifts (e.g. after adding another disk), while the UUID never does. |
| `uid=root,gid=root` | Sets the ownership NTFS-mounted files present as, since NTFS itself has no native Unix permission concept — `ntfs-3g` translates this via mount options. |
| `umask=002` | Grants group read/write by default, needed so the `smbd` process (running under a Samba-specific context) can read and write files without requiring world-writable permissions. |
| `windows_names` | Rejects filenames that are valid on Linux but invalid on Windows/NTFS (e.g. trailing spaces, reserved characters), preventing files created from a Linux-side process from silently becoming inaccessible from Windows/macOS SMB clients. |
| `nofail` | **Critical for a homelab:** if this drive is ever disconnected, absent, or fails to mount for any reason, `nofail` ensures the system still boots normally rather than dropping to an emergency shell waiting for the mount to succeed. |

Apply and verify without rebooting:

```bash
mount -a
mount | grep /mnt/storage
```

**Expected output:** a line showing `/dev/sdb2 on /mnt/storage type fuseblk (rw,...)`.

## Step 3: Install and Configure Samba

```bash
apt install -y samba
```

Edit `/etc/samba/smb.conf`, adding a dedicated share definition:

```ini
[global]
   workgroup = WORKGROUP
   server string = Proxmox Homelab Storage
   security = user
   map to guest = never

   # macOS/Time Machine compatibility
   vfs objects = catia fruit streams_xattr
   fruit:aapl = yes
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no

[storage]
   comment = Homelab 1TB Network Storage
   path = /mnt/storage
   browsable = yes
   read only = no
   guest ok = no
   valid users = @smbusers
   create mask = 0664
   directory mask = 0775

   # Recycle Bin support
   vfs objects = recycle catia fruit streams_xattr
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:touch = yes
   recycle:maxsize = 0

[timemachine]
   comment = Time Machine Backup
   path = /mnt/storage/timemachine
   browsable = yes
   read only = no
   guest ok = no
   valid users = @smbusers
   fruit:time machine = yes
   fruit:time machine max size = 500G
```

| Section/Key | Explanation |
|---|---|
| `security = user` | Requires authenticated Samba users (created in Step 4) rather than anonymous/guest access — appropriate even on a private LAN, since the share holds real personal data. |
| `vfs objects = ... fruit ...` | The `fruit` VFS module implements Apple's SMB extensions (AAPL), which is what makes the share behave correctly in Finder (correct icons, resource forks, `.DS_Store` handling) rather than looking like a generic, slightly-broken Windows share. |
| `[storage]` → `recycle:*` | Implements a Recycle Bin: deleted files move to a hidden `.recycle/<username>/` folder instead of being immediately destroyed, giving you a safety net against accidental deletion over the network. |
| `[timemachine]` → `fruit:time machine = yes` | Advertises this specific share as a valid Time Machine destination to macOS — without this flag, macOS's Time Machine preference pane won't offer the share as a backup destination at all, even though it's a perfectly normal writable SMB share otherwise. |

Create the Time Machine subdirectory and the Samba user group:

```bash
mkdir -p /mnt/storage/timemachine
groupadd smbusers
usermod -aG smbusers <your-linux-username>
```

## Step 4: Create Samba Users

```bash
smbpasswd -a <your-linux-username>
systemctl restart smbd nmbd
systemctl enable smbd nmbd
```

`smbpasswd -a` creates a **Samba-specific** password, distinct from the Linux account's login password — Samba maintains its own credential database (`/var/lib/samba/private/passdb.tdb`) because SMB's authentication protocol needs the password (or a derived hash of it) in a specific format the standard Linux `/etc/shadow` hash isn't compatible with.

## Step 5: Connect from macOS

In Finder: **Go → Connect to Server** (`⌘K`), then:

```
smb://192.168.1.20/storage
```

Enter the Samba username/password created in Step 4. **Expected result:** the share mounts and appears in Finder's sidebar under "Locations."

For Time Machine: **System Settings → General → Time Machine → Add Backup Disk**, select the `timemachine` share.

---

## Verification

```bash
# On the Proxmox host
systemctl status smbd nmbd
testparm                       # validates smb.conf syntax
smbclient -L localhost -U <your-linux-username>
```

**Expected output of `testparm`:** no syntax errors, and a printed summary of all configured shares (`[storage]`, `[timemachine]`).

From macOS:

```bash
ls -la /Volumes/storage
```

**Expected:** the mounted share's contents are listed.

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Mounting `/dev/sdb2` directly in `/etc/fstab` instead of by `UUID` | Mount silently targets the wrong device if disk enumeration order changes | Always mount by `UUID` as shown in Step 2 |
| Omitting `nofail` in the fstab entry | If the drive is ever missing, the whole Proxmox host fails to boot normally | Always include `nofail` for any non-critical, secondary storage mount |
| Forgetting `fruit:time machine = yes` | macOS won't offer the share as a Time Machine destination even though it works fine as regular file storage | Add the flag explicitly to the `[timemachine]` share stanza |
| Using the same Linux login password for `smbpasswd -a` and assuming they'll always match | Confusing if you later change your Linux password and SMB access silently keeps working with the old one (they're independent) | Treat Samba credentials as a separate credential to manage/rotate |

---

## Troubleshooting

**Symptom: Samba share doesn't reappear after a Proxmox host reboot.**
Check `mount | grep /mnt/storage` first — if the underlying filesystem mount itself didn't come up (check `nofail` didn't mask a real failure by hiding it), Samba has nothing to share. Then check `systemctl status smbd nmbd` to confirm the Samba daemons themselves started.

**Symptom: Mac cannot see or reach the share at all.**
Since the Proxmox host and the Mac are both on the `192.168.1.0/24` home network (not the isolated `10.10.10.0/24` lab bridge), this is not a NAT/routing issue like VM connectivity — check basic reachability first: `ping 192.168.1.20` from the Mac. If that fails, the issue is Wi-Fi/home-network level, unrelated to Samba configuration.

**Symptom: Time Machine shows the share but backup fails partway through.**
Check available free space on `/mnt/storage` and confirm `fruit:time machine max size` isn't set below what's actually needed for your Mac's data volume.

---

## Recovery

```bash
# Reset Samba configuration to a known-good state
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
testparm -s /etc/samba/smb.conf   # inspect for the specific syntax error
systemctl restart smbd nmbd
```

[scripts/mount-storage.sh](../scripts/mount-storage.sh) automates the mount + Samba install + share configuration from a clean state.

---

## Best Practices

- Keep a `.bak` copy of `smb.conf` before any manual edit — a single syntax error in this file prevents `smbd` from starting at all.
- Periodically empty the `.recycle/` directories created by the Recycle Bin `vfs object` — they are not automatically pruned and will otherwise silently consume the full 1 TB over time.

## Performance Tips

- NTFS via `ntfs-3g` (FUSE-based) has meaningfully more CPU overhead per I/O operation than a native Linux filesystem — acceptable for a homelab media/backup share, but a reason to plan a migration to `ext4` or a Kubernetes-native storage layer like Longhorn (see [15-Roadmap.md](15-Roadmap.md)) if this ever needs to serve latency-sensitive workloads.

## Security Tips

- `security = user` with `map to guest = never` ensures no anonymous access is possible — verify this explicitly with `smbclient -L 192.168.1.20 -N` (the `-N` flag attempts anonymous/no-password listing) and confirm it's rejected.
- Since this share is only reachable on the home network (not exposed to the internet, and not on the isolated lab bridge either), its primary exposure surface is anyone else already on your home WiFi — set a WiFi password you trust accordingly.

---

**Next:** [12-Mac-Kubectl.md](12-Mac-Kubectl.md) — configuring `kubectl` on macOS to manage the cluster remotely.
