# Phase 0: Foundation & Cluster Audit

## Why this phase?
An architect never deploys onto infrastructure they haven't inspected. Before writing one YAML we need to know: **What version? What's running? How much capacity do we really have? What restrictions (taints) exist?** Every later decision depends on these numbers.

> **Lesson already learned in this phase:** in planning we were told the workers had 2 GB RAM. The audit shows **4 GB**. We also found a problem nobody mentioned: **disk**. Always trust measured data over what anyone remembers, including yourself.

---

## Step 0.1: Audit the cluster ✅ done 2026-09-23

<details><summary>Commands we ran (click to expand)</summary>

```bash
# A. Versions & nodes
kubectl version
kubectl get nodes -o wide
# B. Capacity vs allocatable, taints
kubectl describe nodes | grep -A 7 -E "^Name:|Capacity:|Allocatable:"
kubectl describe nodes | grep -E "^Name:|Taints:"
# C. What's running
kubectl get pods -A -o wide
kubectl get ns
kubectl get storageclass
kubectl get svc -A | grep LoadBalancer
# D. Calico
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E "cidr|ipipMode|vxlanMode"
# E. On each node
hostname; free -h; nproc; df -h /
# F. metrics-server
kubectl top nodes
```
</details>

### Audit results (baseline)

| Item | Value | Verdict |
|---|---|---|
| Kubernetes version | v1.35.8 (client = server) | ✅ Current, no version skew |
| Nodes | `cka-m` 192.168.64.128 (control-plane), `cka-w1` .129, `cka-w2` .131 | ✅ All Ready |
| Node subnet | 192.168.64.0/24 (VMware NAT, VMnet8) | ⚠️ VMware DHCP hands out .128–.254, so MetalLB must use addresses **below .128** |
| OS / kernel | Ubuntu 24.04.4 LTS / 6.8.0-139 | ✅ |
| Container runtime | **CRI-O 1.35.8** (not containerd) | ℹ️ Docs corrected. Use `crictl`, not `docker`/`ctr`, on nodes |
| CNI | Calico, manifest install in `kube-system` (not operator), IPIP `Always`, VXLAN `Never` | ✅ NetworkPolicy supported |
| Pod CIDR | 172.17.0.0/16 | ⚠️ Same range as Docker's default bridge. **Never install Docker on these nodes** |
| CPU / RAM per node | 2 vCPU / 3.8 GiB, **allocatable ≈ 3.58 GiB** | ✅ About 7.1 GiB for pods across 2 workers. Much better than assumed |
| Disk (root) | cka-m 12 G (69 % used) · cka-w1 9.8 G (**78 %**) · cka-w2 9.8 G (**83 %**) | ❌ **Blocker** |
| Taints | cka-m: `control-plane:NoSchedule` (normal) · cka-w2: **`node.kubernetes.io/disk-pressure:NoSchedule`** | ❌ **cka-w2 cannot accept new pods** |
| StorageClass / LoadBalancer | none / none | ℹ️ Expected on kubeadm (Phases 5 and 7) |
| metrics-server | not installed | ℹ️ Expected (Phase 10) |
| Leftover workloads | `argocd` (broken: dex Evicted/Error, repo-server stuck Init, server 0/1), nginx ×4 in `default`, nginx ×4 in `dev` | ⚠️ Consuming RAM and disk on cka-w1 |
| Recent restarts | kube-apiserver, controller-manager (5), scheduler (3) restarted a few minutes before the audit | 🔍 Probably the VMs just booted. **Re-check in 15 min.** If restarts keep climbing, it points to slow disk/etcd |

### Finding 1 (blocker): cka-w2 is under DiskPressure
**What happened:** the kubelet on each node watches free disk space. When free space on the filesystem holding images falls below its **eviction threshold** (default: `imagefs.available < 15%`, `nodefs.available < 10%`), the kubelet:
1. marks the node condition `DiskPressure=True`,
2. Kubernetes automatically adds the taint `node.kubernetes.io/disk-pressure:NoSchedule` so the scheduler stops sending pods there,
3. starts **evicting** pods to free space (that's your `argocd-dex-server ... Evicted` pod).

cka-w2 has 17 % free, close enough to the line to flip back and forth. Result: **every pod is landing on cka-w1**, so we effectively have a 1-worker cluster. cka-w1 (22 % free) is next.

**Why the disks are so small:** the Ubuntu server installer with LVM, by default, gives the root volume only **about half** of the disk and leaves the rest unused in the volume group. You may have free space already sitting there.

> ❗ Do **not** remove the disk-pressure taint by hand (`kubectl taint ... -`). The kubelet owns it and re-adds it immediately. Fix the cause (disk) and the taint disappears on its own. Interview point: *condition taints are managed by Kubernetes, not by you.*

---

## Step 0.1a: Fix disk space (do this FIRST, on all 3 nodes)

### 1. Check if free space is hidden in LVM (on each node, via PuTTY)
```bash
lsblk                 # shows disks (sda), partitions (sda1..3) and the LVM volume
sudo vgs              # look at the "VFree" column
```
- **If `VFree` is greater than 0** → go to step 3 (no VMware change needed).
- **If `VFree` is 0** → do step 2 first.

### 2. (Only if VFree = 0) Grow the virtual disk in VMware
Do **one node at a time**, workers first.
```bash
# On cka-m: move pods off the worker safely before shutting it down
kubectl drain cka-w2 --ignore-daemonsets --delete-emptydir-data
```
1. On the worker: `sudo shutdown now`
2. VMware: **VM → Settings → Hard Disk → Expand…** → set **40 GB** (master: 50 GB, since it will host NFS later).
   *If "Expand" is greyed out, the VM has snapshots. VMware can't expand a disk with snapshots. Delete or consolidate them first.*
3. Power on, then on the node:
```bash
lsblk                          # confirm sda is now 40G; note the LVM partition number (usually sda3)
sudo growpart /dev/sda 3       # grow partition 3 to fill the disk
sudo pvresize /dev/sda3        # tell LVM the physical volume is bigger
sudo vgs                       # VFree should now show the new space
```
4. Continue with step 3, then on cka-m: `kubectl uncordon cka-w2`

### 3. Extend the root volume and filesystem (online, safe)
```bash
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv   # -r also resizes the ext4 filesystem
df -h /                                                   # confirm the new size
```

### 4. Remove unused container images (on each node)
```bash
sudo crictl images            # what's stored
sudo crictl rmi --prune       # delete images not used by any container
```

### 5. Verify from cka-m
```bash
kubectl describe node cka-w2 | grep -E "Taints|DiskPressure"
# Expected:  Taints: <none>   and   DiskPressure   False
```
Target after the fix: **every node below 50 % disk used.**

---

## Step 0.1b: Clean up leftover workloads (recommended)
We want a clean cluster so that every pod you see is one we created and understand. Argo CD is broken and uses about 500–700 MiB. We can reinstall it properly later as a GitOps stretch goal.

> ⚠️ Only run this if you no longer need these practice deployments.

```bash
# 1. Remove old nginx practice deployments
kubectl delete deployment nginx-deployment -n default
kubectl delete namespace dev

# 2. Remove Argo CD: the namespace first...
kubectl delete namespace argocd

# 3. ...then the CLUSTER-scoped leftovers. Deleting a namespace does NOT delete these!
kubectl get crd | grep argoproj
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io
kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=argocd

# 4. Verify: only kube-system pods should remain
kubectl get pods -A
```
**Concept to remember:** some objects live *inside* a namespace (Pods, Deployments, Services), and some are **cluster-scoped** (Nodes, CRDs, ClusterRoles, PersistentVolumes, StorageClasses). Run `kubectl api-resources --namespaced=false` to list the cluster-scoped kinds.

---

## Step 0.1c: Network cleanup (see ADR-003)
Goal: every piece of cluster traffic uses the **static** host-only network 10.0.0.0/24.
Do **one node at a time: cka-w1, then cka-w2, then cka-m**, and verify after each one.

### Part 1: shrink ens34 from /8 to /24 (on each node)
```bash
cat /etc/netplan/*.yaml                                   # before
sudo sed -i 's#\(10\.0\.0\.[0-9]*\)/8#\1/24#' /etc/netplan/*.yaml
cat /etc/netplan/*.yaml                                   # after: the address must end in /24
sudo netplan apply                                        # PuTTY may freeze 1-2 s; reconnect if it drops
ip -br addr show ens34                                    # expect 10.0.0.x/24
```

### Part 2: pin the kubelet to its static IP (on each node)
```bash
cat /etc/default/kubelet 2>/dev/null                      # must be empty or missing. If it has content, STOP and show Claude
# use this node's own 10.0.0.x address: w1=10.0.0.1, w2=10.0.0.2, m=10.0.0.100
echo 'KUBELET_EXTRA_ARGS=--node-ip=10.0.0.1' | sudo tee /etc/default/kubelet
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager | head -5        # expect: active (running)
```

### Verify from cka-m after each node
```bash
kubectl get nodes -o wide                                 # INTERNAL-IP of that node is now 10.0.0.x, STATUS Ready
```

### After all 3 nodes: refresh Calico and test
```bash
kubectl -n kube-system rollout restart daemonset calico-node
kubectl -n kube-system rollout status daemonset calico-node
kubectl get nodes -o yaml | grep "projectcalico.org/IPv4Address"      # expect 10.0.0.x/24
kubectl get pods -n kube-system                                       # everything Running
# End-to-end test: a pod can resolve DNS through a Service IP
kubectl run nettest --image=busybox:1.36 --rm -it --restart=Never -- nslookup kubernetes.default
```
**Rollback** (if a node goes NotReady): `sudo rm /etc/default/kubelet && sudo systemctl restart kubelet`, and change `/24` back to `/8` in netplan, then `sudo netplan apply`.

---

## Step 0.2: kubectl from Windows

**Why:** you'll write YAML in VS Code on Windows. Running `kubectl` from the same place saves copying files to the master every time. Your Windows laptop can reach the API server because VMware's NAT network (192.168.64.0/24) connects the host to the VMs.

**How it works:** `kubectl` is just a client. It reads a **kubeconfig** file (`~/.kube/config`) that holds three things:
1. **cluster**: API server address (`https://192.168.64.128:6443`) + the cluster CA certificate
2. **user**: credentials (for kubeadm's admin: a client certificate + key)
3. **context**: which user talks to which cluster

### 1. Install kubectl v1.35.8 on Windows (PowerShell)
Why this exact version: kubectl officially supports only **±1 minor version** of the server. `winget` would install the newest version, which may be too far ahead of 1.35.
```powershell
New-Item -ItemType Directory -Force C:\tools\kubectl
curl.exe -Lo C:\tools\kubectl\kubectl.exe "https://dl.k8s.io/release/v1.35.8/bin/windows/amd64/kubectl.exe"

# Add the folder to YOUR user PATH (permanently)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$userPath;C:\tools\kubectl", "User")
```
**Close VS Code completely and reopen it** (the PATH is only read at startup), then:
```powershell
kubectl version --client        # expect: Client Version: v1.35.8
```

### 2. Copy the kubeconfig from the master
The admin kubeconfig on the master is `/etc/kubernetes/admin.conf`. It is readable only by root, and Ubuntu blocks root password login over SSH by default. So we copy it to your normal Linux user first.

On **cka-m** (PuTTY, as root). Replace `<user>` with your normal Linux username (the one you log in with before `sudo`):
```bash
install -m 600 -o <user> -g <user> /etc/kubernetes/admin.conf /home/<user>/admin.conf
```
On **Windows** (PowerShell). The OpenSSH client is built into Windows 11:
```powershell
New-Item -ItemType Directory -Force $HOME\.kube
if (Test-Path $HOME\.kube\config) { Copy-Item $HOME\.kube\config $HOME\.kube\config.bak }   # back up any existing one
scp <user>@192.168.64.128:admin.conf $HOME\.kube\config
```
Back on **cka-m**, delete the temporary copy:
```bash
rm /home/<user>/admin.conf
```

### 3. Point the kubeconfig at an address Windows can reach
The copied file says `server: https://10.0.0.100:6443`. That's the host-only network, which **Windows can't reach**. Windows *can* reach `192.168.64.128`, but the API server's certificate doesn't list that IP, so kubectl would refuse with an `x509: certificate is valid for 10.96.0.1, 10.0.0.100, not 192.168.64.128` error.
The fix: connect to 192.168.64.128, and **verify the certificate against the name `kubernetes`**, which *is* in the certificate. (See ADR-003.)
```powershell
kubectl config get-clusters      # the cluster NAME in our kubeconfig is "networknuts" (set when the cluster was built), not the kubeadm default "kubernetes"
kubectl config set-cluster networknuts --server=https://192.168.64.128:6443 --tls-server-name=kubernetes
```
> ⚠️ `set-cluster <name>` **creates a new entry** if `<name>` doesn't exist. It doesn't complain. Always use the exact name shown by `get-clusters`. (We first ran it with `kubernetes`, which created an unused entry, and kubectl kept connecting to 10.0.0.100.)
> Note: `--tls-server-name=kubernetes` refers to the name in the **certificate**, which is a different thing from the cluster entry's name.

### 4. Test
```powershell
kubectl get nodes
kubectl config get-contexts
```
If it hangs or times out: `Test-NetConnection 192.168.64.128 -Port 6443` should say `TcpTestSucceeded : True`. If it doesn't, the Windows firewall or VMware network settings are blocking it. Paste the output to Claude.

> 🔐 **Security, said honestly:** `admin.conf` is **cluster-admin**. Anyone holding this file can do anything to the cluster. Treat it like a root password. It lives in `C:\Users\<you>\.kube\`, **outside** our repo, and `.gitignore` blocks `*kubeconfig*` anyway. In Phase 8 we'll create a limited "intern" kubeconfig with RBAC. That's how real companies do it.

### 5. (Optional) VS Code Kubernetes extension
Extensions → search **"Kubernetes"** (publisher: Microsoft) → Install. It uses the same kubeconfig and gives you a cluster tree view plus YAML autocomplete. Useful, but **learn the kubectl commands first**, because interviews won't give you a GUI.

---

## Step 0.3: Push this repo to GitHub

### 1. Tell Git who you are (once per laptop, PowerShell)
```powershell
git --version                                   # confirm Git is installed
git config --global user.name  "Vishal Bhilare"
git config --global user.email "<email used on your GitHub account>"
```
If you'll make the repo public and don't want your email visible, use GitHub's private "noreply" address (GitHub → Settings → Emails).

### 2. Create an empty repo on GitHub (browser)
1. github.com → **+** (top right) → **New repository**
2. Name: `garamchai-k8s`
3. Visibility: **Private** for now. We'll make it public (as portfolio proof for interviews) after Phase 2, once we've confirmed no secrets are in it.
4. **Do NOT** tick "Add README", ".gitignore" or "license". We already have them, and adding them creates a conflict on the first push.
5. Click **Create repository** and copy the HTTPS URL: `https://github.com/<your-username>/garamchai-k8s.git`

### 3. First commit and push (PowerShell, in `G:\k8S-with-claude`)
```powershell
cd G:\k8S-with-claude
git status                                  # review what will be committed: no secrets, no kubeconfig
git add -A
git commit -m "Phase 0: project scaffold, architecture v0.2, cluster audit"
git branch -M main                          # rename default branch master -> main
git remote add origin https://github.com/<your-username>/garamchai-k8s.git
git push -u origin main
```
On the first push, a **browser window opens** (Git Credential Manager) asking you to sign in to GitHub. Approve it. No password or token typing is needed.

### 4. Verify
Refresh the GitHub page. You should see `README.md` rendered with the progress checklist.

**Daily workflow from now on:**
```powershell
git status; git add -A; git commit -m "what I did"; git push
```

---

## Phase 0 checklist
- [x] 0.1 Cluster audited, baseline recorded
- [x] 0.1a Disk fixed on all nodes: added a 40 GB `sdb` to each node, joined it to `ubuntu-vg` (pvcreate → vgextend → lvextend -r) together with the ~8 GB that had been left unused. Result: cka-m 67 GB (13 %), cka-w1 62 GB (14 %), cka-w2 58 GB (13 %). cka-w2 taint cleared on its own (`DiskPressure False`). Note: cka-m's disk was also merged into root, so NFS data in Phase 5 will be a directory on `/` (fine for a lab; in production, data goes on a separate disk)
- [x] 0.1b Leftover workloads removed: nginx (default, dev) and Argo CD. Argo CD's 3 CRDs and 6 ClusterRoles/ClusterRoleBindings survived the namespace delete and had to be removed separately
- [ ] Network review. Each node has 2 NICs:
  - `ens33`: DHCP, 192.168.64.128/.129/.131. This is the kubelet **node InternalIP** (the kubelet picks the default-route interface)
  - `ens34`: static, 10.0.0.100 (m) / 10.0.0.1 (w1) / 10.0.0.2 (w2), mask **/8**. The **API server advertises 10.0.0.100** (`--advertise-address`), so the control plane runs on ens34
  - Service CIDR is **10.96.0.0/16**, inside 10.0.0.0/8, so the ranges **overlap** (it works today, but it's a latent issue)
  - Mixed design: control plane on the static network, node IPs on the DHCP network
  - Still to verify: Calico's chosen IP, API server certificate SANs, the kubelet's server URL, the VMware adapter type for ens34, and whether Windows can reach 10.0.0.100 (this affects step 0.2)
- [x] Control-plane restart counts stable: no new restarts in 65 min. The earlier jumps came from the VM reboots when the disks were added (components start before the API server is ready, crash, and retry)
- [x] 0.1c Network cleanup applied: ens34 is /24 on all nodes, the kubelet `--node-ip` points to 10.0.0.x, Calico shows 10.0.0.x/24, and all kube-system pods are Running
  - ⚠️ Mistake made: the w1 command (`--node-ip=10.0.0.1`) was pasted on cka-m and cka-w2 before being corrected. **Lesson: check the per-server values in a copied command before pressing Enter.**
  - DNS test note: `busybox` versions after 1.28 have a buggy `nslookup` that **ignores the search domains** in `/etc/resolv.conf`, so the short name `kubernetes.default` returns NXDOMAIN even when DNS is fine. Test with the full name (FQDN) `kubernetes.default.svc.cluster.local`
- [x] DNS verified with FQDN: `kubernetes.default.svc.cluster.local` → `10.96.0.1` via CoreDNS `10.96.0.10`. This proves the whole path works: pod → IPIP tunnel over 10.0.0.x → Service IP → CoreDNS
- [x] 0.2 `kubectl get nodes` works from Windows (context `kubernetes-admin@networknuts`, server `https://192.168.64.128:6443`, tls-server-name `kubernetes`)
- [x] Second kubectl found: **Docker Desktop** ships its own (`...\DockerDesktop\resources\bin\kubectl.exe`, v1.36.1), and it came first on PATH. Fix: put `C:\tools\kubectl` at the **front** of the user PATH (don't delete Docker's copy, because Docker Desktop restores it on every update)
- [x] `/home/redhat/admin.conf` deleted on cka-m
- [x] 0.3 Repo pushed to GitHub: github.com/vishalbhilare9788-eng/garamchai-k8s (public), first commit d1f3519 on 2026-09-23
- [x] Node IPs: the cluster network (ens34) is static. ens33 is still DHCP, but since the rebuild only the Windows hosts entry for `k8s-api` depends on it
- [ ] Self-check: explain to Claude (1) Capacity vs Allocatable, (2) why cka-w2 got a taint you never added, (3) namespaced vs cluster-scoped objects
