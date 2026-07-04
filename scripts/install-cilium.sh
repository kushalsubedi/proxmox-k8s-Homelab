#!/usr/bin/env bash
#
# install-cilium.sh
#
# Installs the Cilium CLI and deploys Cilium as the cluster's CNI, configured
# with kube-proxy replacement and Kubernetes-native IPAM, matching the
# addressing plan established at `kubeadm init` time (--pod-network-cidr).
#
# Run this ONCE, from a machine with kubectl access to the cluster
# (typically the control-plane node itself, or your Mac after completing
# docs/12-Mac-Kubectl.md).
#
# Reference: docs/09-Cilium.md
#
# Usage:
#   ./install-cilium.sh

set -euo pipefail

CILIUM_VERSION="1.16.0"
CLI_ARCH="amd64"
API_SERVER_HOST="10.10.10.10"
API_SERVER_PORT="6443"

log() {
    echo -e "\033[1;32m[install-cilium]\033[0m $1"
}

fail() {
    echo -e "\033[1;31m[install-cilium] ERROR:\033[0m $1" >&2
    exit 1
}

if ! command -v kubectl &> /dev/null; then
    fail "kubectl is not installed or not in PATH."
fi

if ! kubectl get nodes &> /dev/null; then
    fail "Cannot reach the cluster with kubectl. Check your kubeconfig (docs/12-Mac-Kubectl.md)."
fi

# ---------------------------------------------------------------------------
# Step 1: Install the Cilium CLI (if not already present)
# ---------------------------------------------------------------------------
if command -v cilium &> /dev/null; then
    log "Cilium CLI already installed: $(cilium version --client 2>/dev/null | head -1 || echo present)"
else
    log "Installing Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    TMP_DIR=$(mktemp -d)
    curl -L --fail --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
        -o "${TMP_DIR}/cilium-linux-${CLI_ARCH}.tar.gz"
    sudo tar xzvfC "${TMP_DIR}/cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -rf "${TMP_DIR}"
    log "  -> Cilium CLI ${CILIUM_CLI_VERSION} installed to /usr/local/bin/cilium"
fi

# ---------------------------------------------------------------------------
# Step 2: Install Cilium into the cluster
# ---------------------------------------------------------------------------
log "Installing Cilium v${CILIUM_VERSION} into the cluster..."
cilium install \
    --version "${CILIUM_VERSION}" \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${API_SERVER_HOST}" \
    --set k8sServicePort="${API_SERVER_PORT}"

# ---------------------------------------------------------------------------
# Step 3: Wait for Cilium to become healthy
# ---------------------------------------------------------------------------
log "Waiting for Cilium to report healthy (this can take a few minutes)..."
cilium status --wait

# ---------------------------------------------------------------------------
# Step 4: Verification
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo " Node Status"
echo "----------------------------------------"
kubectl get nodes -o wide
echo ""
echo "----------------------------------------"
echo " Running connectivity test (this deploys"
echo " temporary test pods across all nodes)"
echo "----------------------------------------"
cilium connectivity test

log "Cilium installation and validation complete."
log "All nodes should now report 'Ready'. See docs/10-Cluster-Validation.md for further checks."
