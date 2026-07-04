# 13 — Troubleshooting Reference

## Overview

This document consolidates every issue encountered while building this homelab into a single searchable reference, organized by layer. Each entry links back to the document where it's covered in full context, but is repeated here with enough detail to be useful on its own during a 2am debugging session.

---

## Layer 1: Proxmox Host & Networking

### WiFi Bridge Limitation

**Symptom:** VMs attached to a bridge with `wlp3s0` as a bridge port show link state up, but get no DHCP lease and no connectivity at all.

**Root cause:** 802.11 WiFi associations are a Layer-2 relationship between one client MAC and the access point. Frames bridged through from a VM's virtual NIC carry the VM's own MAC address, which the AP has no association for, and it silently drops them. This is fundamental to how WiFi works, not a misconfiguration.

**Fix:** Use an isolated bridge with `bridge-ports none` and NAT via `iptables MASQUERADE` instead of bridging `wlp3s0` directly. Full detail: [02-Proxmox-Networking.md](02-Proxmox-Networking.md).

### `vmbr0` Shows `linkdown`

**Symptom:** The Proxmox Web UI shows `vmbr0` with a "link down" indicator.

**Root cause:** Often cosmetic — a bridge with no physical port (`bridge-ports none`) has no "link" in the traditional sense, and some Proxmox UI versions render this as `linkdown` even when the bridge is fully functional.

**Fix:** Verify actual functionality with `ip a show vmbr0` and a real `ping` test rather than trusting the UI icon. See [02-Proxmox-Networking.md](02-Proxmox-Networking.md).

### Ubuntu VM Not Getting an IP

**Symptom:** A freshly cloned VM boots but `qm guest cmd <vmid> network-get-interfaces` shows no address, or shows only a link-local address.

**Root cause:** Usually a cloud-init `ipconfig0` override that wasn't applied before first boot, or a typo in the `ip=<addr>/<prefix>,gw=<gateway>` syntax.

**Fix:** Confirm `qm config <vmid> | grep ipconfig0` shows the expected value, then console into the VM and check `cloud-init status --long` and `/var/log/cloud-init.log`. See [04-Cloning-VMs.md](04-Cloning-VMs.md).

### Static IP Not Persisting After Reboot

**Symptom:** A VM has the correct IP after cloud-init runs, but loses it (or reverts to DHCP) after a manual reboot.

**Root cause:** Manual edits to `/etc/netplan/*.yaml` made directly inside the guest can be overwritten by cloud-init re-applying its own generated network config on next boot, if cloud-init hasn't been told the network config is "final."

**Fix:** Make network changes via `qm set <vmid> --ipconfig0 ...` at the Proxmox layer (which cloud-init reads at boot) rather than hand-editing netplan files inside the guest. See [04-Cloning-VMs.md](04-Cloning-VMs.md).

---

## Layer 2: SSH & Access

### SSH Host Key Changed

**Symptom:** `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` when connecting to a VM.

**Root cause:** Expected after recreating/re-cloning a VM — the new instance generates a fresh SSH host key that doesn't match the previously cached fingerprint.

**Fix:** `ssh-keygen -R <ip>` to remove the stale cached key, then reconnect and accept the new fingerprint. Do **not** globally disable host key checking as a workaround. See [05-SSH.md](05-SSH.md).

### Permission Denied (publickey)

**Symptom:** SSH fails with `Permission denied (publickey)` when using `ProxyJump`.

**Root cause:** Either the Proxmox host (first hop) or the target VM (second hop) doesn't have your public key authorized, or the wrong username is specified for one of the hops.

**Fix:** Test each hop independently (`ssh root@192.168.1.20`, then `ssh -J root@192.168.1.20 vm1@10.10.10.10`) to isolate which hop is failing. See [05-SSH.md](05-SSH.md).

---

## Layer 3: Kubernetes Bootstrap

### Swap Enabled

**Symptom:** `kubeadm init`/`join` pre-flight check fails: `[ERROR Swap]: running with swap on is not supported`.

**Fix:** `swapoff -a` plus commenting out the swap line in `/etc/fstab` so it stays disabled across reboots. See [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md).

### Kubelet Failing to Start

**Symptom:** `kubelet` crash-loops after `kubeadm init`/`join`; `journalctl -u kubelet` shows cgroup driver mismatch errors.

**Root cause:** containerd's `SystemdCgroup` config option left at `false` while `kubelet`/the OS use the `systemd` cgroup driver, creating two disagreeing cgroup managers on the same node.

**Fix:** Set `SystemdCgroup = true` in `/etc/containerd/config.toml` and restart containerd. See [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md).

### `localhost:8080 was refused` from `kubectl`

**Symptom:** `kubectl get nodes` returns `The connection to the server localhost:8080 was refused`.

**Root cause:** `kubectl` has no valid kubeconfig in scope and falls back to a legacy hardcoded default that never works against a real cluster.

**Fix:** `cp /etc/kubernetes/admin.conf ~/.kube/config` (with correct ownership), and check `$KUBECONFIG` isn't pointing somewhere invalid. See [07-Kubeadm-ControlPlane.md](07-Kubeadm-ControlPlane.md).

### Nodes Stuck `NotReady`

**Symptom:** `kubectl get nodes` shows `NotReady` for all nodes after `kubeadm init`/`join`.

**Root cause:** Expected until a CNI is installed — `kubelet` cannot report `Ready` without one.

**Fix:** Install Cilium per [09-Cilium.md](09-Cilium.md). If nodes remain `NotReady` **after** Cilium reports healthy, check the Cilium-specific troubleshooting below.

---

## Layer 4: Cilium / Pod Networking

### Cilium DaemonSet Not Fully Ready

**Symptom:** `cilium status --wait` times out with fewer than 3/3 agents ready.

**Fix:** `kubectl -n kube-system logs -l k8s-app=cilium` on the specific unhealthy node; commonly traced back to a missed prerequisite (`br_netfilter` module or bridge `sysctl` values) from [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md). See [09-Cilium.md](09-Cilium.md).

### Containerd Issues (overlay errors)

**Symptom:** Pods stuck in `ContainerCreating`; `journalctl -u containerd` shows overlay filesystem errors.

**Fix:** Confirm the `overlay` kernel module is loaded (`lsmod | grep overlay`); re-run `modprobe overlay` and check `dmesg` if it fails to load. See [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md).

---

## Layer 5: Storage & Samba

### Samba Not Mounting After Reboot

**Symptom:** The `/mnt/storage` mount, and therefore the Samba shares, are missing after a Proxmox host reboot.

**Root cause:** Either the underlying `/etc/fstab` entry failed silently (masked by `nofail`), or `smbd`/`nmbd` didn't start.

**Fix:** Check `mount | grep /mnt/storage` first, then `systemctl status smbd nmbd`. See [11-Samba.md](11-Samba.md).

---

## Layer 6: Remote `kubectl` Access

### Mac Cannot Reach the Cluster

**Symptom:** `kubectl` on macOS fails with `dial tcp 10.10.10.10:6443: i/o timeout`.

**Root cause:** The kubeconfig's `server:` field points at `10.10.10.10`, which is only reachable from the isolated lab bridge, not the home network your Mac sits on.

**Fix:** Establish an SSH tunnel (`ssh -f -N -L 6443:10.10.10.10:6443 master`) and repoint the kubeconfig at `https://127.0.0.1:6443`. See [12-Mac-Kubectl.md](12-Mac-Kubectl.md).

### ProxyJump Misconfiguration

**Symptom:** `kubectl`/`scp`/`ssh` from the Mac all fail identically with a connection timeout, regardless of target VM.

**Root cause:** `~/.ssh/config`'s `ProxyJump` directive is missing, misspelled, or pointing at the wrong Proxmox host address.

**Fix:** Verify `~/.ssh/config` matches [05-SSH.md](05-SSH.md) exactly, and test the Proxmox hop in isolation first.

### `kubectl` from macOS: Certificate Hostname Mismatch

**Symptom:** `x509: certificate is valid for 10.10.10.10, ..., not 127.0.0.1` when using the SSH tunnel approach.

**Fix:** Add `127.0.0.1`/`localhost` as extra API server certificate SANs at `kubeadm init` time (`--apiserver-cert-extra-sans=127.0.0.1,localhost`), or accept `--insecure-skip-tls-verify` as a homelab-only convenience. See [12-Mac-Kubectl.md](12-Mac-Kubectl.md).

---

## Quick Diagnostic Commands Reference

| Symptom Category | First Command to Run |
|---|---|
| VM has no network | `qm guest cmd <vmid> network-get-interfaces` |
| Node NotReady | `kubectl describe node <name> \| grep -A5 Conditions` |
| Pod stuck Pending/CrashLoopBackOff | `kubectl describe pod <name>` then `kubectl logs <name>` |
| Cilium unhealthy | `cilium status --wait` then `cilium connectivity test` |
| DNS not resolving | `kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -it -- nslookup kubernetes.default` |
| SSH access broken | Test each `ProxyJump` hop independently |
| Samba unreachable | `systemctl status smbd nmbd` on the Proxmox host |

---

## Best Practices for Diagnosing New Issues

1. **Identify the layer first** — Proxmox networking, SSH, Kubernetes bootstrap, CNI, storage, or remote access — before diving into logs. Most issues in this homelab are layer-specific and don't require cross-layer debugging.
2. **Test the simplest possible reproduction** — e.g. a raw `ping` before a `kubectl` command, or a direct SSH hop before a `ProxyJump`'d one — to isolate exactly where a failure begins.
3. **Check for missed prerequisites before assuming a tool bug** — the overwhelming majority of issues in this build trace back to a skipped or mistyped step in [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md), not a genuine bug in `kubeadm`, Cilium, or Samba.

---

**Next:** [14-Best-Practices.md](14-Best-Practices.md) — performance, security, and operational recommendations for this homelab.
