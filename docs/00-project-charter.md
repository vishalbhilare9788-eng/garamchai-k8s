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
- Payment gateway, real SMS/email (customers pay at the counter on pickup)
- Delivery and delivery tracking (pickup only for now)
- Item substitution negotiation ("we don't have X, would you like Y?")
- Service mesh, GitOps (Argo CD), full Prometheus/Grafana (RAM limits; stretch goals only)
- Multi-cluster / cloud

## 5. Constraints
| Constraint | Impact |
|---|---|
| Nodes have 2 vCPU / 4 GB RAM (~3.58 GiB allocatable) | Still no JVM or service mesh; strict requests/limits on every pod |
| Root disks were 10–12 GB (cka-w2 under DiskPressure at the audit); grown to 58–67 GB in Phase 0 | Still keep images small (multi-stage, alpine/distroless): pulls go over the NAT link and images live on an HDD |
| kubeadm cluster (no cloud) | No built-in LoadBalancer or dynamic storage: we add MetalLB + NFS CSI |
| No registered DNS | `garamchai.test` via Windows hosts file; our own CA for TLS |
| Single-person team, learning pace | Small steps, everything documented |

## 6. Requirements questionnaire (what an architect asks BEFORE building)
To be completed together in **Phase 1**. An architect never starts with YAML. They start with questions. Answers will be recorded here.

**Functional** ✅ decided 2026-09-25

Roles:
| Role | Who | Can do |
|---|---|---|
| Customer | Anyone who signs up | Browse, order, cancel, see own orders |
| Staff | Counter staff | Accept/reject orders, move them through the lifecycle |
| Admin | Shop owner | Everything staff can do, plus menu, availability, coupons, reports |

Features:
| # | Feature | Who | Leads to (K8s / architecture) |
|---|---|---|---|
| F1 | Browse the menu **without logging in** | Customer | menu-service, public; Redis cache in front of Postgres |
| F2 | Sign up / log in, with an **opt-in checkbox for offers** (off by default) | Customer | auth-service, JWT, **Secret** for the signing key |
| F3 | Place an order (**login required**, **pickup at the shop only**) | Customer | order-service → discount-service (sync) |
| F4 | Apply a coupon code at checkout | Customer | discount-service, **internal only** (**NetworkPolicy**) |
| F5 | See own order history and live status | Customer | order-service + Postgres (**StatefulSet**, **PVC**) |
| F6 | "Order accepted / rejected / ready for pickup" message (fake SMS, printed to logs) | Customer | notification worker via Redis Streams (no Service) |
| F7 | Add/edit menu items and **upload photos** | Admin | shared image storage (**PV/PVC RWX** on NFS) |
| F8 | Create coupons | Admin | discount-service |
| F9 | Daily sales report, overnight | Admin | **CronJob** |
| F10 | Expire old coupons every night | System | **CronJob** |
| F11 | Mark the shop **open/closed** and items **available/out of stock**; unavailable items can't be ordered | Admin | menu-service; order-service validates before accepting |
| F12 | Accept or reject orders (reason `CLOSED` / `OUT_OF_STOCK` / `OTHER` + a suggestion text) | Staff | order-service |
| F13 | Orders nobody responds to within 10 min become `EXPIRED` | System | periodic job (**CronJob**) |

Order lifecycle:
```
PLACED ──(staff accepts)──► PREPARING ──► READY ──(customer collects)──► COMPLETED
  │
  ├──(staff rejects: CLOSED / OUT_OF_STOCK / OTHER + suggestion)──► REJECTED
  ├──(customer cancels, only while PLACED)────────────────────────► CANCELLED
  └──(no staff response within 10 min)────────────────────────────► EXPIRED
```

Decisions and why:
- **Login required, no guest checkout:** the account gives email + phone for order updates and (with consent) offers; one ordering path; order history works. Consent is required by law (India DPDP Act 2023 / GDPR), hence the opt-in checkbox.
- **Prevent rather than reject (F11):** a closed shop or an out-of-stock item is blocked on the menu, so customers don't place orders that get rejected. REJECTED remains for surprises (the last milk ran out).
- **No substitution negotiation:** a two-way "would you like Y instead?" flow needs a waiting state, notifications and timeouts, and teaches no new Kubernetes object. Staff put a suggestion in the rejection message instead.
- **Pickup only:** no delivery staff yet; delivery would add addresses (more personal data), a delivery step and tracking. Later phase.

**Non-functional** ✅ decided 2026-09-25
| # | Requirement | Target | Leads to |
|---|---|---|---|
| N1 | Load | 50 concurrent users; ~5 req/s average, **~20 req/s at peak** (8–10 am, 5–7 pm) | k6 load test + **HPA** (Phase 10) |
| N2 | Availability | **99.5 %** (≈ 3.6 h down per month); **zero downtime during deploys** | Rolling updates, readiness probes, **PDB**, ≥ 2 replicas of stateless services |
| N3 | Speed | p95 < 300 ms for menu and order APIs | requests/limits, Redis cache for the menu |
| N4 | Orders data | **RPO 4 h**, RTO 1 h; backups kept 7 days | Postgres backup **CronJob every 4 h** to NFS + a restore drill |
| N5 | Retention | Order history kept 1 year, then deleted | Storage limitation (DPDP/GDPR); a cleanup job |

Payment: customers pay at the counter on pickup (no payment data in the system).

Honest risks to N2 (single points of failure in this lab): 1 Postgres instance, 1 control plane, and the NFS server on cka-m. If cka-m is down, the running pods keep working, but nothing can be changed, and anything that reads or writes NFS stops. 99.5 % is realistic only because failures here are rare and short. We'll measure it, not assume it.

**Security, part 1: protecting data** ✅ decided 2026-09-25
| Data | Sensitivity |
|---|---|
| Menu, prices | public |
| Orders | low |
| Email, phone | **personal data** (DPDP/GDPR) |
| Passwords | **high** (people reuse them) |
| Keys, DB passwords | **critical** (whoever has them becomes the app) |

| # | Rule | Leads to |
|---|---|---|
| S1 | Passwords stored only as **bcrypt** hashes (slow + salted, so stolen hashes are hard to brute-force) | auth-service code |
| S2 | Keys and DB passwords only in **Secrets**; only `*.example.yaml` in Git | **Secret**, `.gitignore` |
| S3 | **Encryption at rest** for Secrets in etcd | `EncryptionConfiguration` on the API server (Phase 8) |
| S4 | **One DB user per service**; only auth-service can read personal data | Postgres roles/grants (Phase 5) |
| S5 | **TLS at the edge** (browser → Traefik); inside the cluster, default-deny **NetworkPolicy** | Ingress/Gateway + cert-manager (Phase 7), NetworkPolicy (Phase 8) |

Not chosen: mTLS between services (needs a service mesh, too heavy for our RAM).

**Security, part 2: access** ✅ decided 2026-09-25 (least privilege everywhere)
| # | Who | Gets | Leads to |
|---|---|---|---|
| A1 | Vishal (admin) | Full admin via `admin.conf`; never shared, never committed | client certificate, group `kubeadm:cluster-admins` |
| A2 | "intern" user | **Read-only in `garamchai` only** | **CSR**, Role/RoleBinding (Phase 8) |
| A3 | Each service | Own **ServiceAccount**, no API permissions, `automountServiceAccountToken: false` | ServiceAccount (Phase 8) |
| A4 | Backup Job | Small Role in `garamchai-data` only | Role/RoleBinding (Phase 6/8) |
| A5 | SSH to nodes | Vishal only, key-based | node hardening |

Deployments: **CI builds and pushes images only; deploys are run from the laptop** (`kubectl apply`). The cluster sits behind VMware NAT, so GitHub can't reach it, and exposing it would put cluster credentials on a third-party server. (Real-world alternative: GitOps, where an in-cluster agent pulls from Git; out of scope for RAM.)

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
