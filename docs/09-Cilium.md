# 09 — Installing Cilium (CNI)

## Overview

Every node has joined the cluster ([08-Kubeadm-Workers.md](08-Kubeadm-Workers.md)) but all report `NotReady`, and `coredns` pods sit `Pending` — because no CNI (Container Network Interface) plugin has been installed yet. This document installs **Cilium**, an eBPF-based CNI, which finally allows pod-to-pod networking, Service routing, and DNS to function, bringing all nodes to `Ready`.

---

## Why Cilium

| Consideration | Cilium | Traditional CNIs (e.g. Flannel) |
|---|---|---|
| Data plane | eBPF, running in-kernel | Typically `iptables`-based `kube-proxy` chains |
| Observability | Built-in `Hubble` flow visibility, no extra install | None natively |
| `NetworkPolicy` support | Full L3/L4 (and L7 with Envoy) | Often requires a separate policy engine (e.g. Calico alongside Flannel) |
| Performance at scale | Bypasses much of the `iptables` chain-length overhead as service count grows | `iptables` rule evaluation scales roughly linearly with Services/Endpoints, which can matter even on small clusters under certain workloads |

For a homelab that's explicitly meant for learning production-grade Kubernetes operations, Cilium's built-in observability tooling (`Hubble`) and native `NetworkPolicy` support make it a better teaching tool than a minimal overlay-only CNI, at the cost of a slightly heavier install.

---

## Step 1: Install the Cilium CLI

On `master` (or any machine with `kubectl` access to the cluster):

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz
```

The `cilium` CLI is a purpose-built installer/diagnostics tool that wraps the equivalent Helm chart with sensible defaults and adds cluster-connectivity test commands used in the Verification section below.

## Step 2: Install Cilium Into the Cluster

```bash
cilium install --version 1.16.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.10.10.10 \
  --set k8sServicePort=6443
```

| Flag | Explanation |
|---|---|
| `ipam.mode=kubernetes` | Delegates pod IP allocation to Kubernetes' own per-node `PodCIDR` assignment (derived from the `--pod-network-cidr=10.244.0.0/16` set at `kubeadm init` time), rather than Cilium managing its own separate IPAM state. This keeps pod IP bookkeeping in one place — the same place `kubectl get nodes -o wide` already reports it. |
| `kubeProxyReplacement=true` | Enables Cilium's eBPF-based Service load-balancing to fully replace `kube-proxy`'s `iptables`/`ipvs` rules — this is the core of what makes Cilium's data plane fast, and is the mode most homelab and production deployments use going forward. |
| `k8sServiceHost` / `k8sServicePort` | Required when `kubeProxyReplacement=true` — Cilium's own agents need to reach the API server directly (rather than through the Service that `kube-proxy` would normally provide), so the API server's real address and port are given explicitly. |

## Step 3: Wait for Cilium to Become Ready

```bash
cilium status --wait
```

**Expected output (abbreviated):**

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:         OK
 \__/¯¯\__/    Operator:       OK
 /¯¯\__/¯¯\    Envoy DaemonSet: disabled (using embedded mode)
 \__/¯¯\__/    Hubble:         disabled
    \__/       ClusterMesh:    disabled

Deployment        cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
DaemonSet         cilium             Desired: 3, Ready: 3/3, Available: 3/3
```

`Desired: 3, Ready: 3/3` confirms the Cilium agent DaemonSet is running on all three nodes (`master`, `worker1`, `worker2`).

---

## Verification

```bash
kubectl get nodes
```

**Expected output — all nodes now `Ready`:**

```
NAME      STATUS   ROLES           AGE   VERSION
master    Ready    control-plane   20m   v1.34.x
worker1   Ready    <none>          15m   v1.34.x
worker2   Ready    <none>          15m   v1.34.x
```

```bash
kubectl get pods -n kube-system
```

**Expected output:** `coredns` pods now `Running` (previously `Pending`), plus `cilium-*` and `cilium-operator-*` pods `Running`.

Run Cilium's built-in end-to-end connectivity test:

```bash
cilium connectivity test
```

**Expected result:** all test cases pass (`✅`). This test deploys temporary pods across nodes and validates pod-to-pod, pod-to-service, and pod-to-external connectivity — a genuinely thorough validation, not just a "pods are Running" check.

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Installing Cilium before setting `--pod-network-cidr` at `kubeadm init` time | IPAM misconfiguration; pods may fail to get IPs or get IPs from an unintended range | Always set `--pod-network-cidr=10.244.0.0/16` at `kubeadm init` (see [07-Kubeadm-ControlPlane.md](07-Kubeadm-ControlPlane.md)) before installing any CNI |
| Setting `kubeProxyReplacement=true` without `k8sServiceHost`/`k8sServicePort` | Cilium agents can't reach the API server once they take over Service routing, causing a cluster-wide outage | Always set both flags together, as shown in Step 2 |
| Installing a CNI version far newer/older than what's validated against Kubernetes v1.34 | Undefined behavior, possible node instability | Check the Cilium release notes for confirmed compatibility with your `kubeadm` version before upgrading |

---

## Troubleshooting

**Symptom: `cilium status --wait` times out with `DaemonSet cilium Desired: 3, Ready: 1/3`.**
One or more nodes' Cilium agent pod is failing. Check directly:
```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
```
Common root causes: a node missed a prerequisite from [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md) (especially the `br_netfilter` module or `bridge-nf-call-iptables` sysctl), or the node has insufficient resources to schedule the pod at all.

**Symptom: Nodes report `Ready` but `cilium connectivity test` fails on cross-node pod traffic specifically.**
This is frequently a sign that the underlying `vmbr0` bridge (see [02-Proxmox-Networking.md](02-Proxmox-Networking.md)) isn't correctly passing traffic between VMs — verify basic VM-to-VM connectivity outside of Kubernetes entirely (`ping` between `worker1` and `worker2` at the OS level) before assuming this is a Cilium bug.

**Symptom: `coredns` pods stuck in `CrashLoopBackOff` even after Cilium reports `OK`.**
Check `kubectl -n kube-system logs deploy/coredns` — a common cause on constrained VMs is a resource limit set too low for `coredns` to start under memory pressure; check `kubectl -n kube-system describe pod <coredns-pod>` for `OOMKilled` events.

---

## Recovery

To fully remove and reinstall Cilium (for example, after changing a Helm value that Cilium doesn't support changing in-place):

```bash
cilium uninstall
cilium install --version 1.16.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.10.10.10 \
  --set k8sServicePort=6443
cilium status --wait
```

[scripts/install-cilium.sh](../scripts/install-cilium.sh) automates the full install sequence (CLI download + `cilium install` + wait) and is safe to re-run.

---

## Best Practices

- Always run `cilium connectivity test` after any CNI install or upgrade — a cluster reporting `Ready` nodes is a necessary but not sufficient signal that pod networking actually works end-to-end.
- Pin the Cilium version explicitly (`--version 1.16.0`) in both documentation and scripts rather than trusting whatever the CLI's "stable" default resolves to at install time — this keeps the cluster reproducible.

## Performance Tips

- `kubeProxyReplacement=true` removes a substantial amount of `iptables` rule-chain overhead compared to the default `kube-proxy` data plane — on a resource-constrained homelab, this measurably reduces per-packet CPU cost, which matters when 3 VMs share 4 physical cores.

## Security Tips

- Cilium's `CiliumNetworkPolicy` CRD supports L3/L4/L7-aware policies — consider layering these on top of standard Kubernetes `NetworkPolicy` resources once the cluster is stable, especially before deploying any workload reachable outside the cluster (see the Ingress/`cert-manager` roadmap items in [15-Roadmap.md](15-Roadmap.md)).
- `Hubble` (Cilium's observability layer) was left disabled in this base install for simplicity — enabling it (`cilium hubble enable`) is recommended once you begin deploying real workloads, since flow-level visibility is invaluable for debugging `NetworkPolicy` issues later.

---

**Next:** [10-Cluster-Validation.md](10-Cluster-Validation.md) — end-to-end tests proving the cluster is genuinely healthy.
