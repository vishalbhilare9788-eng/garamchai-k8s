# ADR-003: Cluster traffic on the static host-only network; Windows access via NAT

- **Status:** Accepted
- **Date:** 2026-09-23

## Context (facts from the Phase 0 audit)
Each node has two NICs:

| NIC | VMware type | Addressing | Reachable from Windows? |
|---|---|---|---|
| `ens33` | NAT (VMnet8) | DHCP 192.168.64.128 / .129 / .131, default route to the internet | ✅ yes (tested: `Test-NetConnection 192.168.64.128 -Port 6443` succeeded) |
| `ens34` | Host-only | Static 10.0.0.100 / .1 / .2, mask **/8** | ❌ no (the Windows VMnet1 adapter is on a different subnet) |

What uses which network today:
| Component | Uses |
|---|---|
| API server `--advertise-address`, admin.conf, kubelet.conf | 10.0.0.100 (ens34) |
| API server certificate SANs | `10.0.0.100`, `10.96.0.1`, `kubernetes`, `cka-m`, … (**not** 192.168.64.128) |
| Calico node IP / IPIP tunnels | 10.0.0.x (ens34) |
| **kubelet node InternalIP** | **192.168.64.x (ens33, DHCP)**: the odd one out, because the kubelet defaults to the default-route interface |

Problems:
1. Mixed design. The API server → kubelet traffic (`kubectl logs/exec`) and NodePorts use the DHCP IPs, while everything else uses the static IPs.
2. ens34's `/8` covers all of 10.0.0.0–10.255.255.255, which **contains the Service CIDR 10.96.0.0/16**. Overlapping ranges cause confusing routing when something goes wrong.
3. Windows can't reach 10.0.0.100, and the certificate doesn't include 192.168.64.128.

## Decision
1. **All cluster-internal traffic uses ens34 (static).** Set the kubelet's `--node-ip=10.0.0.x` on each node.
2. **Shrink ens34 to `/24`** (10.0.0.0/24). All nodes still fit, and the overlap with 10.96.0.0/16 disappears.
3. **Windows reaches the cluster via ens33 (NAT)**: kubeconfig `server: https://192.168.64.128:6443` plus `tls-server-name: kubernetes`. The certificate already contains the name `kubernetes`, so there's **no need to regenerate API server certificates**.
4. **MetalLB (Phase 7)** will hand out IPs from 192.168.64.0/24 **below .128** (outside VMware's DHCP pool), because that's the network Windows can reach.
5. Later (optional): add VMware DHCP reservations so the 192.168.64.x addresses can never change.

## Alternatives rejected
- **Regenerate API server certs with 192.168.64.128 in the SANs**: works, but touches the control-plane PKI to add a DHCP address. More risk, less benefit.
- **`insecure-skip-tls-verify: true` in kubeconfig**: disables server identity checking. Never a habit worth forming.
- **Move everything to ens33**: that network is DHCP, which is exactly the instability we're avoiding.

## Consequences
- ✅ The cluster keeps working even if the DHCP addresses change (only Windows access and MetalLB depend on them).
- ✅ No overlapping ranges: Pods 172.17.0.0/16, Services 10.96.0.0/16, Nodes 10.0.0.0/24, LAN 192.168.64.0/24.
- ⚠️ Two networks to keep in mind while troubleshooting. Documented here.
