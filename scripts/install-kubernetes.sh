
#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_VERSION="1.34"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

log(){ echo -e "\033[1;32m[install-kubernetes]\033[0m $1"; }
fail(){ echo -e "\033[1;31m[install-kubernetes] ERROR:\033[0m $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run with sudo/root."

log "Installing Kubernetes prerequisites"

log "1/7 Disable swap"
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

log "2/7 Kernel modules"
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

log "3/7 Sysctl"
cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

log "4/7 Install containerd"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg bash-completion software-properties-common containerd runc
mkdir -p /etc/containerd
containerd config default > "$CONTAINERD_CONFIG"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG"
systemctl enable --now containerd

log "5/7 Install Kubernetes"
install -d -m755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

log "6/7 Install crictl"
ARCH=amd64
CRICTL_VERSION=v1.34.0
TMP=$(mktemp -d)
curl -fsSL -o $TMP/crictl.tgz https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
tar -C /usr/local/bin -xzf $TMP/crictl.tgz
rm -rf "$TMP"

log "7/7 Bash completion"
kubectl completion bash >/etc/bash_completion.d/kubectl

echo
echo "========== Verification =========="
swapon --show
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward)"
echo "containerd: $(systemctl is-active containerd)"
echo "kubelet: $(systemctl is-enabled kubelet)"
echo "kubeadm: $(kubeadm version -o short)"
echo "kubectl: $(kubectl version --client=true | head -1)"
echo "crictl: $(crictl --version)"
echo
echo "Next (control-plane):"
echo "kubeadm init --pod-network-cidr=10.244.0.0/16"
kubeadm version -o short
echo "Then configure ~/.kube and install CNI."
