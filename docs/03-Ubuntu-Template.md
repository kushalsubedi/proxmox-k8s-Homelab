# 03 — Building the Ubuntu 26.04 VM Template

## Overview

Rather than manually installing Ubuntu Server three separate times (once each for `master`, `worker1`, `worker2`), this homelab builds **one cloud-init-enabled VM template** and clones it three times in [04-Cloning-VMs.md](04-Cloning-VMs.md). This is the standard Proxmox pattern for fleets of similar VMs and saves significant time while guaranteeing all three nodes start from an identical baseline.

---

## Why a Template?

| Approach | Time per node | Consistency | Repeatability |
|---|---|---|---|
| Manual install × 3 | ~20 min each | Manual drift likely | Must repeat every step per node |
| Template + clone × 3 | ~2 min each after template is built | Identical baseline guaranteed | Cloning is instant and scriptable |

A template also means that if a node is ever corrupted or you want a fourth worker later, you clone again in under a minute rather than repeating the OS install.

---

## Step 1: Download the Ubuntu Server 26.04 Cloud Image

Proxmox templates for cloud-init are typically built from Ubuntu's **cloud image** (a minimal, pre-configured `.img` file), not the interactive server ISO — cloud images are designed specifically to be customized at boot time via cloud-init, which is what lets us inject hostname, IP, and SSH keys automatically during cloning.

```bash
# On the Proxmox host
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img
```

## Step 2: Create the Base VM

```bash
qm create 9000 \
  --name ubuntu-26-04-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --ostype l26 \
  --agent enabled=1
```

| Flag | Explanation |
|---|---|
| `9000` | VM ID reserved by convention for templates (VM IDs 100+ are used for actual clones) |
| `--memory 2048` | 2 GB RAM — matches the eventual per-node spec |
| `--cores 2` | 2 vCPU — matches the eventual per-node spec |
| `--net0 virtio,bridge=vmbr0` | **VirtIO** network device attached to the isolated `vmbr0` bridge from [02-Proxmox-Networking.md](02-Proxmox-Networking.md). VirtIO is a paravirtualized driver that is dramatically faster than emulated NICs (`e1000`, `rtl8139`) because it avoids emulating real hardware timing/interrupt behavior — critical when 3 VMs share 4 physical cores. |
| `--scsihw virtio-scsi-pci` | VirtIO SCSI controller — same paravirtualization benefit applied to disk I/O. |
| `--ostype l26` | Tells Proxmox this is a Linux 2.6+ kernel guest, which tunes some QEMU defaults appropriately. |
| `--agent enabled=1` | Enables the QEMU Guest Agent, which lets Proxmox query the VM's actual IP address, trigger clean shutdowns, and fs-freeze during snapshots — install the agent package inside the guest in Step 5. |

## Step 3: Attach the Cloud Image as the Boot Disk

```bash
qm importdisk 9000 ubuntu-26.04-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --boot order=scsi0
qm set 9000 --serial0 socket --vga serial0
```

`qm importdisk` converts the cloud image into a Proxmox-managed disk and attaches it. The `--serial0 socket --vga serial0` pair configures a serial console — cloud images boot without a traditional VGA display by default, so this ensures you can still view console output through the Proxmox Web UI if needed.

## Step 4: Add a Cloud-Init Drive and Resize the Disk

```bash
qm set 9000 --ide2 local-lvm:cloudinit
qm resize 9000 scsi0 35G
```

The cloud-init drive is a small virtual CD-ROM that Proxmox populates at boot time with a generated `user-data`/`meta-data`/`network-config` set, based on values you configure per-clone (hostname, IP, SSH key) in [04-Cloning-VMs.md](04-Cloning-VMs.md). Resizing the disk to **35 GB** here matches the target spec for all three cluster nodes.

## Step 5: Set Cloud-Init Defaults

```bash
qm set 9000 --ciuser vm1
qm set 9000 --sshkeys ~/.ssh/id_ed25519.pub
qm set 9000 --ipconfig0 ip=dhcp
```

These are **template-level defaults** — every clone inherits them unless overridden. `vm1` is the default administrative user created on first boot (matching the `User vm1` entries used later in [05-SSH.md](05-SSH.md)). The SSH public key is injected automatically so that password-based SSH is never required. `ipconfig0=dhcp` is a safe template default; each clone will override this with a static `10.10.10.x` address as covered in [04-Cloning-VMs.md](04-Cloning-VMs.md).

## Step 6: Convert to a Template

```bash
qm template 9000
```

**Expected result:** VM 9000 now appears in the Proxmox Web UI with a distinct template icon, and its disk becomes read-only — Proxmox uses linked clones by default from this point forward, meaning each cloned VM only stores the *differences* from the template, saving disk space.

---

## Verification

```bash
qm config 9000
```

Confirm the output shows:
- `scsi0` pointing at a `local-lvm` disk with `size=35G`
- `net0: virtio,bridge=vmbr0`
- `ide2` present as the cloud-init drive
- `agent: enabled=1`

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Using `e1000` instead of `virtio` for `--net0` | Noticeably slower network throughput, higher CPU usage per packet | Recreate the NIC as `virtio` (`qm set 9000 --net0 virtio,bridge=vmbr0`) |
| Skipping `qm template 9000` | Proxmox treats VM 9000 as a normal VM; cloning it makes full copies instead of efficient linked clones | Run `qm template 9000` once the base VM is fully configured |
| Forgetting to resize the disk before templating | All clones inherit the small cloud-image default size (often 2–3 GB) | Resize before converting to a template, or resize each clone individually afterward |

---

## Troubleshooting

**Symptom: VM console shows nothing / stays black.**
Cloud images boot in serial console mode by default. Confirm `--serial0 socket --vga serial0` was set, and view the console via the Proxmox Web UI's "Console" tab, which will render the serial output correctly.

**Symptom: Cloud-init doesn't seem to apply hostname/IP/SSH key on clone.**
Confirm the `ide2` cloud-init drive exists (`qm config <vmid> | grep ide2`). If it's missing, cloud-init has nothing to read at boot and the guest falls back to whatever was baked into the original cloud image.

---

## Recovery

If the template becomes corrupted or misconfigured, it's generally faster to delete and rebuild than to debug a template in place, since no VM data lives on it long-term:

```bash
qm destroy 9000
# then repeat Steps 1–6
```

---

## Best Practices

- Keep template VM IDs in a distinct, documented range (e.g. `9000`–`9999`) so they're never confused with running cluster nodes.
- Re-run this process whenever a new Ubuntu point release ships, so future clones start from a current, patched baseline.

## Performance Tips

- Always prefer VirtIO devices (network and SCSI) over emulated hardware for both disk and network — this is the single highest-impact performance decision available on constrained hardware.
- Linked clones (the default after `qm template`) are also a performance win: less disk I/O and less SSD wear versus full clones.

## Security Tips

- Bake only a public SSH key into the template — never a private key.
- Avoid setting a cloud-init password (`--cipassword`) on the template at all; rely exclusively on SSH key authentication, matching the ProxyJump-based access model in [05-SSH.md](05-SSH.md).

---

**Next:** [04-Cloning-VMs.md](04-Cloning-VMs.md) — cloning `master`, `worker1`, and `worker2` from this template.
