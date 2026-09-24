# GaramChai.com: Learning Kubernetes by Building a Real Project

**Team:** Vishal Bhilare (Intern DevOps Engineer) · Claude (Enterprise Solution Architect)
**Started:** 2026-09-23
**Goal:** Build GaramChai.com, a microservices chai-ordering app, from Dockerfile to production-style deployment on a homelab kubeadm cluster. By the end, be able to explain, write, debug and defend every Kubernetes object in an interview.

## Where to start
| File | What's in it |
|---|---|
| [docs/00-project-charter.md](docs/00-project-charter.md) | Why this project exists, roles, scope, honest constraints |
| [docs/01-architecture.md](docs/01-architecture.md) | The architecture: services, tiers, traffic, public vs private |
| [docs/02-roadmap.md](docs/02-roadmap.md) | Phase-by-phase plan |
| [docs/adr/](docs/adr/) | Architecture Decision Records (why we chose X over Y) |
| [docs/phases/](docs/phases/) | Step-by-step runbooks with real outputs |
| [concepts/](concepts/) | One deep-dive file per Kubernetes object |
| [concepts/00-cluster-networking.md](concepts/00-cluster-networking.md) | Our lab network explained, CoreDNS, production network design (interview-ready) |
| [concepts/00-how-a-cluster-comes-alive.md](concepts/00-how-a-cluster-comes-alive.md) | The cluster "boot process": pre-build checklist, kubeadm init/join step by step, default objects |
| [concepts/00-etcd-backup-restore.md](concepts/00-etcd-backup-restore.md) | etcd backup & restore in plain words: why, checklist, backup, restore, validate |
| [docs/guides/git-basics.md](docs/guides/git-basics.md) | The git commands we use, explained |
| [docs/study/](docs/study/README.md) | **Phase-wise study PDFs** with diagrams, quizzes and answers (start here to revise) |
| [docs/guides/high-availability-99.99.pdf](docs/guides/high-availability-99.99.pdf) | Study guide: 99.99% on AWS (SLA/SLO/SLI, error budget, MTTR, RPO/RTO, availability math, DR, cost). Source: `.html` next to it |
| [journal/](journal/) | Session-by-session log |
| [interview/question-bank.md](interview/question-bank.md) | Interview questions collected along the way |

## Phase progress
- [x] Phase 0: Foundation & cluster audit (done 2026-09-25)
- [ ] Phase 1: Requirements & architecture
- [ ] Phase 2: Build & containerize (Dockerfiles, Docker Hub)
- [ ] Phase 3: First deployment (Pod → ReplicaSet → Deployment, ConfigMap, Secret, Probes)
- [ ] Phase 4: Service networking (Service, Endpoints, EndpointSlice, DNS)
- [ ] Phase 5: Storage & data tier (PV, PVC, StorageClass, StatefulSet)
- [ ] Phase 6: Batch workloads (Job, CronJob)
- [ ] Phase 7: Exposure & TLS (MetalLB, Ingress, Gateway, HTTPRoute, cert-manager)
- [ ] Phase 8: Security (ServiceAccount, RBAC, NetworkPolicy, Pod Security)
- [ ] Phase 9: Scheduling (nodeSelector, affinity, taints, DaemonSet)
- [ ] Phase 10: Reliability & scale (HPA, PDB, Quota, load test)
- [ ] Phase 11: Operations & packaging (troubleshooting, Kustomize/Helm, CI)
- [ ] Phase 12: Interview capstone

## Kubernetes object coverage
Status legend: ⬜ not started · 🟨 learned (concept file written) · ✅ used hands-on in GaramChai + explained back

| Object | Phase | Status | Object | Phase | Status |
|---|---|---|---|---|---|
| Container | 2 | ⬜ | Ingress / IngressClass | 7 | ⬜ |
| Pod | 3 | ⬜ | Gateway / GatewayClass | 7 | ⬜ |
| Namespace | 0 | ⬜ | HTTPRoute | 7 | ⬜ |
| Labels & Annotations | 0 | ⬜ | ServiceAccount | 8 | ⬜ |
| ConfigMap | 3 | ⬜ | Role / RoleBinding | 8 | ⬜ |
| Secret | 3 | ⬜ | ClusterRole / ClusterRoleBinding | 8 | ⬜ |
| ReplicaSet | 3 | ⬜ | NetworkPolicy | 8 | ⬜ |
| Deployment | 3 | ⬜ | Pod Security Admission / securityContext | 8 | ⬜ |
| Probes (liveness/readiness/startup) | 3 | ⬜ | nodeSelector | 9 | ⬜ |
| Requests/Limits & QoS | 3 | ⬜ | Affinity / Anti-affinity | 9 | ⬜ |
| Service (all types) | 4 | ⬜ | Taints & Tolerations | 9 | ⬜ |
| Endpoints | 4 | ⬜ | topologySpreadConstraints | 9 | ⬜ |
| EndpointSlice | 4 | ⬜ | DaemonSet | 9 | ⬜ |
| PersistentVolume | 5 | ⬜ | PriorityClass | 9 | ⬜ |
| PersistentVolumeClaim | 5 | ⬜ | HorizontalPodAutoscaler | 10 | ⬜ |
| StorageClass | 5 | ⬜ | PodDisruptionBudget | 10 | ⬜ |
| VolumeAttachment / CSIDriver | 5 | ⬜ | ResourceQuota / LimitRange | 10 | ⬜ |
| StatefulSet | 5 | ⬜ | CRDs (cert-manager) | 7 | ⬜ |
| Job | 6 | ⬜ | CertificateSigningRequest | 8 | ⬜ |
| CronJob | 6 | ⬜ | Kustomize / Helm | 11 | ⬜ |
