# 02: Roadmap

Each phase ends with: runbook in `docs/phases/`, concept files for new objects, journal entry, and a **self-check**: Vishal explains each new object back and Claude grades it like an interviewer.

| Phase | Goal | Objects / skills | Done when |
|---|---|---|---|
| **0. Foundation & cluster audit** | Repo + docs scaffold; audit cluster (versions, Calico, containerd, allocatable RAM, taints); kubectl from Windows/VS Code; push to GitHub | Namespace, labels, annotations, kubeconfig, control-plane components | Baseline recorded in `phase-00-foundation.md`; `kubectl get nodes` works from Windows |
| **1. Requirements & architecture** | Answer the charter questionnaire; finalize architecture v1.0; write ADRs | Architecture thinking, sync vs async, trade-offs | Architecture doc marked v1.0 |
| **2. Build & containerize** | Write the 6 services (minimal code); multi-stage, non-root Dockerfiles; push to Docker Hub; GitHub Actions CI later | **container**, image layers, registry, tags vs digests, imagePullSecret | All 6 images on Docker Hub, each < 150 MB (Go < 20 MB) |
| **3. First deployment** | Pod by hand, then ReplicaSet, then Deployment; rolling update + rollback; ConfigMap/Secret; probes; requests/limits | **Pod, ReplicaSet, Deployment, ConfigMap, Secret, Probes**, QoS, init containers | Rolling update with zero failed requests; rollback demonstrated |
| **4. Service networking** | ClusterIP/NodePort/headless; CoreDNS; watch EndpointSlices change as pods come and go; internal-only discount-service | **Service, Endpoints, EndpointSlice**, DNS | order → discount → reply works by DNS name |
| **5. Storage & data tier** | **Prereq: add dedicated 100 GB NFS disk to cka-m (`/srv/nfs`)**; Static PV; NFS server + csi-driver-nfs; StorageClass; Postgres + Redis StatefulSets; RWX images PVC | **PV, PVC, StorageClass, StatefulSet, VolumeAttachment/CSIDriver** | Delete the Postgres pod and the data survives |
| **6. Batch workloads** | db-migrate Job; pg-backup, order-report, coupon-expiry CronJobs | **Job, CronJob** | Backup file appears on NFS on schedule; restore tested |
| **7. Exposure & TLS** | MetalLB; Traefik; Ingress, then Gateway + HTTPRoute; own CA with openssl, then cert-manager; hosts file; trust CA in Windows | **Ingress, IngressClass, Gateway, GatewayClass, HTTPRoute**, TLS Secret, CRDs | Browser shows 🔒 on `https://garamchai.test` |
| **8. Security** | ServiceAccount per service; RBAC (backup job, "intern" user via CSR); default-deny NetworkPolicies; securityContext; Pod Security Admission | **ServiceAccount, Role, ClusterRole, RoleBinding, ClusterRoleBinding, NetworkPolicy**, PSA, CSR | Test pod blocked from Postgres; frontend can't reach discount |
| **9. Scheduling** | Node labels; nodeSelector; affinity/anti-affinity; taint worker-2; topology spread; DaemonSet; PriorityClass | **nodeSelector, affinity, taints/tolerations, DaemonSet**, PriorityClass | Replicas spread across nodes; fluent-bit on every node |
| **10. Reliability & scale** | metrics-server; HPA on order-service; PDB; 50-user load test (k6); node drain; Quota/LimitRange | HPA, PDB, ResourceQuota, LimitRange | HPA scales under load; drain without downtime |
| **11. Operations & packaging** | Break/fix drills; backup/restore; Kustomize then Helm; CI with GitHub Actions | Troubleshooting, `kubectl debug`, Kustomize, Helm | Whole app deploys with one command |
| **12. Interview capstone** | Whiteboard the architecture; timed break & fix; question bank review | — | Every object in README is ✅ |

## Failure experiments planned (the best learning)
| Experiment | Phase | What you'll learn |
|---|---|---|
| Wrong image tag | 3 | ImagePullBackOff, `kubectl describe` events |
| Liveness probe that always fails | 3 | CrashLoopBackOff, restart backoff |
| Memory limit too low | 3 | OOMKilled, QoS classes |
| Kill discount-service during checkout | 4 | Graceful degradation, timeouts |
| Kill notification-service, place orders, bring it back | 4 | Async buffering, at-least-once processing |
| Delete Postgres pod | 5 | StatefulSet identity + PVC reattach |
| Delete a PVC with Retain vs Delete policy | 5 | Reclaim policies |
| Default-deny NetworkPolicy without a DNS allow rule | 8 | Why everything breaks (DNS on port 53) |
| Taint a node with pods already running (NoSchedule vs NoExecute) | 9 | Taint effects |
| Drain a node with PDB minAvailable=2 and 2 replicas | 10 | Why drain hangs |
