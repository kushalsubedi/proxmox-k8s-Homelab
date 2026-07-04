# 08 — Joining Worker Nodes

## Overview

With the control plane initialized on `master` ([07-Kubeadm-ControlPlane.md](07-Kubeadm-ControlPlane.md)), this document joins `worker1` (`10.10.10.11`) and `worker2` (`10.10.10.12`) to the cluster using the token generated during `kubeadm init`. The companion script [scripts/worker-join.sh](../scripts/worker-join.sh) wraps this process with pre-flight checks.

---

## Prerequisites

- Both workers have already completed [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md) (same `containerd`, swap, sysctl, and kernel module setup as `master`).
- You have the exact `kubeadm join` command captured from the `kubeadm init` output in [07-Kubeadm-ControlPlane.md](07-Kubeadm-ControlPlane.md), or you've regenerated one with `kubeadm token create --print-join-command`.

---

## Step 1: Retrieve (or Regenerate) the Join Command

On `master`:

```bash
kubeadm token create --print-join-command
```

**Expected output:**

```
kubeadm join 10.10.10.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...cdef
```

This is safe to re-run at any time — it always generates a fresh, valid token rather than trying to recall an old (possibly expired) one, which is why this is the recommended approach even if you saved the original `kubeadm init` output.

## Step 2: Join Each Worker

On `worker1`:

```bash
sudo kubeadm join 10.10.10.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...cdef
```

Repeat the identical command on `worker2`. Both workers use the **same** token and hash — a token isn't per-node, it authorizes any node presenting it to join, up to its expiry.

**Expected output:**

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

## Step 3: Confirm From the Control Plane

On `master`:

```bash
kubectl get nodes -o wide
```

**Expected output:**

```
NAME      STATUS     ROLES           AGE   VERSION
master    NotReady   control-plane   10m   v1.34.x
worker1   NotReady   <none>          1m    v1.34.x
worker2   NotReady   <none>          1m    v1.34.x
```

> **Note:** All three nodes showing `NotReady` at this point is expected — no CNI has been installed yet. This is resolved entirely in [09-Cilium.md](09-Cilium.md); do not troubleshoot networking here.

---

## Verification

```bash
kubectl get nodes
kubectl describe node worker1 | grep -A5 Conditions
```

Confirm both `worker1` and `worker2` appear in the node list with the correct internal IPs (`10.10.10.11`, `10.10.10.12` respectively) under `kubectl describe node <name> | grep InternalIP`.

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Reusing a `kubeadm join` command copied from a previous cluster build | Fails — the CA cert hash no longer matches a freshly re-initialized control plane | Always regenerate with `kubeadm token create --print-join-command` after any `kubeadm reset`/`init` cycle |
| Running `kubeadm join` without `sudo` | Fails with a permissions error writing to `/etc/kubernetes/` | Always run as root/with `sudo` |
| Joining a worker that skipped [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md) | Join appears to succeed, but `kubelet` on that node crash-loops immediately after | Run [scripts/install-kubernetes.sh](../scripts/install-kubernetes.sh) on every node **before** attempting to join |

---

## Troubleshooting

**Symptom: `kubeadm join` hangs at `[preflight] Running pre-flight checks` then times out.**
Almost always a network reachability issue between the worker and `master:6443`. From the worker:
```bash
curl -k https://10.10.10.10:6443/healthz
```
If this fails, verify the worker's static IP/gateway configuration ([04-Cloning-VMs.md](04-Cloning-VMs.md)) rather than assuming a `kubeadm` bug.

**Symptom: `error execution phase preflight: couldn't validate the identity of the API Server`.**
The discovery token CA cert hash doesn't match the control plane's actual CA — this happens if the control plane was reset/reinitialized after the token/hash was generated. Regenerate a fresh join command per Step 1.

**Symptom: Worker joins, but `kubectl get nodes` never shows it.**
Confirm from the worker itself that `kubelet` is running: `systemctl status kubelet`. If it's not running or crash-looping, check `journalctl -u kubelet -f` for the specific error — commonly a missed prerequisite from [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md).

---

## Recovery

To fully remove and re-join a worker:

```bash
# On the worker
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d

# On master, remove the stale node object first
kubectl delete node worker1

# Then regenerate a token and re-join
kubeadm token create --print-join-command   # run on master
sudo kubeadm join ...                        # run on worker1
```

[scripts/reset-node.sh](../scripts/reset-node.sh) automates the worker-side reset.

---

## Best Practices

- Join workers one at a time and verify each with `kubectl get nodes` before joining the next — this makes it immediately obvious which node introduced a problem if something goes wrong.
- Take a Proxmox snapshot of each worker immediately after a successful join, mirroring the snapshot strategy for `master` in [07-Kubeadm-ControlPlane.md](07-Kubeadm-ControlPlane.md).

## Performance Tips

- With only 2 vCPU / 2 GB RAM per worker, avoid running unrelated workloads on these VMs outside of Kubernetes-scheduled pods — every bit of headroom matters on hardware this constrained (see [14-Best-Practices.md](14-Best-Practices.md)).

## Security Tips

- Treat join tokens as short-lived secrets — they expire in 24 hours by default specifically to limit exposure if leaked. Regenerating a token per join (Step 1) is both more reliable and more secure than reusing an old one from a saved log.

---

**Next:** [09-Cilium.md](09-Cilium.md) — installing the Cilium CNI so all three nodes can finally report `Ready`.
