# Phase 0 (extra): Rebuilding the cluster after etcd data loss

## Why this runbook exists
On 2026-09-23 the Windows host hung, the VMs were hard-powered-off, and etcd came back with almost no data (full analysis in `journal/2026-09-23.md`). We rebuild instead of repairing, because an etcd store in an unknown state produces bugs we can't explain later.

The rebuild uses a **versioned config file**, [infra/kubeadm/kubeadm-config.yaml](../../infra/kubeadm/kubeadm-config.yaml). The cluster can then be recreated from Git at any time.

**What survives a `kubeadm reset`:** the OS, CRI-O, kubeadm/kubelet/kubectl packages, cached images, `/etc/default/kubelet` (node-ip), and `/root/k8s-backup-2026-09-23`.
**What is wiped:** `/etc/kubernetes` (certificates, kubeconfigs, manifests), `/var/lib/etcd`, `/var/lib/kubelet` state.

**Every node** means cka-m, cka-w1 and cka-w2. Paste output after every step.

---

## Step R1: Name resolution for `k8s-api` (split-horizon DNS)

**On every node:**
```bash
echo "10.0.0.100 k8s-api" | sudo tee -a /etc/hosts
getent hosts k8s-api                  # expect: 10.0.0.100  k8s-api
```
**On Windows** (Notepad **as Administrator**, file `C:\Windows\System32\drivers\etc\hosts`), add:
```
192.168.64.128 k8s-api
```
Check in PowerShell: `ping -n 1 k8s-api`, and expect replies from 192.168.64.128.

Why: the same name resolves to the right address for whoever is asking. Nodes use the static cluster network; Windows uses the network it can reach.

## Step R2: Copy the config to cka-m and validate it (Windows PowerShell)
```powershell
scp g:\k8S-with-claude\infra\kubeadm\kubeadm-config.yaml redhat@192.168.64.128:~/
```
**On cka-m:**
```bash
sudo kubeadm config validate --config /home/redhat/kubeadm-config.yaml    # catches typos and unknown or duplicate fields BEFORE we destroy anything
```

## Step R3: Reset every node (workers first: w2 → w1 → m)
```bash
sudo kubeadm reset -f --cri-socket unix:///var/run/crio/crio.sock
# kubeadm reset does NOT clean these, so we do it ourselves:
sudo rm -rf /etc/cni/net.d/* /var/lib/calico /root/.kube /home/redhat/.kube
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo reboot                           # clears leftover routes and the tunl0 state the cleanest way
```
After the reboot, check: `ls /etc/kubernetes/manifests` (empty) and `sudo ls /var/lib/etcd` (cka-m: empty or missing).

## Step R4: Initialize the control plane (cka-m)
```bash
sudo kubeadm init --config /home/redhat/kubeadm-config.yaml | tee /root/kubeadm-init.log   # full paths: ~ differs for root and redhat
```
Keep the `kubeadm join ...` command it prints (also saved in /root/kubeadm-init.log), because we need it in R7. Then give `redhat` a kubeconfig. Run this block **as redhat** (`exit` the root shell first), because `$HOME` must be /home/redhat:
```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes                     # cka-m NotReady: expected, because there's no CNI yet
kubectl get pods -n kube-system       # coredns Pending: expected, for the same reason
```

## Step R5: Check the API server certificate
```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```
Expect `k8s-api`, `10.0.0.100` and `10.96.0.1` among the names.

## Step R6: Install Calico v3.32.0 (same version as before)
```bash
curl -fLO https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml
# 1) Pod pool = our pod CIDR (the manifest's commented default is 192.168.0.0/16)
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: "192.168.0.0/16"|  value: "172.17.0.0/16"|' calico.yaml
# 2) STOP and paste this before applying: the indentation must line up
grep -n -B1 -A3 'CALICO_IPV4POOL_CIDR' calico.yaml
grep -n -A1 'CALICO_IPV4POOL_IPIP' calico.yaml          # expect: value: "Always"
```
After Claude reviews the output, add the node-IP detection rule (Calico must use ens34 / 10.0.0.x) and apply:
```bash
# Insert right after the pool CIDR value (12 spaces before "- name", 14 before "value"). s/// with \n, not "a\", keeps the spaces
sed -i 's|^\(              value: "172.17.0.0/16"\)$|\1\n            - name: IP_AUTODETECTION_METHOD\n              value: "cidr=10.0.0.0/24"|' calico.yaml
grep -n -B1 -A5 'CALICO_IPV4POOL_CIDR' calico.yaml     # the 3 env entries must line up
kubectl apply --dry-run=server -f calico.yaml | tail -5  # server-side validation, creates nothing
kubectl apply -f calico.yaml
kubectl get pods -n kube-system -w    # wait: calico-node, calico-kube-controllers, coredns all Running
```

## Step R7: Join the workers (cka-w1, then cka-w2)
```bash
sudo <the kubeadm join command from ~/kubeadm-init.log>
```
On cka-m:
```bash
kubectl get nodes -o wide             # all Ready, INTERNAL-IP 10.0.0.100 / .1 / .2
```

## Step R8: Verify the whole path (same tests as Phase 0)
```bash
kubectl get pods -A -o wide
kubectl run t --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local
kubectl get ippools -o wide 2>/dev/null || kubectl get ippools.crd.projectcalico.org -o yaml | grep -E 'cidr|ipipMode'
```

## Step R9: kubectl from Windows
Back up the old kubeconfig, then copy the new one:
```powershell
Copy-Item $HOME\.kube\config $HOME\.kube\config.old-2026-09-23
scp redhat@192.168.64.128:.kube/config $HOME\.kube\config
kubectl config view --minify | Select-String server      # expect: https://k8s-api:6443
kubectl get nodes
```
There's no `tls-server-name` workaround any more: `k8s-api` is in the certificate, and the Windows hosts file points it to 192.168.64.128.

## Step R10: etcd backup

### R10a: manual snapshot (done 2026-09-23)
```bash
# etcdctl/etcdutl must match the etcd version (3.6.6)
ETCD_VER=v3.6.6
curl -fLO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzf etcd-${ETCD_VER}-linux-amd64.tar.gz
install etcd-${ETCD_VER}-linux-amd64/etcdctl etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/

# Flags come from the etcd static pod manifest
grep -E -- '--(listen-client-urls|trusted-ca-file|cert-file|key-file)=' /etc/kubernetes/manifests/etcd.yaml

install -d -m 700 /var/backups/etcd             # backups contain secrets: root-only
SNAP=/var/backups/etcd/etcd-$(date +%F-%H%M).db
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key snapshot save $SNAP
etcdutl snapshot status $SNAP -w table          # etcdctl snapshot status/restore were removed in 3.6
(umask 077; tar czf /var/backups/etcd/pki-$(date +%F).tgz -C /etc/kubernetes pki)   # CA + keys: restore needs them
```
First snapshot: revision 4794, 505 keys, 3.6 MB. WAL fsync average 1.5 ms (fast only because the host caches writes; see the journal).

### R10b: copy off the node (Windows, outside the repo) (done 2026-09-23)
On cka-m: `install -d -o redhat -m 700 /home/redhat/etcd-export && install -o redhat -m 600 /var/backups/etcd/* /home/redhat/etcd-export/`
On Windows: `scp "redhat@192.168.64.128:etcd-export/*" C:\k8s-backups\etcd\`, then on cka-m `rm -rf /home/redhat/etcd-export`. Compare sizes or hashes on both sides.
### R10c: automate (systemd timer) + restore drill: next session

---

## Rebuild checklist
- [x] R1 `k8s-api` resolves on all nodes and on Windows
- [x] R2 config validated
- [x] R3 all nodes reset and rebooted
- [x] R4 control plane initialized
- [x] R5 certificate SANs checked
- [x] R6 Calico installed with the pool 172.17.0.0/16, IPIP Always, node IPs 10.0.0.x
- [x] R7 workers joined, all Ready
- [x] R8 DNS and pods verified
- [x] R9 Windows kubectl works via `k8s-api`
- [x] R10a first etcd snapshot + PKI backup taken and verified
- [x] R10b backups copied to Windows (off the node)
- [ ] R10c scheduled backups (systemd timer) + restore drill
