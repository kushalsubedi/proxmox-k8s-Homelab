# 12 — Configuring `kubectl` on macOS

## Overview

This guide configures `kubectl` on your MacBook so you can manage your Kubernetes homelab directly from macOS.

Cluster information:

| Component | IP Address |
|------------|------------|
| Proxmox Host | `192.168.1.20` |
| Master | `10.10.10.10` |
| Worker 1 | `10.10.10.11` |
| Worker 2 | `10.10.10.12` |

The Kubernetes API server is running on the control-plane node (`10.10.10.10:6443`).

Your Mac reaches the Kubernetes network through the Proxmox host.

---

# Step 1 — Install kubectl

Install kubectl.

```bash
brew install kubectl
```

Verify the installation.

```bash
kubectl version --client
```

Example:

```
Client Version: v1.34.x
```

---

# Step 2 — Configure Routing to the Kubernetes Network

The Kubernetes nodes are on the internal subnet:

```
10.10.10.0/24
```

Configure your Mac to reach this network through the Proxmox host.

```bash
sudo route -n add -net 10.10.10.0/24 192.168.1.20
```

Verify the route.

```bash
netstat -rn | grep 10.10.10
```

Expected output:

```
10.10.10/24    192.168.1.20
```

---

# Step 3 — Copy the kubeconfig

Create the kubeconfig directory.

```bash
mkdir -p ~/.kube
```

Copy the configuration from the control-plane node.

```bash
scp master:~/.kube/config ~/.kube/config
```

Because your SSH configuration already uses `ProxyJump`, the copy automatically traverses through the Proxmox host.

Current SSH configuration:

```ssh
Host proxmox
    HostName 192.168.1.20
    User root
    IdentityFile ~/.ssh/id_ed25519

Host master
    HostName 10.10.10.10
    User vm1
    ProxyJump proxmox
    IdentityFile ~/.ssh/id_ed25519

Host worker1
    HostName 10.10.10.11
    User vm1
    ProxyJump proxmox
    IdentityFile ~/.ssh/id_ed25519

Host worker2
    HostName 10.10.10.12
    User vm1
    ProxyJump proxmox
    IdentityFile ~/.ssh/id_ed25519
```

---

# Step 4 — Verify the API Server Endpoint

Check the current endpoint.

```bash
kubectl config view --minify
```

You should see something similar to:

```yaml
clusters:
- cluster:
    server: https://10.10.10.10:6443
```

Since the route to the Kubernetes network has already been configured, no additional SSH tunnel is required.

---

# Step 5 — Verify Cluster Connectivity

Verify that kubectl can communicate with the cluster.

```bash
kubectl cluster-info
```

Example:

```
Kubernetes control plane is running at https://10.10.10.10:6443
```

---

List the nodes.

```bash
kubectl get nodes -o wide
```

Expected output:

```
NAME      STATUS   ROLES           AGE
master    Ready    control-plane   xxm
worker1   Ready    <none>          xxm
worker2   Ready    <none>          xxm
```

---

Verify the system pods.

```bash
kubectl get pods -A
```

Expected output includes:

- coredns
- cilium
- kube-apiserver
- kube-controller-manager
- kube-scheduler
- etcd

All pods should be in the **Running** state.

---

# Useful Commands

Cluster information.

```bash
kubectl cluster-info
```

List nodes.

```bash
kubectl get nodes
```

List all pods.

```bash
kubectl get pods -A
```

Describe a node.

```bash
kubectl describe node master
```

List namespaces.

```bash
kubectl get ns
```

View events.

```bash
kubectl get events -A
```

---

# Troubleshooting

## Verify the route

```bash
netstat -rn | grep 10.10.10
```

---

## Verify connectivity

```bash
ping 10.10.10.10
```

---

## Verify the API endpoint

```bash
kubectl config view --minify
```

---

## Verify cluster connectivity

```bash
kubectl cluster-info
```

---

## Verify nodes

```bash
kubectl get nodes
```

---

## Verify pods

```bash
kubectl get pods -A
```

---

# Recovery

If the cluster is rebuilt:

```bash
rm -rf ~/.kube

mkdir -p ~/.kube

scp master:~/.kube/config ~/.kube/config
```

Verify the API endpoint.

```bash
kubectl config view --minify
```

Test connectivity.

```bash
kubectl get nodes
```

---

# Best Practices

- Keep the Kubernetes client version aligned with the cluster version.
- Use the SSH aliases defined in `~/.ssh/config`.
- Access the Kubernetes API directly through the routed network.
- Keep your SSH private key secure.
- Re-copy the kubeconfig whenever the control plane is rebuilt.

---

# Next

Continue to **13-Troubleshooting.md**.
