# 01: Architecture: GaramChai.com

> Status: **Draft v0.2** (2026-09-23). Added discount-service and notification-service. Will be finalized after the Phase 1 requirements session.

## 1. The big picture

```
 Windows browser ──https://garamchai.test──► MetalLB IP (Service type LoadBalancer)
                                              │
                                     Traefik (Ingress + Gateway API)          [ns: traefik]
                                     TLS terminated here (cert-manager, our own CA)
          ┌──────────────────┬────────────────┴──┬───────────────────────┐
     "/"  ▼      "/api/auth" ▼       "/api/menu" ▼        "/api/orders"  ▼
   frontend               auth-service         menu-service            order-service ───────► discount-service
   React + nginx          Node.js              Python FastAPI          Go          (HTTP)     Node.js
   PUBLIC                 PRIVATE              PRIVATE                 PRIVATE                INTERNAL-ONLY
                              │                    │   │                  │   │                 │
                              │                    │   └──► redis ◄───────┘   │  publish        │
                              │                    │        (cache +          │  "order.placed" │
                              │                    │         stream)  ────────┼──► notification-service
                              │                    │                          │    Python worker (no Service)
                              └────────────────────┴──► postgres ◄────────────┴─────────────────┘
                                                     (StatefulSet)     [ns: garamchai-data]
                         menu images ──► NFS ReadWriteMany PVC (StorageClass: nfs-csi)

 Batch:      db-migrate Job · order-report CronJob · coupon-expiry CronJob · pg-backup CronJob (dump → NFS)
 Node-level: fluent-bit DaemonSet (logs) · calico-node · kube-proxy
```

## 2. Services: three tiers + storage

| Tier | Component | Tech | K8s objects | Exposure | Responsibility |
|---|---|---|---|---|---|
| **Web** | frontend | React (static build) on `nginx-unprivileged` | Deployment, Service (ClusterIP) | **Public** (via Traefik `/`) | UI. Static files, stateless |
| **App** | auth-service | Node.js (Express) | Deployment, Service, Secret (JWT key) | Private, routed at `/api/auth/*` | Signup/login, issues JWT tokens |
| **App** | menu-service | Python (FastAPI) | Deployment, Service, ConfigMap, PVC (images) | Private, routed at `/api/menu/*` | Menu catalog, Redis cache, item images on shared storage |
| **App** | order-service | Go | Deployment, Service, HPA | Private, routed at `/api/orders/*` | Cart and checkout, calculates the total, publishes `order.placed` event. Busiest path, so this one autoscales |
| **App** | **discount-service** | Node.js | Deployment, Service (ClusterIP) | **Internal-only**: *no* route in Traefik | Validates coupon codes (`CHAI10`, first-order offer), returns the discount amount. Only order-service calls it |
| **App** | **notification-service** | Python worker | Deployment, **no Service** | **None**: it receives no traffic at all | Reads `order.placed` events from a Redis Stream and "sends" SMS/email (simulated: writes to logs and a `notifications` table) |
| **Data** | PostgreSQL | `postgres:16-alpine` | StatefulSet, headless Service, PVC | **Never exposed** | One instance, one database per service: `auth_db`, `menu_db`, `order_db`, `discount_db`, `notification_db` |
| **Data** | Redis | `redis:7-alpine` | StatefulSet, Service, PVC | Never exposed | Menu cache **and** event stream (Redis Streams) |
| **Storage** | NFS server on master VM | csi-driver-nfs | StorageClass, PV, PVC | n/a | Dynamic provisioning + ReadWriteMany for images and backups |

### Why the two new services are designed this way
**discount-service: internal-only, synchronous (HTTP).**
Checkout *needs* the discount before it can show the final price, so order-service calls it directly and waits for the answer. The browser never calls it: if it could, a user could probe or brute-force coupon codes. Coupons are applied through `POST /api/orders/quote`, and order-service calls `http://discount-service/validate` internally.
*K8s lessons:* a ClusterIP Service with **no** Ingress/HTTPRoute (private by design); service-to-service DNS; NetworkPolicy allowing **only** order-service in; a **CronJob** that expires old coupons.
*Failure design:* if discount-service is down, order-service uses a short timeout and continues **without** the discount instead of failing the order. We will test this.

**notification-service: asynchronous (event-driven), no Service.**
Sending an SMS must **not** slow down or break checkout. If notification were a synchronous HTTP call and it crashed, customers could not place orders. So order-service writes an event to a **Redis Stream** and returns immediately. notification-service consumes the stream at its own pace. If it's down, events wait in the stream and get processed when it recovers.
*K8s lessons:* a Deployment **without a Service** (nothing calls it, it pulls work); an **exec-based liveness probe** (there's no HTTP port to check); egress-only NetworkPolicy; scaling a worker by queue depth (discussion).

> **Correction to v0.1:** I earlier wrote "no message queue needed". With a notification service, that no longer holds, because a synchronous call would couple checkout to SMS delivery. Instead of adding RabbitMQ/Kafka (300 MB+ RAM), we reuse **Redis Streams** from the Redis we already run. It costs no extra RAM. In a bigger system you would use a dedicated broker, and you should be able to say why in an interview.

### Why "one Postgres instance, one DB per service"?
The microservices rule is **"each service owns its data; no service reads another's tables."** In production each service might get its own DB server. On our small workers we keep **one server with separate databases and separate DB users**. Each user only has rights on its own DB, so ownership is still enforced, at a fraction of the RAM. This is a conscious, documented trade-off.

## 3. Public vs private: who can talk to whom

| From → To | Allowed? | Why |
|---|---|---|
| Browser → Traefik (443) | ✅ | Single entry point |
| Traefik → frontend, auth, menu, order | ✅ | Path-based routing |
| Traefik → discount-service / notification-service | ❌ | Not public |
| Browser → any service directly | ❌ | All Services are ClusterIP |
| order-service → menu-service | ✅ | Current prices |
| order-service → discount-service | ✅ | Coupon validation (**only** caller) |
| order-service → Redis (stream write) | ✅ | Publish `order.placed` |
| notification-service → Redis (stream read) | ✅ | Consume events |
| menu-service → Redis | ✅ | Cache |
| auth/menu/order/discount/notification → Postgres :5432 | ✅ | Each to its own DB only |
| frontend → Postgres / Redis | ❌ | Frontend never touches data |
| Anything else | ❌ | **Default deny** (NetworkPolicy, Phase 8, works because we run Calico) |

The frontend calls APIs **from the browser** through Traefik (same domain, `/api/...` paths), not pod-to-pod. That avoids CORS and keeps one TLS certificate.

## 4. Namespaces

| Namespace | Contents | Why separate |
|---|---|---|
| `garamchai` | frontend, auth, menu, order, discount, notification, app Jobs/CronJobs | App tier |
| `garamchai-data` | Postgres, Redis, backup CronJob | Different lifecycle and security. Practises cross-namespace DNS (`postgres.garamchai-data.svc.cluster.local`) and namespace-level NetworkPolicy/RBAC |
| `traefik` | Traefik controller | Platform |
| `metallb-system` | MetalLB | Platform |
| `cert-manager` | cert-manager | Platform |
| `logging` | fluent-bit DaemonSet | Platform |

## 5. Scheduling plan (Phase 9)
- `worker-1`: labelled `tier=app`.
- `worker-2`: labelled `tier=data`, tainted `dedicated=data:NoSchedule`. Only Postgres/Redis tolerate it. *With only 2 workers this forces all app pods onto one node and kills HA. We'll do it, observe the problem, then fix it. That tension is the lesson.*
- API replicas use **pod anti-affinity / topologySpreadConstraints** so both replicas don't sit on one node.
- master keeps its `node-role.kubernetes.io/control-plane:NoSchedule` taint. DaemonSets that must run there tolerate it.

## 6. RAM budget: honest numbers
Kubernetes schedules by **requests** (guaranteed minimum). **Limits** are the ceiling before OOMKill. Requests must fit on the nodes; limits may add up to more (overcommit).

| Component | Replicas | Request / Limit each | Total request | Total limit |
|---|---|---|---|---|
| frontend | 2 | 32 / 64 Mi | 64 Mi | 128 Mi |
| auth-service (Node) | 2 | 64 / 128 Mi | 128 Mi | 256 Mi |
| menu-service (Python) | 2 | 64 / 128 Mi | 128 Mi | 256 Mi |
| order-service (Go) | 2 (HPA → 4) | 32 / 64 Mi | 64 Mi | 128 Mi |
| discount-service (Node) | 2 | 48 / 96 Mi | 96 Mi | 192 Mi |
| notification-service (Python) | 1 | 48 / 96 Mi | 48 Mi | 96 Mi |
| PostgreSQL | 1 | 256 / 384 Mi | 256 Mi | 384 Mi |
| Redis | 1 | 48 / 96 Mi | 48 Mi | 96 Mi |
| Traefik | 1 | 64 / 128 Mi | 64 Mi | 128 Mi |
| cert-manager (3 pods) | 3 | ~32 / 64 Mi | ~96 Mi | ~192 Mi |
| MetalLB (controller + speakers) | — | — | ~80 Mi | ~150 Mi |
| fluent-bit | 3 (per node) | 32 / 64 Mi | 96 Mi | 192 Mi |
| **Total** | | | **~1.2 Gi** | **~2.2 Gi** |

**Measured in the Phase 0 audit (2026-09-23):** every node has 3.8 GiB RAM, **~3.58 GiB allocatable**, so the two workers offer **~7.1 GiB** for pods (the planning assumption of 2 GB was wrong). Requests (~1.2 Gi) and limits (~2.2 Gi) fit comfortably, with room for HPA scale-out and rolling-update surge pods.

We **keep the tight limits anyway**: small limits are good practice, and they make `OOMKilled`/QoS behaviour easy to demonstrate. The spare headroom makes Argo CD (GitOps) and a light Prometheus possible as stretch goals.

**The real constraint is disk, not RAM:** 10–12 GB root disks, 69–83 % used, and cka-w2 was already under `DiskPressure`. Disks must be grown before we deploy anything (see `docs/phases/phase-00-foundation.md`).

## 7. Open questions (to resolve in Phase 1)
- Admin features: separate admin UI or same frontend with an `admin` role? (Admin needs: add menu items, create coupons.)
- Discount rules: flat amount vs percentage, per-user limits, expiry?
- Notification channels to simulate: SMS, email, or both?
- Backup retention period for pg_dump.
