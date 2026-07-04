#!/usr/bin/env bash
#
# mount-storage.sh
#
# Mounts the 1TB NTFS HDD persistently via /etc/fstab and configures Samba
# to share it, with Recycle Bin and Time Machine support for macOS clients.
#
# Run this on the PROXMOX HOST (not inside a VM).
#
# Reference: docs/11-Samba.md
#
# Usage:
#   sudo ./mount-storage.sh /dev/sdb2 <smb-username>
#
# Example:
#   sudo ./mount-storage.sh /dev/sdb2 kushal

set -euo pipefail

MOUNT_POINT="/mnt/storage"
TIMEMACHINE_DIR="${MOUNT_POINT}/timemachine"
SMB_CONF="/etc/samba/smb.conf"
SMB_GROUP="smbusers"

log() {
    echo -e "\033[1;32m[mount-storage]\033[0m $1"
}

fail() {
    echo -e "\033[1;31m[mount-storage] ERROR:\033[0m $1" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)."
fi

if [[ $# -lt 2 ]]; then
    fail "Usage: $0 <device, e.g. /dev/sdb2> <smb-username>"
fi

DEVICE="$1"
SMB_USER="$2"

if [[ ! -b "$DEVICE" ]]; then
    fail "Device '$DEVICE' does not exist or is not a block device."
fi

# ---------------------------------------------------------------------------
# Step 1: Install ntfs-3g and create the mount point
# ---------------------------------------------------------------------------
log "Step 1/6: Installing ntfs-3g and creating mount point..."
apt-get update -qq
apt-get install -y -qq ntfs-3g samba
mkdir -p "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# Step 2: Identify the filesystem UUID and configure /etc/fstab
# ---------------------------------------------------------------------------
log "Step 2/6: Resolving UUID for ${DEVICE}..."
UUID=$(blkid -s UUID -o value "$DEVICE") || fail "Could not determine UUID for $DEVICE"
log "  -> UUID: ${UUID}"

FSTAB_ENTRY="UUID=${UUID}  ${MOUNT_POINT}  ntfs-3g  defaults,uid=root,gid=root,umask=002,windows_names,nofail  0  0"

if grep -q "$UUID" /etc/fstab; then
    log "  -> fstab entry for this UUID already exists, skipping append"
else
    echo "$FSTAB_ENTRY" >> /etc/fstab
    log "  -> Added fstab entry: $FSTAB_ENTRY"
fi

# ---------------------------------------------------------------------------
# Step 3: Mount and verify
# ---------------------------------------------------------------------------
log "Step 3/6: Mounting ${MOUNT_POINT}..."
mount -a
if ! mount | grep -q "$MOUNT_POINT"; then
    fail "Mount did not succeed — check 'dmesg' and 'journalctl -xe' for details."
fi
log "  -> Mounted successfully"

mkdir -p "$TIMEMACHINE_DIR"

# ---------------------------------------------------------------------------
# Step 4: Create the Samba user group and add the user
# ---------------------------------------------------------------------------
log "Step 4/6: Configuring Samba group and user..."
if ! getent group "$SMB_GROUP" > /dev/null; then
    groupadd "$SMB_GROUP"
    log "  -> Created group ${SMB_GROUP}"
fi

if id "$SMB_USER" &> /dev/null; then
    usermod -aG "$SMB_GROUP" "$SMB_USER"
    log "  -> Added ${SMB_USER} to ${SMB_GROUP}"
else
    log "  -> WARNING: Linux user '${SMB_USER}' does not exist. Create it first with:"
    log "       adduser ${SMB_USER}"
    log "     Then re-run this script, or add the user manually:"
    log "       usermod -aG ${SMB_GROUP} ${SMB_USER}"
fi

# ---------------------------------------------------------------------------
# Step 5: Write smb.conf shares (backs up any existing config first)
# ---------------------------------------------------------------------------
log "Step 5/6: Writing Samba configuration..."
if [[ -f "$SMB_CONF" ]]; then
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"
    log "  -> Backed up existing smb.conf"
fi

cat <<EOF > "$SMB_CONF"
[global]
   workgroup = WORKGROUP
   server string = Proxmox Homelab Storage
   security = user
   map to guest = never

   vfs objects = catia fruit streams_xattr
   fruit:aapl = yes
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no

[storage]
   comment = Homelab 1TB Network Storage
   path = ${MOUNT_POINT}
   browsable = yes
   read only = no
   guest ok = no
   valid users = @${SMB_GROUP}
   create mask = 0664
   directory mask = 0775

   vfs objects = recycle catia fruit streams_xattr
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:touch = yes
   recycle:maxsize = 0

[timemachine]
   comment = Time Machine Backup
   path = ${TIMEMACHINE_DIR}
   browsable = yes
   read only = no
   guest ok = no
   valid users = @${SMB_GROUP}
   fruit:time machine = yes
   fruit:time machine max size = 500G
EOF

if ! testparm -s "$SMB_CONF" > /dev/null 2>&1; then
    fail "Generated smb.conf failed validation (testparm). Check ${SMB_CONF} manually."
fi
log "  -> smb.conf written and validated"

# ---------------------------------------------------------------------------
# Step 6: Set the Samba password and restart services
# ---------------------------------------------------------------------------
log "Step 6/6: Restarting Samba services..."
systemctl restart smbd nmbd
systemctl enable smbd nmbd --quiet

echo ""
log "Mount and Samba configuration complete."
log "IMPORTANT: Set the Samba password for '${SMB_USER}' if you haven't already:"
log "    smbpasswd -a ${SMB_USER}"
log ""
log "From macOS, connect via Finder -> Go -> Connect to Server:"
log "    smb://192.168.1.20/storage"
log "    smb://192.168.1.20/timemachine"
log ""
log "See docs/11-Samba.md for full detail and troubleshooting."
