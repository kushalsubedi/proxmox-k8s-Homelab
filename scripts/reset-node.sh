#!/usr/bin/env bash
#
# reset-node.sh
#
# Fully resets a node's kubeadm/CNI state so it can be cleanly re-joined
# (or re-initialized, if run on the control-plane node) from scratch.
#
# Safe to run on ANY node — master, worker1, or worker2.
#
# WARNING: This is destructive. It removes all local Kubernetes state on
# THIS node, including certificates, manifests, and CNI configuration.
# It does NOT affect other nodes, and does NOT delete the node object from
# the API server if run on a worker — remove it manually from the control
# plane afterward with:
#
#   kubectl delete node <node-name>
#
# Reference: docs/07-Kubeadm-ControlPlane.md, docs/08-Kubeadm-Workers.md
#
# Usage:
#   sudo ./reset-node.sh

set -euo pipefail

log() {
    echo -e "\033[1;33m[reset-node]\033[0m $1"
}

fail() {
    echo -e "\033[1;31m[reset-node] ERROR:\033[0m $1" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)."
fi

HOSTNAME_LOCAL="$(hostname)"

echo ""
echo "=========================================================="
echo "  WARNING: This will reset all Kubernetes state on:"
echo "  ${HOSTNAME_LOCAL}"
echo "=========================================================="
echo ""
read -rp "Type 'yes' to continue: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted. No changes made."
    exit 0
fi

log "Resetting kubeadm state on ${HOSTNAME_LOCAL}..."
kubeadm reset -f

log "Removing CNI configuration..."
rm -rf /etc/cni/net.d

log "Removing local kubeconfig (if present)..."
rm -rf "${HOME}/.kube"
if [[ -n "${SUDO_USER:-}" ]]; then
    rm -rf "/home/${SUDO_USER}/.kube"
fi

log "Flushing leftover iptables rules from kube-proxy/CNI (best-effort)..."
iptables -F || true
iptables -t nat -F || true
iptables -t mangle -F || true
iptables -X || true

log "Restarting containerd to clear any stale container state..."
systemctl restart containerd

echo ""
log "Reset complete on ${HOSTNAME_LOCAL}."
log ""
log "If this was a WORKER node, remove its stale entry from the control plane:"
log "    kubectl delete node ${HOSTNAME_LOCAL}"
log ""
log "If this was the CONTROL-PLANE node, re-initialize with:"
log "    sudo kubeadm init --pod-network-cidr=10.244.0.0/16 \\"
log "        --apiserver-advertise-address=10.10.10.10 \\"
log "        --control-plane-endpoint=10.10.10.10"
log ""
log "See docs/07-Kubeadm-ControlPlane.md and docs/08-Kubeadm-Workers.md for full detail."
