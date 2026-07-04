# 12 — Configuring `kubectl` on macOS

## Overview

This document configures `kubectl` on your MacBook so you can manage the cluster directly from your admin machine, rather than SSHing into `master` for every command. Since `master` (`10.10.10.10`) is not directly reachable from your Mac (it lives on the isolated lab bridge — see [02-Proxmox-Networking.md](02-Proxmox-Networking.md)), this uses the same SSH `ProxyJump` tunnel established in [05-SSH.md](05-SSH.md) to retrieve the kubeconfig and to reach the API server.

---

## Step 1: Install `kubectl` on macOS

```bash
brew install kubectl
kubectl version --client
```

**Expected output:** `Client Version: v1.34.x` (match the same minor version as the cluster itself — see [06-Kubernetes-Prerequisites.md](06-Kubernetes-Prerequisites.md)).

## Step 2: Copy the Kubeconfig from `master`

```bash
mkdir -p ~/.kube
scp master:~/.kube/config ~/.kube/config
```

Because `master` is aliased in `~/.ssh/config` with a `ProxyJump` through the Proxmox host ([05-SSH.md](05-SSH.md)), `scp master:...` transparently tunnels through the Proxmox host — no manual two-hop copy required.

## Step 3: Test Direct Access

```bash
kubectl get nodes
```

**Expected result — this will *fail*:**

```
Unable to connect to the server: dial tcp 10.10.10.10:6443: i/o timeout
```

This is expected. The kubeconfig's `server:` field points at `https://10.10.10.10:6443`, but `10.10.10.10` is only reachable from the isolated lab bridge, not from your Mac's home-network vantage point. The next step resolves this using an SSH tunnel.

## Step 4: Establish a Persistent SSH Tunnel to the API Server

```bash
ssh -f -N -L 6443:10.10.10.10:6443 master
```

| Flag | Explanation |
|---|---|
| `-f` | Backgrounds the SSH process after authentication, so it doesn't tie up a terminal. |
| `-N` | Don't execute a remote command — this connection exists purely to forward ports. |
| `-L 6443:10.10.10.10:6443` | Local port forward: connections to `localhost:6443` on your Mac are tunneled through the SSH session (which itself is `ProxyJump`ed through the Proxmox host) to `10.10.10.10:6443` as seen from `master`'s own network position. |

Because `master` itself can reach `10.10.10.10:6443` directly (it's the control-plane node), this single tunnel effectively bridges your Mac's `localhost:6443` to the real API server address, through two hops (Mac → Proxmox host → master → API server) collapsed into one SSH command.

## Step 5: Point the Kubeconfig at the Local Tunnel

```bash
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
```

> **Note:** The API server's TLS certificate is issued for `10.10.10.10` (and other SANs `kubeadm` adds automatically, like `kubernetes.default.svc`), **not** for `127.0.0.1`. Depending on your kubeconfig's `certificate-authority-data`, `kubectl` may reject the connection with a certificate hostname mismatch. If this occurs, use `--insecure-skip-tls-verify=true` on this specific `set-cluster` command for homelab convenience, or (preferred, and shown in Step 6) add `127.0.0.1` as a certificate SAN at `kubeadm init` time.

## Step 6 (Recommended): Add `127.0.0.1` as a Certificate SAN

A cleaner long-term fix is to include the loopback address as an additional API server certificate SAN when initializing the control plane, so tunneled access never triggers a certificate mismatch:

```bash
# Alternative kubeadm init invocation (on master, done once, before or in place of 07-Kubeadm-ControlPlane.md's version)
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=10.10.10.10 \
  --control-plane-endpoint=10.10.10.10 \
  --apiserver-cert-extra-sans=127.0.0.1,localhost
```

If the cluster is already initialized, you can regenerate just the API server certificate with the extra SAN using `kubeadm init phase certs apiserver --apiserver-cert-extra-sans=127.0.0.1,localhost`, followed by a `kubelet`/static-pod restart to pick up the new certificate.

## Step 7: Verify

```bash
kubectl get nodes -o wide
```

**Expected output:** all three nodes, `Ready`, identical to what you'd see running the same command directly on `master`.

---

## Making the Tunnel Persistent (Optional but Recommended)

Add this to `~/.ssh/config` so the tunnel is established automatically whenever you connect:

```
Host master
    HostName 10.10.10.10
    User vm1
    ProxyJump root@192.168.1.20
    LocalForward 6443 10.10.10.10:6443
```

With `LocalForward` set here, simply running `ssh -f -N master` re-establishes the tunnel without retyping the full `-L` flag.

---

## Verification

```bash
kubectl cluster-info
kubectl get pods -A
```

Confirm both commands return the same output whether run locally via the tunnel or directly on `master` via SSH — this confirms the tunnel is transparent and not silently talking to a stale/cached state.

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Copying `~/.kube/config` from `master` without also setting up the tunnel | `kubectl` fails with a connection timeout, since `10.10.10.10` isn't reachable from the Mac's network position | Complete Step 4 (SSH tunnel) before expecting direct `kubectl` access to work |
| Forgetting the SSH tunnel is backgrounded and letting your Mac sleep | Tunnel silently drops; `kubectl` starts failing again until reconnected | Re-run `ssh -f -N master` (or the `LocalForward`-based equivalent) after sleep/wake cycles |
| Using `--insecure-skip-tls-verify` permanently instead of fixing the certificate SAN | Works, but silently disables an important security check for every future `kubectl` invocation | Prefer Step 6's certificate SAN approach for a homelab you'll use regularly |

---

## Troubleshooting

**Symptom: `kubectl` reports `dial tcp 127.0.0.1:6443: connect: connection refused`.**
The SSH tunnel from Step 4 isn't running. Check with `ps aux | grep "L 6443"` on your Mac, and re-establish it if absent.

**Symptom: `x509: certificate is valid for 10.10.10.10, ..., not 127.0.0.1`.**
Expected without Step 6. Either add the SAN as shown, or set `insecure-skip-tls-verify: true` on the specific cluster context as a homelab-only convenience.

**Symptom: Tunnel works, but drops every ~10–15 minutes.**
NAT/firewall connection-tracking timeouts on idle TCP sessions are a common cause. Add `ServerAliveInterval 30` under the relevant `Host` block (or a global `Host *` block) in `~/.ssh/config`, as also recommended in [05-SSH.md](05-SSH.md).

---

## Recovery

If the kubeconfig on your Mac becomes stale (e.g. after a full cluster rebuild with new certificates):

```bash
rm ~/.kube/config
scp master:~/.kube/config ~/.kube/config
kubectl config set-cluster kubernetes --server=https://127.0.0.1:6443
```

---

## Best Practices

- Keep exactly one kubeconfig context for this homelab cluster and name it clearly (`kubectl config rename-context kubernetes homelab`) if you manage multiple clusters, to avoid accidentally running a command against the wrong one.
- Prefer the certificate-SAN approach (Step 6) over `--insecure-skip-tls-verify` for anything beyond a quick one-off test — it costs one extra flag at `kubeadm init` time and removes a persistent, easy-to-forget security shortcut.

## Performance Tips

- A single SSH tunnel adds negligible latency for typical `kubectl` usage (listing resources, applying manifests); it will not be a noticeable bottleneck for interactive cluster management.

## Security Tips

- The SSH tunnel model means your Mac never has a direct network path to the API server — every `kubectl` command is authenticated twice over (SSH key to the Proxmox host, then the Kubernetes client certificate/token to the API server itself), which is a meaningfully stronger posture than exposing `6443` directly on the home network.

---

**Next:** [13-Troubleshooting.md](13-Troubleshooting.md) — a consolidated reference of every issue encountered across this build.
