# etcd Backup & Restore, in Plain Words

> **One-line definition:** etcd is the cluster's memory. A backup is a photocopy of that memory. A restore is replacing the memory with the photocopy.
> **Where it runs in our lab:** static pod `etcd-cka-m` on cka-m, data in `/var/lib/etcd`, one single copy (no HA).
> **Hands-on:** [phase-00-rebuild.md, Step R10](../docs/phases/phase-00-rebuild.md) · [journal 2026-09-23](../journal/2026-09-23.md) (the incident) · [journal 2026-09-24](../journal/2026-09-24.md) (the drill)

---

## 1. Why back up at all? (the story)

### The analogy: the office register
Imagine a restaurant. The **register book** at the counter lists every order, every table, every staff member and every key to every room. The cooks, the waiters and the manager don't remember anything themselves. They all **look it up in the register**.

- **etcd** = the register book.
- **API server** = the only person allowed to write in it or read from it.
- **Controllers, scheduler, kubelets** = staff who keep asking "what does the register say?" and then make reality match it.

If the register burns, the kitchen still has pots and pans (the containers may keep running for a while), but **nobody knows what should exist anymore**. No Deployments, no Services, no Secrets, no RBAC. That's a dead cluster.

### What actually happened to us (2026-09-23)
1. The laptop hung, and the VMs were switched off hard, like pulling the plug.
2. etcd had been told "your write is saved", but the data was still in a cache and never reached the disk.
3. After the reboot, etcd's database was inconsistent. Almost everything was gone. `kubectl` gave **403**, because even the admin's RoleBinding had disappeared.
4. There was **one** etcd and **zero** backups, so there was nothing to go back to. We rebuilt the cluster from scratch.

**The lesson:** etcd is the only place where the cluster's state lives. No backup means no recovery.

### What is in etcd, and what is NOT
| In etcd (a restore brings it back) | NOT in etcd (a restore does NOT bring it back) |
|---|---|
| Every object: Namespaces, Deployments, Pods, Services, ConfigMaps, **Secrets**, RBAC, CRDs, Nodes, Leases | Files inside **PersistentVolumes** (database rows, uploads): back those up separately (Phase 5) |
| The desired state ("3 replicas of X") | Container images (they're in Docker Hub) |
| | The **certificates and keys** in `/etc/kubernetes/pki` (see §2) |

> Because etcd holds every **Secret** (only base64 encoded, not encrypted, unless you turn on encryption at rest), **a snapshot file is as sensitive as all your passwords together.** Treat it that way.

---

## 2. Think before you back up (the checklist)

| # | Question | Our answer | Why it matters |
|---|---|---|---|
| 1 | **Which tool?** | `etcdctl`/`etcdutl` **3.6.6**, the same version as the etcd server | Different versions can fail or behave differently. In 3.6, `snapshot status/restore` moved from `etcdctl` to `etcdutl` |
| 2 | **How do I connect?** | Endpoint + 3 TLS files, read from `/etc/kubernetes/manifests/etcd.yaml` | etcd only talks to clients presenting a certificate signed by its CA. Never guess the flags; read them |
| 3 | **What else must I save?** | `/etc/kubernetes/pki` (the CA + keys) | The snapshot is the cluster's **data**; the PKI is its **identity**. See §2.1 |
| 4 | **Who can read the backup?** | root only: `umask 077`, folder mode `700` | The snapshot contains every Secret; the PKI contains the CA's private key |
| 5 | **Where is it stored?** | `/var/backups/etcd` on cka-m **plus** a copy on Windows | A backup on the same machine dies with the machine. Rule **3-2-1**: 3 copies, 2 media, 1 off-site |
| 6 | **How often, how long?** | Every 6 h, keep 7 days (28 snapshots) | How much data can you afford to lose (RPO)? We accept up to 6 h |
| 7 | **Who remembers to do it?** | Nobody: a **systemd timer** does it | Manual backups get forgotten. A CronJob inside the cluster would die with the cluster |
| 8 | **Is the file actually good?** | Verified with `etcdutl snapshot status` *before* it gets its final name | A corrupt backup found on restore day is worse than none, because you trusted it |
| 9 | **Did I ever restore it?** | Yes, drill on 2026-09-24 | **A backup you've never restored is a hope, not a backup** |

### 2.1 Why the PKI matters (the ID-card analogy)
Every component carries an **ID card** (a certificate), stamped by the cluster's **CA** (Certificate Authority). Everyone checks the stamp before they talk to each other.

If cka-m dies and you run `kubeadm init` on a new VM, kubeadm creates a **new CA**, which is a new stamp. The workers and your Windows kubeconfig still carry cards with the **old** stamp. Nobody trusts anybody: the nodes go `NotReady`, `kubectl` from Windows fails, and ServiceAccount tokens stop validating.

**Fix:** put the backed-up `/etc/kubernetes/pki` back on the new node **before** `kubeadm init`. kubeadm reuses the certificates it finds, so the cluster keeps its identity.

---

## 3. How to back up

### 3.1 Find the connection details (never guess)
```bash
sudo grep -E -- '--(listen-client-urls|trusted-ca-file|cert-file|key-file)=' /etc/kubernetes/manifests/etcd.yaml
```
This gives us the 4 values we pass to every `etcdctl` command:
| Flag | Our value | Plain meaning |
|---|---|---|
| `--endpoints` | `https://127.0.0.1:2379` | "Where is etcd listening?" |
| `--cacert` | `/etc/kubernetes/pki/etcd/ca.crt` | "Which stamp do I trust?" (to check etcd's ID card) |
| `--cert` | `/etc/kubernetes/pki/etcd/server.crt` | "My ID card" |
| `--key` | `/etc/kubernetes/pki/etcd/server.key` | "The private key that proves the card is mine" |

### 3.2 Take the snapshot (the photocopy)
```bash
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd/etcd-$(date +%F-%H%M).db
```
- `snapshot save` asks the **running** etcd for a consistent copy of its whole database. No downtime is needed.
- Internally, etcdctl first writes `<name>.part` and renames it when the download is complete.

### 3.3 Check the snapshot (is the photocopy readable?)
```bash
sudo etcdutl snapshot status /var/backups/etcd/etcd-2026-09-24-1630.db -w table
```
```
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | VERSION |
| 62bd7044 |    10111 |        532 |     4.4 MB |   3.6.0 |
```
| Column | Plain meaning |
|---|---|
| HASH | A fingerprint of the content. etcdutl checks it, so a damaged file makes this command **fail** |
| REVISION | etcd's change counter: every write in the cluster adds 1. Ours grew by ~2,600 in 28 min with nothing deployed (node heartbeats, status updates, events) |
| TOTAL KEYS | Number of stored objects |
| VERSION | Storage format version (always `x.y.0`, even though the binary is 3.6.6) |

### 3.4 Save the PKI (the ID cards and the stamp)
```bash
(umask 077; sudo tar czf /var/backups/etcd/pki-$(date +%F).tgz -C /etc/kubernetes pki)
```

### 3.5 Automate it (what we run now)
Three files in [infra/etcd-backup/](../infra/etcd-backup/):
| File | Role | Analogy |
|---|---|---|
| `etcd-backup.sh` | **What** to do: wait for etcd → snapshot to `.tmp` → verify → rename to `.db` → save PKI → delete old ones | The recipe |
| `etcd-backup.service` | **How** to run it: as root, once, at low priority | The cook |
| `etcd-backup.timer` | **When**: every 6 h; `Persistent=true` catches up after the VM was off | The alarm clock |

**Why verify before renaming?** The cleanup keeps "the newest 28 `.db` files". If damaged snapshots were also called `.db`, a week of silent failures would push every good snapshot out, and you'd only find out on restore day. So: only a verified file gets the `.db` name.

```bash
sudo systemctl start etcd-backup.service            # run once by hand
sudo journalctl -u etcd-backup -n 30 --no-pager     # see the status table + "OK: ..."
systemctl list-timers etcd-backup.timer --no-pager  # when does it run next?
```

---

## 4. How to restore

### The idea in one picture
```
 snapshot file ──(etcdutl restore)──► NEW folder /var/lib/etcd-restore     (live cluster untouched)
                                              │
 stop control plane ── swap folders ──────────┘  /var/lib/etcd  ◄── restored data
                                                 /var/lib/etcd.before-drill  ◄── old data (way back)
 start control plane ──► etcd reads the restored data ──► API server, controllers reload from it
```

### Step 0: read the member's identity (never guess)
```bash
sudo grep -E -- '--(name|data-dir|initial-cluster|initial-advertise-peer-urls)=' /etc/kubernetes/manifests/etcd.yaml
sudo grep -B1 -A2 'path: /var/lib/etcd' /etc/kubernetes/manifests/etcd.yaml
```
A restore creates a **brand-new database** that records who its member is. That identity must match what the etcd pod says about itself:
| Flag | Plain meaning | Ours |
|---|---|---|
| `--name` | "My name is…" | `cka-m` |
| `--initial-advertise-peer-urls` | "Other members reach me at…" | `https://10.0.0.100:2380` |
| `--initial-cluster` | "The cluster consists of…" | `cka-m=https://10.0.0.100:2380` |
| `--data-dir` | The folder **inside the container** | `/var/lib/etcd` |
| `hostPath.path` | The folder **on the node's disk** mounted there, which is what we swap | `/var/lib/etcd` |

Without these flags, etcdutl uses its defaults (`default` at `http://localhost:2380`). The pod would then say "I'm cka-m" while its data says "the member is `default`", and it breaks.

### Step A: restore into a new folder (safe)
```bash
sudo etcdutl snapshot restore /var/backups/etcd/etcd-2026-09-24-1658.db \
  --data-dir=/var/lib/etcd-restore \
  --name=cka-m \
  --initial-cluster=cka-m=https://10.0.0.100:2380 \
  --initial-advertise-peer-urls=https://10.0.0.100:2380 \
  --bump-revision=1000000000 --mark-compacted
```
**`--bump-revision` and `--mark-compacted` in plain words:** every controller remembers "the last change number I saw". The live cluster was already past the snapshot's number, because it kept running after 16:58. If the restored etcd started at a *lower* number, the controllers would think "nothing new happened" and keep old data in their memory. So we jump the counter far ahead (12718 → 1000012718) and mark the old history as gone. That forces every controller to reload everything fresh.

### Step B: stop the control plane
```bash
sudo mkdir /etc/kubernetes/manifests-stopped
sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests-stopped/
sudo crictl ps --name '^(etcd|kube-apiserver|kube-controller-manager|kube-scheduler)$'   # repeat until empty
```
kubelet runs whatever YAML is in `/etc/kubernetes/manifests`. Take the files away and it stops those pods. We stop **all four**, because the API server, controller-manager and scheduler keep cluster state in memory and must reload it after the swap.

### Step C: swap the folders
```bash
sudo mv /var/lib/etcd /var/lib/etcd.before-drill     # keep the old data: your way back
sudo mv /var/lib/etcd-restore /var/lib/etcd
```

### Step D: start again
```bash
sudo mv /etc/kubernetes/manifests-stopped/*.yaml /etc/kubernetes/manifests/
sudo rmdir /etc/kubernetes/manifests-stopped
sudo systemctl restart kubelet
```

**Why swap folders instead of editing etcd.yaml?** The exam shortcut is to change `hostPath` to `/var/lib/etcd-restore`. That works today, but a later `kubeadm upgrade` rewrites etcd.yaml back to `/var/lib/etcd`, which would silently switch you back to the **old** data. Swapping keeps the manifest exactly as kubeadm made it.

**If it doesn't come back within 5 min:** repeat B, move the restored folder aside, move `etcd.before-drill` back to `/var/lib/etcd`, repeat D. Don't try random fixes on a cluster that's down.

---

## 5. How to validate (prove it, don't assume it)

| # | Check | Command | What we saw |
|---|---|---|---|
| 1 | Control plane back, no crash loops | `sudo crictl ps --name '^(etcd\|kube-apiserver\|kube-controller-manager\|kube-scheduler)$'` | All 4 Running, attempt 0 |
| 2 | **The proof:** the change made after the snapshot is gone | `kubectl get ns` | `drill` missing ✅ |
| 3 | Nodes and system pods healthy | `kubectl get nodes`, `kubectl get pods -A` | 3 Ready, all Running |
| 4 | etcd healthy with the right identity | `etcdctl ... endpoint status -w table` | Member ID `99c2fd4fe11e28d9` = the ID the restore wrote |
| 5 | Writes work, not just reads | `kubectl create ns write-test && kubectl delete ns write-test` | Created and deleted |
| 6 | Backups work on the restored etcd | `sudo systemctl start etcd-backup.service` + journal | Revision 1000013198: the bump is live |
| 7 | Remote clients still trusted (PKI unchanged) | Windows: `kubectl get nodes` | 3 Ready |
| 8 | **Only then** clean up | `sudo rm -rf /var/lib/etcd.before-drill` | It holds every Secret, so don't leave it lying around |

**Why a drill?** We created the namespace `drill` *after* the snapshot. If it disappears after the restore, we have proof that the cluster really runs on the snapshot's data, not on the old folder by accident.

**Real-world caution:** a restore rolls back **everything** after the snapshot, not only your mistake. Pods created after the snapshot become unknown to Kubernetes, and IP allocations can clash. In production you restore only for disasters, and you pick the newest good snapshot.

---

## 6. Common mistakes & gotchas
| Mistake | What happens |
|---|---|
| Backup stored only on the control-plane node | Dies with the node: no backup at all |
| Snapshot saved without the PKI | A rebuilt node gets a new CA and nothing trusts anything |
| Restore without `--name` / `--initial-cluster` / peer URL | Member identity mismatch; etcd fails or records a wrong member |
| Restoring on top of the existing `/var/lib/etcd` | etcdutl refuses (data dir exists), or you destroy your only way back |
| Leaving the API server running during the swap | It serves stale cached data, or writes into the wrong database |
| Backup files readable by everyone | Anyone on the node can read every Secret and the CA key |
| Never testing a restore | You find out on the worst day that the backup doesn't work |
| `etcdctl snapshot restore` on 3.6 | Removed: use `etcdutl` |
| Forgetting `sudo` / wrong cert paths | `context deadline exceeded` or `certificate signed by unknown authority` |

## 7. Interview questions
| Question | Short answer |
|---|---|
| What's in etcd, and what isn't? | All API objects incl. Secrets. Not PV data, not images, not the PKI files |
| How do you back up etcd in a kubeadm cluster? | `etcdctl snapshot save` with the endpoint + CA/cert/key from etcd.yaml; verify with `etcdutl snapshot status`; also save `/etc/kubernetes/pki`; automate it; copy it off the node |
| How do you restore? | `etcdutl snapshot restore` into a new data dir with the member's name/cluster/peer URL, stop the static pods, swap the data dir, start them, verify |
| Why `--bump-revision --mark-compacted`? | So controllers' remembered revisions are lower than the restored one: they re-list instead of trusting stale caches |
| Why is a snapshot sensitive? | It contains every Secret in plain base64 |
| Where should backups live? | Off the node, ideally 3-2-1 |
| systemd timer vs CronJob for this? | A backup of the cluster must not depend on the cluster being healthy |
| How do you know your backup works? | You restore it in a drill and prove a known change was rolled back |

## 8. Related
[00-how-a-cluster-comes-alive.md](00-how-a-cluster-comes-alive.md) (static pods, PKI, etcd's role at boot) · [interview/question-bank.md](../interview/question-bank.md) Q7–10
