# 14 — Best Practices, Performance, and Security

## Overview

This document consolidates operational guidance that applies across the entire homelab, rather than to any single layer. It covers the specific resource-constraint tradeoffs of running a 3-node Kubernetes cluster as VMs on a single 4-core/16GB laptop, along with general security hardening recommendations appropriate for a homelab (not a hardened production environment, but not a completely open one either).

---

## Resource Oversubscription: What It Means Here

| Resource | Physical Available | Allocated to VMs | Ratio |
|---|---|---|---|
| vCPU | 4 physical cores | 6 vCPU (2 × 3 VMs) | 1.5:1 |
| RAM | 16 GB | 6 GB (2GB × 3 VMs) | Comfortable — ~10GB headroom for host + overhead |

CPU is **oversubscribed** (6 vCPU scheduled against 4 physical cores) while RAM has generous headroom. This is a deliberate, common homelab tradeoff:

- CPU oversubscription is generally safe as long as all three VMs are not simultaneously CPU-bound — KVM's scheduler time-slices fairly, and idle VMs consume essentially zero CPU.
- RAM, by contrast, is **not** safely oversubscribed by default in this configuration (no ballooning is configured) — if allocated RAM exceeds physical RAM, VMs can be starved or the host can begin swapping, which is far more disruptive than CPU contention.

> **Tip:** If you notice sluggish behavior during simultaneous heavy workloads across nodes (e.g. running `cilium connectivity test` while also applying a large deployment), this is expected given the 1.5:1 CPU ratio — it is not a sign of misconfiguration.

---

## Performance Recommendations

### Virtualization Layer

- **Always use VirtIO** for both network (`virtio`) and disk (`virtio-scsi-pci`) devices — covered in depth in [03-Ubuntu-Template.md](03-Ubuntu-Template.md). This is the single highest-impact performance decision available given the CPU constraint.
- **Use linked clones**, not full clones, for all three cluster VMs — faster to create, less SSD wear, and appropriate since the template is never modified after being finalized.
- **Keep the boot/VM-disk SSD separate from the bulk-storage HDD** — VM disk I/O and large Samba file transfers ([11-Samba.md](11-Samba.md)) would otherwise compete for the same spindle, introducing latency spikes in both directions.

### Kubernetes Layer

- **`kubeProxyReplacement=true` with Cilium** reduces `iptables` rule-chain evaluation overhead versus the default `kube-proxy` data plane — meaningful on CPU-constrained nodes (see [09-Cilium.md](09-Cilium.md)).
- **Avoid running unrelated workloads on worker VMs outside Kubernetes** — with only 2 GB RAM per worker, every non-Kubernetes-managed process directly reduces the pod-schedulable headroom.
- **Set resource requests/limits on every workload you deploy** going forward — without them, the scheduler has no basis for intelligent placement across 3 memory-constrained nodes, and a single runaway pod can starve its neighbors.

### Storage Layer

- NTFS via `ntfs-3g` (FUSE) has real CPU overhead per I/O operation compared to a native filesystem — acceptable for backups/media, but a reason to plan a future migration to Longhorn or NFS-backed persistent storage (see [15-Roadmap.md](15-Roadmap.md)) for anything latency-sensitive.

---

## Security Recommendations

### Network Boundaries

- The isolated `10.10.10.0/24` lab bridge with NAT-only outbound access ([02-Proxmox-Networking.md](02-Proxmox-Networking.md)) is the foundation of this homelab's security posture: nothing on that network is reachable from the home network or the internet except through an authenticated SSH hop.
- Never open inbound NAT/port-forward rules from the home network directly to `10.10.10.0/24` addresses — always route through SSH `ProxyJump` ([05-SSH.md](05-SSH.md)) or `kubectl` tunneling ([12-Mac-Kubectl.md](12-Mac-Kubectl.md)).

### Authentication

- SSH key-only authentication everywhere; `PasswordAuthentication no` on both the Proxmox host and all three VMs once key-based access is confirmed working.
- Samba uses `security = user` with `map to guest = never` — verify explicitly that anonymous listing is rejected (`smbclient -L 192.168.1.20 -N`).
- Kubernetes join tokens expire in 24 hours by default; don't extend this casually — regenerate a fresh token per join instead (see [08-Kubeadm-Workers.md](08-Kubeadm-Workers.md)).

### Credential Hygiene

- The `admin.conf` kubeconfig grants full cluster-admin — treat it like a root credential; it is correctly excluded from version control via [.gitignore](../.gitignore).
- Proxmox's root password and Samba credentials are independent secrets — store both in a password manager, and don't assume they'll ever match a Linux login password (see [11-Samba.md](11-Samba.md)).

### Package Management

- `apt-mark hold` on `kubelet`/`kubeadm`/`kubectl` ([06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md)) prevents an unattended upgrade from silently jumping Kubernetes minor versions — upgrades should always be a deliberate, tested process (drain → upgrade → uncordon), not an automatic side effect of `apt upgrade`.

### Future Hardening (as workloads are added)

- Layer `CiliumNetworkPolicy`/Kubernetes `NetworkPolicy` on top of the default-allow-all pod networking once real workloads are deployed — see [09-Cilium.md](09-Cilium.md) and [15-Roadmap.md](15-Roadmap.md).
- Consider Kyverno or OPA Gatekeeper (both on the roadmap) once you're ready to enforce policy (e.g. "no privileged containers", "images must come from a trusted registry") across the cluster rather than relying on manual review.

---

## Operational Recommendations

- **Snapshot before every risky change.** Proxmox snapshots (`qm snapshot <vmid> <name>`) are cheap and fast on this hardware — take one before Kubernetes version upgrades, Cilium version upgrades, or any manual `/etc/kubernetes` edit.
- **Keep scripts idempotent.** Every script in [scripts/](../scripts/) is written to be safely re-runnable; prefer re-running the script over manual, one-off fixes so configuration never silently drifts between nodes.
- **Validate after every meaningful change**, not just at initial build time — re-run the checklist in [10-Cluster-Validation.md](10-Cluster-Validation.md) after upgrades, node rebuilds, or CNI changes.
- **Back up configuration, not just data.** [scripts/backup-config.sh](../scripts/backup-config.sh) archives Proxmox VM configs and Kubernetes manifests/certs metadata — run it on a regular cadence, not only after something breaks.

---

**Next:** [15-Roadmap.md](15-Roadmap.md) — the planned next additions to this homelab.
