# How a Kubernetes Cluster Comes Alive: the "boot process" of a cluster

> Written 2026-09-24, after we rebuilt the lab cluster from scratch. Every example below comes from **our real outputs**.
> You learned the Linux boot process: power on → BIOS → GRUB → kernel → systemd → login prompt. This page is the same idea for Kubernetes: from empty VMs to "all nodes Ready".

**How to read it:**
- Part 0: who's who
- Part 1: what to decide **before** building
- Parts 2–4: what happens **during** the build, in order
- Part 5: what exists **after**
- Part 6: how the cluster keeps itself running
- Part 7: the Linux boot comparison
- Part 8: interview questions

---

## Part 0: The cast, in plain words

Think of the cluster as a **company office**.

| Component | Runs where | How it runs | Analogy | Real job |
|---|---|---|---|---|
| **kubelet** | every node | normal **systemd service** (the only one!) | The **floor manager** on each floor | Starts and stops containers on its node, reports node health |
| **CRI-O** (container runtime) | every node | systemd service | The **workers** who actually do the job | Pulls images, creates containers (kubelet talks to it via CRI) |
| **etcd** | master | static pod | The **records room**: the company's only ledger | Stores *every* object: pods, services, secrets. If it's lost, the cluster forgets everything (our incident!) |
| **kube-apiserver** | master | static pod | The **front desk**: everyone goes through it | The *only* component that talks to etcd. Checks who you are, what you may do, then saves/reads objects |
| **kube-scheduler** | master | static pod | The **seat allocator** | Picks a node for each new pod |
| **kube-controller-manager** | master | static pod | The **supervisors** | Dozens of loops that make reality match the desired state ("3 replicas wanted, 2 running → start 1") |
| **kube-proxy** | every node | DaemonSet pod | The **phone switchboard rules** | Turns Service IPs into iptables rules that forward to real pods |
| **CNI plugin (Calico)** | every node | DaemonSet pod | The **corridors and wiring** | Gives each pod an IP and connects pods across nodes (IPIP tunnels) |
| **CoreDNS** | usually 2 pods | Deployment | The **phone directory** | Turns `discount-service` into a Service IP |
| **Certificates / CA** | files in `/etc/kubernetes/pki` | - | **ID badges**, and the **HR office** that issues them | Every component proves its identity with a certificate signed by the cluster CA |

**Two ideas explain almost everything:**
1. **Everything goes through the API server, and only the API server talks to etcd.** Components never talk to each other directly. They *watch* the API server for changes.
2. **Controllers compare "desired" with "actual" in an endless loop** and fix the difference. That's what "self-healing" means.

---

## Part 1: Before you build: what to decide first

> Rule from the networking page: **networking is the hardest thing to change after a cluster exists.** Decide it first.

### 1A. Network checklist
| # | Decide / check | Why it matters (what breaks if you skip it) | Our lab |
|---|---|---|---|
| 1 | **IP plan**: node network, Pod CIDR, Service CIDR | They must **never overlap** each other, or the LAN, VPN, or Docker's `172.17.0.0/16`. Overlaps create routing bugs that are very hard to find | Nodes 10.0.0.0/24, Pods 172.17.0.0/16, Services 10.96.0.0/16. We hit an overlap: ens34 was /8, which covered 10.96.x |
| 2 | **Static node IPs** (or DHCP reservations) | Certificates, etcd and kubelets remember node IPs. A DHCP change after a reboot breaks the cluster | ens34 static: .100 / .1 / .2 |
| 3 | **Which NIC carries cluster traffic** (multi-NIC nodes) | Otherwise each component picks "the first NIC" on its own, and they can disagree | `advertiseAddress`, kubelet `--node-ip`, Calico `IP_AUTODETECTION_METHOD=cidr=10.0.0.0/24`: all point to ens34 |
| 4 | **A stable API endpoint** (`controlPlaneEndpoint`) | Can't be changed after init. It must be a **DNS name or load-balancer VIP**, never one node's IP, or you can never add a second master | `k8s-api:6443` (split-horizon hosts file) |
| 5 | **Name resolution**: unique hostnames that nodes can resolve | Nodes register under their hostname; duplicates collide | cka-m, cka-w1, cka-w2 |
| 6 | **Firewall ports** open between nodes | 6443 (API), 2379–2380 (etcd), 10250 (kubelet), 10257/10259 (controller-manager/scheduler), 30000–32767 (NodePort), plus the CNI's: BGP 179/TCP, IPIP = IP protocol 4 | No firewall inside our lab |
| 7 | **MTU** | Overlays add a header (IPIP 20 bytes). A mismatch gives "small requests work, big ones hang" | Calico handles it automatically |
| 8 | **Internet / registry access, NTP** | Nodes pull images; certificates and etcd need correct time | ens33 via VMware NAT |
| 9 | **LoadBalancer IP range** (bare metal) | MetalLB needs free IPs outside the DHCP pool | Below 192.168.64.128 (Phase 7) |
| 10 | **CNI choice** | Decides NetworkPolicy support, overlay or not, performance. Flannel doesn't enforce NetworkPolicy | Calico, IPIP Always |

### 1B. OS checklist (every node)
| # | Check | Why | Command |
|---|---|---|---|
| 1 | Same supported OS and version on all nodes | Fewer surprises | `cat /etc/os-release` |
| 2 | **Unique hostname, MAC and product_uuid** | Cloned VMs often share these, and kubeadm rejects or confuses them | `cat /sys/class/dmi/id/product_uuid` |
| 3 | **Swap off** (unless deliberately configured) | The kubelet refuses to start with swap on by default, because swapping breaks memory limits and eviction | `swapoff -a` + comment it out in `/etc/fstab` |
| 4 | **Kernel modules** `overlay`, `br_netfilter` | overlay = container filesystem layers; br_netfilter lets iptables see bridged pod traffic | `lsmod \| grep -E 'overlay\|br_netfilter'` |
| 5 | **sysctls** `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-iptables=1` | A node must *route* packets for pods; Service rules must see bridged traffic | `sysctl net.ipv4.ip_forward` |
| 6 | **Container runtime** installed, **cgroup driver = systemd**, same as the kubelet | A mismatch makes pods and the kubelet unstable | CRI-O 1.35.8 |
| 7 | **kubeadm, kubelet, kubectl** at the cluster version, and **held** | An `apt upgrade` must not silently upgrade Kubernetes | `apt-mark hold kubeadm kubelet kubectl` |
| 8 | **Time sync** | Certificates have validity windows; etcd hates clock jumps | `timedatectl` → "synchronized: yes" |
| 9 | **Resources**: master ≥ 2 vCPU / 2 GB; disk space for images; a **fast disk for etcd** | etcd fsyncs on every write | 2 vCPU, 3–4 GB, 58–67 GB root |
| 10 | **resolv.conf**: Ubuntu's `127.0.0.53` stub | If pods inherited it, CoreDNS would forward to itself (a loop). The kubelet uses `/run/systemd/resolve/resolv.conf` instead | kubeadm detects this automatically |

### 1C. Design decisions
| Decision | Options | Ours |
|---|---|---|
| Control plane HA? | 1 master (lab) or 3 masters + load balancer (production) | 1 master, but `controlPlaneEndpoint` keeps HA possible |
| etcd placement | **Stacked** (on the masters) or **external** (its own servers) | Stacked |
| Backup plan | etcd snapshot **+ PKI**, copied **off the node**, **restore tested** | Taken and copied to Windows; timer and restore drill next |
| Versions and upgrades | Kubernetes supports N-1 skew between components; upgrade one minor version at a time | v1.35.8 everywhere |
| Certificate expiry | kubeadm leaf certs last **1 year**, CAs 10 years. Upgrades renew them | `kubeadm certs check-expiration` |

**Write all of it into a config file** (`infra/kubeadm/kubeadm-config.yaml`) so the build is repeatable. It's also the "why" record for the next engineer.

---

## Part 2: `kubeadm init`: the boot sequence of the master, stage by stage

This is the order kubeadm really uses. The `[tags]` are the ones you saw in our output.

### Stage 1: `[preflight]`: the POST check
- **What:** checks everything from Part 1B: swap, ports free, runtime reachable, CPU/RAM, required images. With `--dry-run` or `validate` you can check the config itself before this.
- **Layman:** the BIOS self-test. If something is wrong, it stops *before* touching anything.
- **Ours:** it also **pulled the images** (etcd, apiserver, …).

### Stage 2: `[certs]`: print everyone's ID badges
kubeadm becomes a small certificate authority and generates in `/etc/kubernetes/pki`:

| File | What it's for |
|---|---|
| `ca.crt/key` | **The cluster CA.** Signs all the other badges. Whoever has `ca.key` can make an admin badge, so protect it like the crown jewels (that's why the PKI backup is chmod 600) |
| `apiserver.crt` | The API server's own server certificate. Ours lists `k8s-api`, `10.0.0.100`, `10.96.0.1`, `kubernetes.default…` |
| `apiserver-kubelet-client` | The API server's badge when *it* calls kubelets (`kubectl logs/exec`) |
| `etcd/ca`, `etcd/server`, `etcd/peer`, `etcd/healthcheck-client` | etcd has its **own separate CA**. Only holders of an etcd-CA badge may talk to etcd |
| `apiserver-etcd-client` | The API server's badge for etcd |
| `front-proxy-ca/client` | For API aggregation (for example metrics-server) |
| `sa.key/sa.pub` | Not a certificate: the key pair that signs **ServiceAccount tokens** (pod identities) |

### Stage 3: `[kubeconfig]`: give components their login files
Each file = API endpoint + CA + that component's client certificate:
- `admin.conf`: you (group `kubeadm:cluster-admins`, powerful only through RBAC)
- `super-admin.conf`: break-glass (group `system:masters`, **bypasses RBAC**; it's what saved us in the incident)
- `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`

### Stage 4: `[etcd]` + `[control-plane]`: write the static pod manifests
kubeadm writes 4 YAML files into `/etc/kubernetes/manifests/`: etcd, kube-apiserver, kube-controller-manager, kube-scheduler.

**The chicken-and-egg problem, and its solution:** the control plane runs *as pods*, but normally pods are created *through the API server*, which doesn't exist yet. The answer is **static pods**: the kubelet reads these files **directly from disk** and runs them, with no API server needed.
> Linux analogy: the **initramfs**, a tiny system loaded from disk that brings up just enough to mount the real system.

### Stage 5: `[kubelet-start]`: start the floor manager
- Writes `/var/lib/kubelet/config.yaml` (from our KubeletConfiguration) and `kubeadm-flags.env`, then starts the kubelet.
- The kubelet sees the 4 manifests and asks CRI-O to run them. Each gets a **pause container** (holds the pod's network namespace), then the real container.
- They start **at the same time**. The API server crashes and retries until etcd answers; the controller-manager and scheduler retry until the API server answers. **This is why static pods often show restarts after a boot, and it's harmless** (our 5/9/11 counts).

### Stage 6: `[wait-control-plane]`: wait for the health checks
Polls `https://10.0.0.100:6443/livez`, `:10257/healthz` and `:10259/livez` until all are healthy. Ours: API server healthy after 2 s.

**At this moment the API server starts, and IT creates the built-in objects by itself** (not kubeadm):
- the namespaces `default`, `kube-system`, `kube-public`, `kube-node-lease`
- the `kubernetes` Service (10.96.0.1) in `default`
- the **bootstrap RBAC**: `cluster-admin`, `admin`, `edit`, `view`, all the `system:*` roles
- PriorityClasses `system-cluster-critical` and `system-node-critical`, and API priority-and-fairness rules

(This is exactly what we saw in the incident: after etcd lost its data, the API server recreated only *these* at 15:36, and everything kubeadm and Calico had made was missing.)

### Stage 7: `[upload-config]`: save the build settings inside the cluster
- ConfigMap `kube-system/kubeadm-config` (our ClusterConfiguration)
- ConfigMap `kube-system/kubelet-config` (so every node joining later gets the same kubelet settings)

### Stage 8: `[mark-control-plane]`: label and taint the master
- Label `node-role.kubernetes.io/control-plane` (that's why ROLES shows `control-plane`)
- Taint `node-role.kubernetes.io/control-plane:NoSchedule`: normal app pods stay off the master

### Stage 9: `[bootstrap-token]`: prepare the door for new nodes
- Creates a **bootstrap token** (a Secret in kube-system, expires after **24 h**)
- Creates RBAC so token holders may: read nodes, send a certificate request (CSR), and get it **auto-approved**; plus certificate rotation for all kubelets
- Creates ConfigMap `kube-public/cluster-info` with the **CA certificate and API address**, readable by anyone. That's the whole purpose of the `kube-public` namespace: info that a node needs *before* it has credentials.

### Stage 10: `[kubelet-finalize]`
Points the master's kubelet at a **rotating** client certificate, so it renews itself before expiry.

### Stage 11: `[addons]`: the essential add-ons
- **CoreDNS**: Deployment (2 replicas) + Service `kube-dns` (10.96.0.10) + ConfigMap `coredns` (the Corefile) + RBAC
- **kube-proxy**: DaemonSet + ConfigMap `kube-proxy`

### Stage 12: prints the join commands
The master is up, but **NotReady**, and CoreDNS is **Pending**. Why? See Part 4.

---

## Part 3: `kubeadm join`: how a worker gets in safely

The worker has **nothing**: no certificate, no kubeconfig. It only has the join command. The question is: *how do two strangers trust each other?*

| Step | What happens | Layman |
|---|---|---|
| 1. Preflight | Same checks as init | Self-test |
| 2. **Discovery** | Reads `cluster-info` from kube-public. The **token** proves the info really came from the cluster (it's signed with the token), and `--discovery-token-ca-cert-hash` **pins the CA**, so a fake API server can't pretend | "Show me your company's badge-office stamp, and I'll compare it with the fingerprint I was given" |
| 3. **TLS bootstrap** | The kubelet logs in *with the token* (group `system:bootstrappers`) and sends a **CSR**: "please sign a certificate for `system:node:cka-w1`" | A visitor pass is used to apply for a real employee badge |
| 4. **Auto-approval** | The csrapprover controller approves (allowed by the RBAC from stage 9); the controller-manager **signs it with the CA** | HR stamps the badge |
| 5. Real credentials | The kubelet saves the cert (`/var/lib/kubelet/pki/`) and writes `/etc/kubernetes/kubelet.conf`. The token is no longer needed | Visitor pass returned |
| 6. **Node registration** | The kubelet creates its **Node** object, with InternalIP = `--node-ip` (10.0.0.1) | Name on the office board |
| 7. Heartbeat | Every ~10 s the kubelet renews its **Lease** in `kube-node-lease`. If heartbeats stop, the node becomes `NotReady` and later its pods are evicted | "I'm alive" check-ins |
| 8. **DaemonSets react** | The DaemonSet controller sees a new node and creates **kube-proxy** and **calico-node** pods on it | New floor gets its switchboard and wiring |

Why workers have **no kubectl or admin.conf**: the kubelet's own credential is limited by the **Node authorizer** (it can see only its own node and pods). An admin credential on a worker means a container escape = whole-cluster takeover.

---

## Part 4: The CNI: why nothing works until the network plugin is installed

1. Without a CNI config in `/etc/cni/net.d/`, the kubelet reports **`NetworkReady=false`**, so the Node is **NotReady**.
2. The node lifecycle controller adds the taint **`node.kubernetes.io/not-ready:NoSchedule`**, so normal pods can't be scheduled (our CoreDNS `FailedScheduling`).
3. `kubectl apply -f calico.yaml` creates: CRDs, RBAC, the IPPool (172.17.0.0/16), the **calico-node** DaemonSet and **calico-kube-controllers**.
4. calico-node's **init containers copy the CNI binary and config onto the node**. Then its main container starts **BIRD (BGP)**, detects the node IP (our pinned `cidr=10.0.0.0/24`), takes a **/26 block** for the node, and shares routes with the other nodes (`172.17.62.128/26 via 10.0.0.2 dev tunl0 proto bird`).
5. The config file now exists → the kubelet says NetworkReady → the Node goes **Ready** → the taint is removed → CoreDNS gets scheduled.
6. First pod attempts can fail with `stat /var/lib/calico/nodename: no such file`. That's a harmless race; the kubelet retries.

> Linux analogy: the machine is booted, but **the network service hasn't started**. Nothing that needs the network can come up yet.

---

## Part 5: What exists when the cluster is up, and why

| Object | Where | Created by | Purpose / importance |
|---|---|---|---|
| Namespace `default` | - | API server | Where objects go if you don't say otherwise. Don't run real apps here |
| Namespace `kube-system` | - | API server | The cluster's own components. **Cannot be deleted** |
| Namespace `kube-public` | - | API server | Readable by everyone, even unauthenticated. Holds `cluster-info` for joining nodes |
| Namespace `kube-node-lease` | - | API server | One **Lease per node** = heartbeats. Cheap, fast node health |
| Service `kubernetes` (10.96.0.1) | default | API server | How **pods** reach the API server. Its endpoint = 10.0.0.100:6443 |
| Service `kube-dns` (10.96.0.10) | kube-system | kubeadm | CoreDNS's address; written into every pod's `/etc/resolv.conf` |
| ServiceAccount `default` | every namespace | controller-manager | The identity a pod gets if you don't choose one |
| ConfigMap `kube-root-ca.crt` | every namespace | controller-manager | The CA cert, so pods can verify the API server |
| ConfigMaps `kubeadm-config`, `kubelet-config`, `kube-proxy`, `coredns` | kube-system | kubeadm | The cluster's own settings, readable by joining nodes and by upgrades |
| ConfigMap `cluster-info` | kube-public | kubeadm | CA + API address for node discovery |
| Secret `bootstrap-token-xxxxxx` | kube-system | kubeadm | The join token (24 h) |
| ClusterRoles `cluster-admin`, `admin`, `edit`, `view`, `system:*` | cluster | API server (auto-reconciled) | Standard permissions. **Recreated automatically** at every API server start |
| ClusterRoleBindings `kubeadm:*`, `calico-*`, `system:coredns` | cluster | kubeadm / Calico / CoreDNS | **Not** auto-reconciled. If deleted, they stay gone (incident lesson) |
| Leases `kube-controller-manager`, `kube-scheduler` | kube-system | those components | **Leader election**: with 3 masters, only one active controller-manager/scheduler at a time |
| PriorityClasses `system-cluster-critical`, `system-node-critical` | cluster | API server | Critical add-ons are scheduled and kept first under pressure |
| CSRs (`csr-xxxxx`) | cluster | kubelets | Record of node certificate requests and approvals |
| Static pods ×4 | kube-system | kubelet (from files) | The control plane. Visible via the API as **mirror pods**; delete one and it comes straight back, because the file is the truth |

Try it yourself:
```bash
kubectl get ns
kubectl get svc -A
kubectl get cm -A
kubectl get sa -A | head
kubectl get lease -A
kubectl get priorityclass
kubectl get csr
kubectl -n kube-system get secret | grep bootstrap
```

---

## Part 6: The cluster at work: life of one pod
What happens after `kubectl apply -f deployment.yaml`:
1. **kubectl** sends the YAML to the API server (HTTPS, with your client certificate).
2. The API server runs **authentication** (who are you?), then **authorization** (RBAC: may you?), then **admission** (mutating: add defaults such as the ServiceAccount; validating: policies such as Pod Security). Then it **saves to etcd**.
3. The **Deployment controller** sees the new Deployment and creates a **ReplicaSet**. The **ReplicaSet controller** creates **Pods** (with no node assigned yet).
4. The **scheduler** sees the unassigned pods, **filters** the nodes (resources, taints, affinity), **scores** the rest, and **binds** each pod to a node.
5. The **kubelet** on that node sees "a pod for me". It asks CRI-O to create the **sandbox** (pause container), then calls the **CNI** (Calico): a veth pair `cali…`, an IP from the node's /26, and a `/32` route. Then it pulls the image and starts init containers, then app containers.
6. The kubelet runs the **probes** and reports status to the API server. Readiness passes → the pod is `Ready`.
7. If a **Service** selects the pod, the **EndpointSlice controller** adds its IP. **kube-proxy on every node** updates iptables. **CoreDNS** already answers the Service name.
8. From then on, **controllers keep comparing desired with actual**. If a pod dies, the ReplicaSet creates a new one; if a node dies, its pods are rescheduled. Nobody "runs" the cluster; the loops do.

---

## Part 7: Linux boot vs cluster boot, side by side

| Linux boot | Kubernetes cluster | What it has in common |
|---|---|---|
| Power on, BIOS POST | `kubeadm` **preflight** | Hardware and prerequisite checks; stop early if something is wrong |
| Firmware keys, secure boot | **certs** + **kubeconfig** | Establish trust and identity before anything runs |
| GRUB loads the kernel from disk | **systemd starts the kubelet**; the kubelet reads **static pod files** from disk | The first program started the old-fashioned way, with no dependencies |
| Kernel + initramfs | **etcd + kube-apiserver** | The core everything else depends on |
| systemd (PID 1) starts and supervises services | **controller-manager + scheduler** | Start things and keep them running (restart what dies) |
| Network service comes up | **CNI (Calico)** → node Ready | Until the network exists, most services can't start |
| Services start (sshd, cron, …) | **Add-ons**: CoreDNS, kube-proxy | Useful services that run on the core |
| Login prompt | `kubectl get nodes` → all **Ready** | The system is usable |
| `/etc/fstab`, `/etc/systemd/*` | etcd (desired state) | Where "how things should be" is stored |
| `journalctl` | `kubectl get events`, `kubectl logs`, `journalctl -u kubelet` | Where you look when boot fails |

---

## Part 8: Interview questions from this page
| Question | Short answer |
|---|---|
| How does the control plane start if it runs as pods? | **Static pods**: the kubelet runs manifests from `/etc/kubernetes/manifests` without the API server |
| Which component talks to etcd? | **Only the kube-apiserver** |
| Why is a new node NotReady? | No CNI yet: the kubelet reports NetworkReady=false |
| How does a joining node trust the cluster, and vice versa? | Bootstrap token (the node proves itself) + CA cert hash (the node verifies the cluster) → TLS bootstrap via an auto-approved CSR |
| What are kube-public and kube-node-lease for? | Public discovery info (cluster-info); node heartbeat Leases |
| admin.conf vs super-admin.conf? | admin = `kubeadm:cluster-admins` via RBAC; super-admin = `system:masters`, bypasses RBAC, break-glass only |
| What does `controlPlaneEndpoint` give you, and why set it at init? | A stable API address for HA. It's baked into certs and kubeconfigs, so changing it later is painful |
| Which default objects come back by themselves if deleted? | Bootstrap RBAC and default namespaces (the API server reconciles them). kubeadm, CNI and addon objects do **not** |
| Why do control-plane pods show restarts after a reboot? | They start in parallel; the API server waits for etcd, and the others wait for the API server |
| What must you back up? | etcd snapshot **and** `/etc/kubernetes/pki`, off the node, and test the restore |
