#!/usr/bin/env bash
#
# backup-config.sh
#
# Backs up Proxmox VM configuration and Kubernetes cluster configuration
# metadata (NOT persistent volume data) for disaster recovery purposes.
#
# Run this on the PROXMOX HOST. It archives:
#   - Proxmox VM config files (/etc/pve/qemu-server/*.conf)
#   - Proxmox network configuration (/etc/network/interfaces)
#   - Samba configuration (/etc/samba/smb.conf)
#   - Kubernetes cluster info (nodes, namespaces, deployments — via kubectl,
#     if reachable from this host)
#
# It does NOT back up:
#   - VM disk images themselves (use Proxmox's own vzdump/backup jobs for that)
#   - Kubernetes PersistentVolume data
#   - Secrets (deliberately excluded — see docs/14-Best-Practices.md)
#
# Reference: docs/14-Best-Practices.md
#
# Usage:
#   sudo ./backup-config.sh [output-directory]
#
# Default output directory: /mnt/storage/backups/homelab-config

set -euo pipefail

OUTPUT_ROOT="${1:-/mnt/storage/backups/homelab-config}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${OUTPUT_ROOT}/${TIMESTAMP}"

log() {
    echo -e "\033[1;32m[backup-config]\033[0m $1"
}

warn() {
    echo -e "\033[1;33m[backup-config] WARNING:\033[0m $1"
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

log "Creating backup directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"/{proxmox,kubernetes,samba}

# ---------------------------------------------------------------------------
# Proxmox VM and network configuration
# ---------------------------------------------------------------------------
log "Backing up Proxmox VM configuration files..."
if [[ -d /etc/pve/qemu-server ]]; then
    cp -a /etc/pve/qemu-server/. "${BACKUP_DIR}/proxmox/qemu-server/" 2>/dev/null || \
        warn "Could not copy /etc/pve/qemu-server (may require running on the Proxmox host itself)"
else
    warn "/etc/pve/qemu-server not found — are you running this on the Proxmox host?"
fi

log "Backing up network configuration..."
cp /etc/network/interfaces "${BACKUP_DIR}/proxmox/interfaces" 2>/dev/null || \
    warn "Could not copy /etc/network/interfaces"

iptables -t nat -S > "${BACKUP_DIR}/proxmox/iptables-nat-rules.txt" 2>/dev/null || \
    warn "Could not capture iptables NAT rules"

# ---------------------------------------------------------------------------
# Samba configuration
# ---------------------------------------------------------------------------
log "Backing up Samba configuration..."
if [[ -f /etc/samba/smb.conf ]]; then
    cp /etc/samba/smb.conf "${BACKUP_DIR}/samba/smb.conf"
else
    warn "/etc/samba/smb.conf not found, skipping"
fi

# ---------------------------------------------------------------------------
# Kubernetes cluster metadata (non-secret)
# ---------------------------------------------------------------------------
log "Backing up Kubernetes cluster metadata (if reachable)..."
if command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null; then
    kubectl get nodes -o yaml            > "${BACKUP_DIR}/kubernetes/nodes.yaml"
    kubectl get namespaces -o yaml       > "${BACKUP_DIR}/kubernetes/namespaces.yaml"
    kubectl get deployments -A -o yaml   > "${BACKUP_DIR}/kubernetes/deployments.yaml"
    kubectl get services -A -o yaml      > "${BACKUP_DIR}/kubernetes/services.yaml"
    kubectl get configmaps -A -o yaml    > "${BACKUP_DIR}/kubernetes/configmaps.yaml"
    log "  -> Kubernetes resource manifests exported (Secrets intentionally excluded)"
else
    warn "kubectl not available or cluster unreachable from this host — skipping Kubernetes backup"
    warn "(Run this script from a machine with cluster access, e.g. master, for a full backup)"
fi

# ---------------------------------------------------------------------------
# Archive and summarize
# ---------------------------------------------------------------------------
ARCHIVE_PATH="${OUTPUT_ROOT}/homelab-config-${TIMESTAMP}.tar.gz"
log "Creating compressed archive: ${ARCHIVE_PATH}"
tar -czf "${ARCHIVE_PATH}" -C "${OUTPUT_ROOT}" "${TIMESTAMP}"

echo ""
echo "----------------------------------------"
echo " Backup Summary"
echo "----------------------------------------"
echo " Raw backup directory: ${BACKUP_DIR}"
echo " Compressed archive:   ${ARCHIVE_PATH}"
du -sh "${ARCHIVE_PATH}" 2>/dev/null || true
echo "----------------------------------------"

log "Backup complete."
log "NOTE: This backup covers CONFIGURATION only, not VM disks or PV data."
log "For full VM disk backups, configure Proxmox's native vzdump backup jobs"
log "under Datacenter -> Backup in the Web UI."
