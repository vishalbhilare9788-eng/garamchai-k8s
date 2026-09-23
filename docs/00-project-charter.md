# 00: Project Charter: GaramChai.com

## 1. Background
GaramChai.com is a (fictional) client that wants an online platform for ordering chai and snacks. They asked for a **microservices** application on **Kubernetes** that serves **50 concurrent users**.

Our team:
| Person | Role | Responsibility |
|---|---|---|
| Vishal Bhilare | Intern DevOps Engineer | Runs every command, builds images, writes manifests, keeps notes |
| Claude | Enterprise Solution Architect | Designs the system, explains every concept, reviews output, challenges wrong assumptions |

## 2. The real goal (internal)
The client project is the vehicle. The actual outcome is that **Vishal can explain, write, debug and defend every major Kubernetes object in an interview**, because they built and broke each one themselves.

## 3. Architect's honest assessment of the client's request
> An architect's job is not to say yes. It is to say what is true.

1. **50 concurrent users does not need microservices.** A single well-written monolith on one small VM with one Postgres would serve this load easily. Microservices add network hops, distributed failures, more deployments, more monitoring and more cost.
   *In a real engagement I would recommend a modular monolith first and split later when team size or scaling needs justify it.* We are building microservices because **learning is the requirement**. In an interview, being able to say this is a strong signal.
2. **Kubernetes is also overkill for 50 users.** Same reasoning. For learning, it's exactly right.
3. **Homelab constraints are real constraints.** 4 GB nodes with small 10–12 GB disks force us to size every pod and image carefully, which is actually good practice. Most beginners never set resource limits and then can't explain OOMKilled or Pending pods.

## 4. Scope
**In scope**
- 6 microservices (frontend, auth, menu, order, discount, notification) + PostgreSQL + Redis (cache + event stream)
- Dockerfiles, images on Docker Hub, source on GitHub
- Full Kubernetes deployment: workloads, networking, storage, TLS, security, scheduling, scaling
- Our own Certificate Authority and HTTPS on `https://garamchai.test`
- Documentation of every step and every concept

**Out of scope (for now)**
- Public domain / public internet exposure
- Payment gateway, real SMS/email
- Service mesh, GitOps (Argo CD), full Prometheus/Grafana (RAM limits; stretch goals only)
- Multi-cluster / cloud

## 5. Constraints
| Constraint | Impact |
|---|---|
| Nodes have 2 vCPU / 4 GB RAM (~3.58 GiB allocatable) | Still no JVM or service mesh; strict requests/limits on every pod |
| Small root disks (10–12 GB), cka-w2 under DiskPressure at audit | Grow disks in Phase 0; keep images small (multi-stage, alpine/distroless) |
| kubeadm cluster (no cloud) | No built-in LoadBalancer or dynamic storage: we add MetalLB + NFS CSI |
| No registered DNS | `garamchai.test` via Windows hosts file; our own CA for TLS |
| Single-person team, learning pace | Small steps, everything documented |

## 6. Requirements questionnaire (what an architect asks BEFORE building)
To be completed together in **Phase 1**. An architect never starts with YAML. They start with questions. Answers will be recorded here.

**Functional**
- What can a customer do? (browse menu, sign up/login, place order, view order history?)
- What can an admin do? (add menu items, upload images, see daily sales?)
- Are there reports? How often?

**Non-functional**
- Load: 50 concurrent users. What's the peak? Requests per second per user?
- Availability target (99%? 99.9%?) and acceptable downtime for deploys?
- Response time target (e.g. p95 < 300 ms)?
- Data retention and backups: how often, how long kept, what's the restore time target (RTO/RPO)?

**Security**
- What data is sensitive? (passwords, phone numbers, addresses)
- Who may access the cluster, and with what permissions?
- TLS everywhere or only at the edge?

**Operations**
- How are releases done? Rollback expectations?
- Logging and monitoring expectations?
- Budget / infrastructure limits?

## 7. Success criteria
- `https://garamchai.test` works from the Windows browser with a trusted certificate
- A pod, node or DB pod failure causes no data loss and minimal downtime
- NetworkPolicies prove the DB is unreachable from anything except the APIs
- The app handles a 50-user load test with autoscaling
- Every object in the README coverage table is ✅
