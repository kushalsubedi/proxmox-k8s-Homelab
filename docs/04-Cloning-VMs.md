# 04 — Cloning the Master and Worker VMs

## Overview

With the template built in [03-Ubuntu-Template.md](03-Ubuntu-Template.md), this document creates the three actual cluster VMs — `master`, `worker1`, `worker2` — as linked clones, each with its own static IP, hostname, and resource allocation.

---

## Target Specification

| VM ID | Hostname | IP | vCPU | RAM | Disk | Role |
|---|---|---|---|---|---|---|
| 101 | `master` | `10.10.10.10/24` | 2 | 2 GB | 35 GB | Control Plane |
| 102 | `worker1` | `10.10.10.11/24` | 2 | 2 GB | 35 GB | Worker |
| 103 | `worker2` | `10.10.10.12/24` | 2 | 2 GB | 35 GB | Worker |

All three share a gateway of `10.10.10.1` (the Proxmox host's `vmbr0` address) and DNS of `1.1.1.1`.

> **Note on resource math:** 3 VMs × 2 GB RAM = 6 GB, leaving roughly 10 GB for the Proxmox host and its own services on a 16 GB machine — comfortable headroom. 3 VMs × 2 vCPU = 6 vCPU scheduled against 4 physical cores; this is intentional oversubscription, which is normal and expected in homelab virtualization as long as all three VMs are not simultaneously CPU-bound (discussed further in [14-Best-Practices.md](14-Best-Practices.md)).

---

## Step 1: Clone the Template

```bash
qm clone 9000 101 --name master   --full false
qm clone 9000 102 --name worker1  --full false
qm clone 9000 103 --name worker2  --full false
```

`--full false` requests a **linked clone** — each new VM references the template's base disk and only stores block-level differences, which is faster to create and uses less SSD space than a full clone. This is safe here because the template is never booted or modified after being converted with `qm template`.

## Step 2: Set Per-VM Static Networking via Cloud-Init

```bash
qm set 101 --ipconfig0 ip=10.10.10.10/24,gw=10.10.10.1
qm set 102 --ipconfig0 ip=10.10.10.11/24,gw=10.10.10.1
qm set 103 --ipconfig0 ip=10.10.10.12/24,gw=10.10.10.1
```

This overrides the template's `ipconfig0=dhcp` default (from [03-Ubuntu-Template.md](03-Ubuntu-Template.md)) on a per-clone basis. Static addressing is used, rather than DHCP with reservations, because there is no DHCP server running on the isolated `10.10.10.0/24` network at all (see [02-Proxmox-Networking.md](02-Proxmox-Networking.md)) — every address on this network is assigned explicitly.

## Step 3: Set Hostnames

```bash
qm set 101 --name master
qm set 102 --name worker1
qm set 103 --name worker2
```

(These were already set at clone time via `--name`, shown here for completeness since hostname is also reflected into cloud-init's `meta-data` at next boot.)

## Step 4: Confirm Resource Allocation Matches Spec

```bash
for id in 101 102 103; do
  qm set $id --memory 2048 --cores 2
done
```

## Step 5: Start the VMs

```bash
qm start 101
qm start 102
qm start 103
```

Cloud-init runs on first boot of each clone, applying the hostname, static IP, and SSH key baked into the template plus the per-clone `ipconfig0` override from Step 2.

## Step 6: Confirm IP Assignment via QEMU Guest Agent

```bash
qm guest cmd 101 network-get-interfaces
qm guest cmd 102 network-get-interfaces
qm guest cmd 103 network-get-interfaces
```

**Expected output:** each command returns JSON listing an interface with the expected `10.10.10.1x` address. This confirms both that cloud-init applied the network config correctly and that the QEMU Guest Agent (enabled in the template) is running and responsive inside the guest.

---

## Verification

```bash
# From the Proxmox host
for ip in 10.10.10.10 10.10.10.11 10.10.10.12; do
  ping -c 2 $ip
done
```

**Expected output:** all three addresses respond, 0% packet loss.

```bash
qm list
```

**Expected output:** three running VMs (`master`, `worker1`, `worker2`), each showing status `running`.

---

## Common Mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Cloning with `--full true` unnecessarily | Slower clone operation, more SSD usage, no benefit for this use case | Use `--full false` (linked clone) since the template is immutable |
| Forgetting to override `ipconfig0` per clone | All three VMs attempt DHCP and get no address (no DHCP server on `vmbr0`) | Explicitly set static `ipconfig0` per VM as shown in Step 2 |
| Assigning the same static IP to two clones by copy-paste error | IP conflict; one or both VMs become unreachable or flap | Double-check each `qm set <id> --ipconfig0` command's IP against the table at the top of this document |

---

## Troubleshooting

**Symptom: `qm guest cmd` returns "QEMU guest agent is not running".**
The guest agent daemon (`qemu-guest-agent`) may not have started yet on first boot, or the package may be missing from the cloud image (uncommon for official Ubuntu cloud images, which include it by default). Wait 30–60 seconds after `qm start` and retry; if it persists, console into the VM and run `systemctl status qemu-guest-agent`.

**Symptom: VM boots but has no IP / cloud-init didn't apply the static config.**
Console into the VM (Proxmox Web UI → VM → Console) and run `cloud-init status --long`. If it reports an error, check `/var/log/cloud-init.log` inside the guest for the specific `network-config` parsing failure, and re-verify the `qm set --ipconfig0` syntax exactly matches the format shown in Step 2 (`ip=<addr>/<prefix>,gw=<gateway>`).

---

## Recovery

If a clone becomes corrupted or misconfigured beyond easy repair:

```bash
qm stop <vmid>
qm destroy <vmid>
qm clone 9000 <vmid> --name <name> --full false
qm set <vmid> --ipconfig0 ip=<addr>/24,gw=10.10.10.1
qm start <vmid>
```

Because the template is untouched, recreating any single node takes under a minute and does not affect the other two.

---

## Best Practices

- Reserve VM IDs 101–103 specifically for `master`/`worker1`/`worker2`, and document any future additions (e.g. a `worker3` at 104) in this same table for consistency.
- Snapshot each VM (`qm snapshot <vmid> clean-install`) immediately after this step, before Kubernetes is installed — this gives you an instant rollback point if a later step goes wrong.

## Performance Tips

- Linked clones share the template's base disk; avoid deleting or modifying the template (VM 9000) while any clones still exist, as this can corrupt the shared base layer.

## Security Tips

- Since the SSH key was already baked into the template, no clone requires a password to be set — verify `qm config <vmid>` shows no `cipassword` set for any of the three nodes.

---

**Next:** [05-SSH.md](05-SSH.md) — configuring SSH ProxyJump access from macOS to all three nodes through the Proxmox host.
