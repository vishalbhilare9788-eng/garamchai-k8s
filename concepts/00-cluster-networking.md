# Cluster Networking: Our Lab, CoreDNS, and Production Design

> Written after Phase 0 (2026-09-23), when we fixed the lab network (ADR-003).
> Part 1 = our lab in plain words · Part 2 = CoreDNS · Part 3 = how to design K8s networking in production (interview-ready)

---

# Part 1: Our lab network in plain words

## 1.1 The analogy
Think of your laptop as a **building**, and the 3 VMs as **3 flats** inside it.

| Real thing | Analogy |
|---|---|
| Windows laptop | The building owner's office |
| VMware NAT network (VMnet8), **192.168.64.0/24** | The **main road**: connects the flats to the owner's office and, through the gate, to the outside world (internet) |
| VMware host-only network, **10.0.0.0/24** | A **private corridor** only between the flats. The owner's office has no door onto it |
| Pod network **172.17.0.0/16** | The **rooms inside each flat**. Each flat numbers its own rooms from its own block |
| Service network **10.96.0.0/16** | **Reception desk phone extensions**: numbers that don't belong to any room. When you dial one, reception forwards you to a real room |
| CoreDNS | The **building's phone directory**: you ask "discount-service", it tells you the extension number |

## 1.2 The four networks (and why they must never overlap)

| # | Network | Range | Real or virtual? | Who gives out the addresses | Used for |
|---|---|---|---|---|---|
| 1 | LAN / NAT (`ens33`) | 192.168.64.0/24 | Real (VMware virtual NIC) | VMware DHCP (.128–.254) | Internet access, **Windows → cluster**, MetalLB IPs later |
| 2 | Node / cluster network (`ens34`) | 10.0.0.0/24 | Real (VMware virtual NIC) | **Static** (we set them) | Node-to-node traffic: API server, kubelet, etcd, Calico tunnels |
| 3 | Pod network | 172.17.0.0/16 | Virtual (Calico) | Calico IPAM, a /26 block per node | Every pod gets an IP from here |
| 4 | Service network | 10.96.0.0/16 | **Purely virtual**: exists on no interface | API server | Stable virtual IPs (ClusterIP) in front of pods |

**Why no overlap:** a Linux machine decides where to send a packet by looking up the destination in its **routing table**. If two networks share addresses, the lookup can pick the wrong one. Before our fix, ens34 was `10.0.0.0/8`, which means "10.0.0.0 to **10.255.255.255** is on ens34", and that includes the whole Service range 10.96.x.x. It happened to work, because kube-proxy rewrites Service IPs before they go out, but any hiccup would have sent packets down the wrong interface: the worst kind of bug to debug. `/24` means only 10.0.0.0–10.0.0.255, so there's no more overlap.

## 1.3 The design diagram (real addresses from our cluster)

```
                                   INTERNET
                                      │
                          ┌───────────┴───────────┐
                          │  Windows 11 laptop    │
                          │  VMnet8 = 192.168.64.1 │   kubectl, browser, Docker Desktop
                          └───────────┬───────────┘
                                      │ VMware NAT gateway 192.168.64.2 (DHCP + NAT to internet)
 ═════════════════════════════════════╪═══════════════════════════════════════════════════════
  NETWORK 1: LAN / NAT  192.168.64.0/24  (ens33, DHCP)        ← Windows CAN reach this
 ══════════╤══════════════════════════╤═══════════════════════════════╤════════════════════════
           │ .128                     │ .129                          │ .131
 ┌─────────┴──────────┐     ┌─────────┴──────────┐          ┌─────────┴──────────┐
 │ cka-m (master)     │     │ cka-w1 (worker)    │          │ cka-w2 (worker)    │
 │                    │     │                    │          │                    │
 │ kube-apiserver:6443│     │ kubelet            │          │ kubelet            │
 │ etcd, scheduler,   │     │ kube-proxy         │          │ kube-proxy         │
 │ controller-manager │     │ calico-node        │          │ calico-node        │
 │ CoreDNS ×2         │     │                    │          │                    │
 │                    │     │                    │          │                    │
 │ pods: 172.17.44.0/26│    │ pods: 172.17.95.128/26│       │ pods: 172.17.62.128/26│
 │   └ tunl0 (IPIP)   │     │   └ tunl0 (IPIP)   │          │   └ tunl0 (IPIP)   │
 └─────────┬──────────┘     └─────────┬──────────┘          └─────────┬──────────┘
           │ .100                     │ .1                            │ .2
 ══════════╧══════════════════════════╧═══════════════════════════════╧════════════════════════
  NETWORK 2: CLUSTER  10.0.0.0/24  (ens34, host-only, STATIC)  ← Windows can NOT reach this
  carries: API server traffic, kubelet, Calico IPIP tunnels (pod-to-pod across nodes)
 ═════════════════════════════════════════════════════════════════════════════════════════════

  NETWORK 3: PODS     172.17.0.0/16   virtual, carried INSIDE network 2 by IPIP tunnels
  NETWORK 4: SERVICES 10.96.0.0/16    virtual, exists only as iptables rules on every node
             10.96.0.1  = "kubernetes" Service (API server)
             10.96.0.10 = "kube-dns"  Service (CoreDNS)
```

## 1.4 Follow the packet: the 6 journeys that matter

**① kubectl on Windows → API server**
```
Windows 192.168.64.1 ──(network 1)──► 192.168.64.128:6443 (cka-m ens33) ──► kube-apiserver
```
The API server listens on **all** interfaces, so it answers on .128 too. Its certificate only lists `10.0.0.100` and the name `kubernetes`, so kubectl checks the name `kubernetes` (`tls-server-name`) instead of the IP.

**② Worker → API server** (the kubelet reporting "I'm alive", fetching pods to run)
```
cka-w1 10.0.0.1 ──(network 2)──► 10.0.0.100:6443
```
Static on both ends, so a DHCP change can never break this.

**③ Pod on w1 → pod on w2** (e.g. order-service → discount-service pod)
```
pod 172.17.95.130 ──► tunl0 on cka-w1
     wraps the packet in an outer envelope:  [ from 10.0.0.1 → to 10.0.0.2 [ from 172.17.95.130 → to 172.17.62.131 ] ]
──(network 2)──► cka-w2 unwraps it ──► pod 172.17.62.131
```
This is **IPIP encapsulation** (IP-in-IP): an envelope inside an envelope. How does cka-w1 know that 172.17.62.128/26 lives on cka-w2? Calico's BGP agent (`bird`) shares routes between nodes. You saw them in `ip route`:
```
172.17.62.128/26 via 10.0.0.2 dev tunl0 proto bird
172.17.95.128/26 via 10.0.0.1 dev tunl0 proto bird
```

**④ Pod → Service IP** (e.g. a pod asks DNS at 10.96.0.10)
```
pod ──► dst 10.96.0.10:53
        iptables rules (written by kube-proxy on EVERY node) rewrite the destination:
        10.96.0.10 → one of the CoreDNS pods (172.17.44.7 or 172.17.44.9)   ← DNAT
    ──► then travels like journey ③ to cka-m
```
No machine "owns" 10.96.0.10. It's a rule, not an interface. That's why you can't ping a Service IP (ICMP isn't covered by the rules), but you **can** connect to its port.

**⑤ Pod → internet** (e.g. pulling data from an external API)
```
pod 172.17.95.130 ──► node rewrites the source to its own IP (SNAT / masquerade; Calico natOutgoing)
──► ens33 ──► VMware NAT 192.168.64.2 ──► Windows ──► internet
```

**⑥ Browser → GaramChai (Phase 7, not built yet)**
```
Windows browser ──► https://garamchai.test (hosts file → 192.168.64.50, a MetalLB IP)
──► MetalLB answers "192.168.64.50 is at cka-w1's MAC" (ARP) ──► Traefik ──► frontend / API pods
```
This is why MetalLB IPs must come from **network 1** (Windows can reach it) and **below .128** (outside VMware's DHCP pool, so nothing else ever gets the same IP).

## 1.5 What exactly we changed in Phase 0, and why

| Change | Before | After | Why |
|---|---|---|---|
| ens34 mask | 10.0.0.x**/8** | 10.0.0.x**/24** | Removed the overlap with the Service range 10.96.0.0/16 |
| kubelet `--node-ip` (in `/etc/default/kubelet`) | not set, so the kubelet picked ens33 (DHCP) | 10.0.0.100 / .1 / .2 | The node's **InternalIP** is now static. The API server uses it to reach the kubelet (`kubectl logs`, `exec`, port 10250), and host-network pods use it as their IP |
| Calico | node IP 10.0.0.x/8 | 10.0.0.x/24 (restarted the DaemonSet) | Picks up the new mask |
| Windows kubeconfig | `server: 10.0.0.100` (unreachable from Windows) | `server: 192.168.64.128` + `tls-server-name: kubernetes` | Windows can reach it, and certificate checking stays on |

What we did **not** change: CoreDNS, kube-proxy, the Service CIDR, the Pod CIDR, certificates.

---

# Part 2: CoreDNS

## 2.1 What is it?
**CoreDNS is the cluster's phone directory.** Pods get new IPs every time they restart, so nobody should use pod IPs directly. Apps use **names** (`discount-service`), and CoreDNS turns the name into the Service's stable IP.

## 2.2 How it's deployed (look for yourself)
```bash
kubectl -n kube-system get deployment coredns        # 2 replicas, for HA
kubectl -n kube-system get svc kube-dns              # ClusterIP 10.96.0.10, ports 53/UDP, 53/TCP, 9153 (metrics)
kubectl -n kube-system get configmap coredns -o yaml # its config file, the "Corefile"
```
Yes, the Service is still called **kube-dns**. It's the historical name from before CoreDNS replaced kube-dns, kept for compatibility. That's a classic interview trick question.

## 2.3 How a pod finds it
When the kubelet starts a pod, it writes the pod's `/etc/resolv.conf`:
```
nameserver 10.96.0.10                                                   ← CoreDNS Service IP
search garamchai.svc.cluster.local svc.cluster.local cluster.local     ← suffixes to try
options ndots:5
```
Try it: `kubectl run t --image=busybox:1.36 --rm -it --restart=Never -- cat /etc/resolv.conf`

## 2.4 Which names it answers

| You ask for | Resolves to | Example in GaramChai |
|---|---|---|
| `<svc>` (same namespace) | Service ClusterIP (via the search list) | order-service calls `http://discount-service` |
| `<svc>.<namespace>` | Service ClusterIP | order-service calls `postgres.garamchai-data` |
| `<svc>.<ns>.svc.cluster.local` | Service ClusterIP (full name, FQDN) | what we tested: `kubernetes.default.svc.cluster.local → 10.96.0.1` |
| headless Service `<svc>` | **all pod IPs** directly | Postgres StatefulSet (Phase 5) |
| `<pod-name>.<svc>.<ns>.svc.cluster.local` | one specific StatefulSet pod | `postgres-0.postgres.garamchai-data.svc.cluster.local` |
| `google.com` | forwarded to the node's upstream DNS (`forward . /etc/resolv.conf` in the Corefile) | a pod calling an external API |

How CoreDNS knows all this: its `kubernetes` plugin **watches the API server** for Services and EndpointSlices, and updates its answers in real time.

## 2.5 What happened in our test, and what we changed in CoreDNS: nothing
We **didn't change CoreDNS**. We used it as a **test**: if a pod on a worker can get an answer from CoreDNS on the master through a Service IP, then journeys ③ and ④ both work after our network changes.

- 1st test, `nslookup kubernetes.default` → NXDOMAIN. CoreDNS **did answer** (`Server: 10.96.0.10`), so the network was fine. But busybox ≥ 1.29's nslookup **ignores the `search` line**, so it asked for the literal name `kubernetes.default`, which doesn't exist.
- 2nd test, the full name `kubernetes.default.svc.cluster.local` → `10.96.0.1` ✅

**`ndots:5`, in short:** if a name has fewer than 5 dots, the resolver tries the search suffixes **first**. So `google.com` (1 dot) is first tried as `google.com.garamchai.svc.cluster.local`, then `google.com.svc.cluster.local`... 3–4 wasted lookups before the real one. At scale this overloads DNS. Fixes: use a trailing dot (`google.com.`), lower `ndots` per pod (`dnsConfig`), or run **NodeLocal DNSCache**.

## 2.6 DNS failure checklist (interview favourite: "a pod can't resolve names, what do you do?")
1. `kubectl -n kube-system get pods -l k8s-app=kube-dns`: are the CoreDNS pods running?
2. `kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns`: does the Service have endpoints?
3. From a test pod: `nslookup kubernetes.default.svc.cluster.local` (FQDN!)
4. `cat /etc/resolv.conf` inside the failing pod
5. `kubectl -n kube-system logs -l k8s-app=kube-dns`
6. A NetworkPolicy blocking **UDP/TCP 53** to kube-system? (We'll hit this in Phase 8.)

---

# Part 3: Designing Kubernetes networking in production

## 3.1 The first principle
> **Networking is the hardest thing to change after a cluster is built.** Pod CIDR, Service CIDR, the CNI and the VPC/subnet layout are effectively permanent; changing them usually means building a new cluster. So network design comes **first**, before any YAML.

## 3.2 The 7 questions an architect answers first (memorise the order)

| # | Question | What you decide | Typical mistake |
|---|---|---|---|
| 1 | **IP plan**: which ranges, how big, and do they collide with anything? | Node/VPC subnets, Pod CIDR, Service CIDR. Check against **corporate LAN, VPN, peered VPCs/VNets, other clusters, on-prem data centres** | Using 10.0.0.0/8 or 172.17.0.0/16 (Docker's default) without checking; picking ranges too small for growth |
| 2 | **CNI (network plugin)**: overlay or routable? | Overlay (VXLAN/IPIP: Calico, Cilium, Flannel) vs pods with real network IPs (AWS VPC CNI, Azure CNI). NetworkPolicy support? eBPF? | Flannel, which doesn't enforce NetworkPolicy; routable pod IPs exhausting the subnet |
| 3 | **Topology & HA**: where do nodes live, how does the control plane survive failure? | Multiple AZs/racks; 3 control-plane nodes (etcd needs an odd number); a **load-balanced API endpoint (VIP)** | A single master; an API server address tied to one machine |
| 4 | **Ingress**: how does traffic get in? | L4 load balancer (cloud LB / MetalLB / F5) + L7 (Ingress/Gateway controller), TLS termination, WAF | Exposing NodePorts to users; no TLS plan |
| 5 | **Egress**: how does traffic get out? | NAT gateway, **fixed egress IPs** (partners whitelist them), egress firewall/proxy | Random egress IPs a bank partner can't whitelist |
| 6 | **DNS**: internal and external | CoreDNS (+ NodeLocal DNSCache at scale), forwarding to corporate DNS, ExternalDNS for public records | Corporate names not resolvable from pods |
| 7 | **Security & segmentation** | Private subnets for nodes, public only for LBs; firewall/security groups; NetworkPolicy **default deny**; encryption in transit (WireGuard/mTLS); private API endpoint | Flat network, everything talks to everything; API server on the internet |

Also check: **MTU** (overlays add headers: IPIP 20 bytes, VXLAN 50. A mismatch causes "small requests work, big ones hang"), **firewall ports** (6443 API, 2379–2380 etcd, 10250 kubelet, 30000–32767 NodePort, 179/TCP BGP, IP protocol 4 for IPIP, 4789/UDP VXLAN), **IPv4/IPv6 dual-stack**, and **observability** (VPC/NSG flow logs, Cilium Hubble).

## 3.3 On-prem vs AWS vs Azure

| Topic | On-prem (kubeadm, like our lab) | AWS (EKS) | Azure (AKS) |
|---|---|---|---|
| Who owns the network | **You**: VLANs, IPs, routers, firewalls | AWS VPC; you design subnets | Azure VNet; you design subnets |
| Node addressing | Static IPs or DHCP **reservations** on a dedicated VLAN | Private subnets, **one per AZ** | Subnet(s) in the VNet |
| Pod networking | Calico/Cilium overlay (IPIP/VXLAN), or BGP peering with the top-of-rack switches for routable pods | **AWS VPC CNI**: pods get **real VPC IPs**, so you need big subnets, or prefix delegation, or a secondary CIDR (e.g. 100.64.0.0/10) | **Azure CNI Overlay** (pods from a private overlay CIDR, the usual default today), Azure CNI with VNet IPs, or Azure CNI powered by Cilium. Kubenet is being retired |
| API server HA | You build it: 3 masters + VIP (**kube-vip** or keepalived + HAProxy) | Managed by AWS; choose public / private / both endpoints | Managed by Azure; **private cluster** option |
| `type: LoadBalancer` | **MetalLB** (L2 or BGP), or hardware like F5 | **AWS Load Balancer Controller**: NLB for Services, ALB for Ingress | Azure Standard Load Balancer; Application Gateway for Containers / AGIC for L7 |
| Egress | Corporate firewall / proxy | **NAT Gateway** per AZ; VPC endpoints for ECR/S3 (so traffic stays private) | NAT Gateway or **Azure Firewall** via UDR (`outboundType`) |
| Firewalling | Physical/virtual firewalls, host firewalls | Security groups (also per pod), NACLs | NSGs, Azure Firewall |
| Hybrid connectivity | — | VPN / **Direct Connect** to on-prem (so IPs must not overlap on-prem!) | VPN / **ExpressRoute** (same overlap rule) |
| Biggest trap | Nobody plans the IPs; DHCP node IPs | **Running out of pod IPs** in small subnets | Choosing a mode that consumes VNet IPs, then running out |

## 3.4 Your 60-second interview answer
> *"When I design Kubernetes networking, I start with the IP plan, because it's the one thing you can't change later. I pick node, pod and service ranges that don't overlap with each other or with anything the cluster will ever connect to: the corporate LAN, VPNs, peered VPCs, other clusters. Then I choose the CNI: an overlay like Calico or Cilium on-prem, or the cloud-native CNI on EKS/AKS, where I have to size subnets for pod IPs or use overlay mode. Then HA: nodes across zones and a load-balanced API endpoint. Then traffic flow: how requests get in (load balancer plus an Ingress or Gateway controller with TLS) and how they get out (NAT gateway with fixed egress IPs). Then DNS, both CoreDNS and integration with corporate DNS. And finally security: private subnets, security groups, default-deny NetworkPolicies and a private API endpoint. In my homelab I actually hit these problems: a /8 on the node network overlapping the service CIDR, and node IPs on DHCP. I fixed them by moving cluster traffic to a static /24 and pinning the kubelet's node IP."*

The last sentence is what makes an interviewer believe you: **a real problem you found and fixed.**

---

## Interview questions from this page
| Question | Short answer |
|---|---|
| Why can't you ping a ClusterIP? | It's virtual: only iptables/IPVS rules for its TCP/UDP ports exist. No interface owns it, and ICMP isn't translated |
| What is the kube-dns Service? | The Service in front of the CoreDNS pods (historical name). Usually the 10th IP of the service CIDR (10.96.0.10) |
| What does `ndots:5` do and why can it hurt? | Names with fewer than 5 dots try the search domains first, so external lookups multiply. Fix with dnsConfig, a trailing dot, or NodeLocal DNSCache |
| Overlay vs routable pod networking? | Overlay wraps pod packets in node packets (IPIP/VXLAN): simple, but has MTU overhead. Routable gives pods real network IPs: no overhead, but consumes network IPs |
| What must not overlap? | Node/VPC, pod, service CIDRs, plus every network the cluster connects to |
| How does traffic reach a LoadBalancer Service on bare metal? | MetalLB assigns an IP and announces it via ARP (L2) or BGP |
| What's the kubelet's `--node-ip` for? | It picks which IP the node reports as InternalIP. It matters on multi-NIC nodes |
