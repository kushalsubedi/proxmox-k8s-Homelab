#!/usr/bin/env bash
#
# worker-join.sh
#
# Wraps `kubeadm join` with pre-flight checks and safe defaults for joining
# a worker node to the homelab Kubernetes cluster.
#
# This script does NOT hardcode a token, since tokens are short-lived
# (24 hours by default) and must be freshly generated on the control-plane
# node before each use:
#
#   kubeadm token create --print-join-command
#
# Reference: docs/08-Kubeadm-Workers.md
#
# Usage:
#   sudo ./worker-join.sh "kubeadm join 10.10.10.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
#
# Or interactively (the script will prompt if no argument is given):
#   sudo ./worker-join.sh

set -euo pipefail

CONTROL_PLANE_ENDPOINT="10.10.10.10:6443"

log() {
    echo -e "\033[1;32m[worker-join]\033[0m $1"
}

fail() {
    echo -e "\033[1;31m[worker-join] ERROR:\033[0m $1" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)."
fi

# ---------------------------------------------------------------------------
# Pre-flight checks — verify prerequisites from install-kubernetes.sh are met
# ---------------------------------------------------------------------------
log "Running pre-flight checks..."

if swapon --show | grep -q .; then
    fail "Swap is still active. Run scripts/install-kubernetes.sh first (see docs/06-Kubernetes-Prerequisites.md)."
fi

if ! systemctl is-active --quiet containerd; then
    fail "containerd is not running. Run scripts/install-kubernetes.sh first."
fi

if ! command -v kubeadm &> /dev/null; then
    fail "kubeadm is not installed. Run scripts/install-kubernetes.sh first."
fi

log "  -> Swap disabled: OK"
log "  -> containerd running: OK"
log "  -> kubeadm installed: OK"

# ---------------------------------------------------------------------------
# Verify reachability of the control plane before attempting to join
# ---------------------------------------------------------------------------
log "Checking control-plane reachability at ${CONTROL_PLANE_ENDPOINT}..."
if ! curl -k -s --connect-timeout 5 "https://${CONTROL_PLANE_ENDPOINT}/healthz" > /dev/null; then
    fail "Cannot reach the control plane at https://${CONTROL_PLANE_ENDPOINT}/healthz — check networking (docs/02-Proxmox-Networking.md) before proceeding."
fi
log "  -> Control plane reachable: OK"

# ---------------------------------------------------------------------------
# Obtain the join command
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
    JOIN_CMD="$1"
else
    echo ""
    echo "No join command supplied as an argument."
    echo "On the control-plane node, run:"
    echo ""
    echo "    kubeadm token create --print-join-command"
    echo ""
    read -rp "Paste the full 'kubeadm join ...' command here: " JOIN_CMD
fi

if [[ -z "$JOIN_CMD" || "$JOIN_CMD" != kubeadm\ join* ]]; then
    fail "Invalid join command. It must start with 'kubeadm join'."
fi

# ---------------------------------------------------------------------------
# Execute the join
# ---------------------------------------------------------------------------
log "Joining the cluster..."
eval "$JOIN_CMD"

log "Join complete. Verify from the control-plane node with:"
log "    kubectl get nodes -o wide"
log "(See docs/10-Cluster-Validation.md for full validation steps.)"
