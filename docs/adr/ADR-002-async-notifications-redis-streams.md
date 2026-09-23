# ADR-002: Notifications are asynchronous via Redis Streams; discounts are synchronous

- **Status:** Accepted
- **Date:** 2026-09-23

## Context
Two services were added to the scope: **discount-service** and **notification-service**. Both are triggered during checkout in order-service. We must decide *how* order-service talks to each.

The rule: **use synchronous calls only when the caller needs the answer to continue.**

| | Needs answer to finish checkout? | Can the order succeed if it's down? |
|---|---|---|
| discount-service | Yes (final price) | Yes: continue without discount (timeout ~500 ms) |
| notification-service | No | Must: a failed SMS must never fail an order |

## Decision
- **discount-service**: synchronous HTTP (`POST /validate`), ClusterIP Service, **not routed** by Traefik. Only order-service may call it (NetworkPolicy in Phase 8).
- **notification-service**: order-service publishes `order.placed` to a **Redis Stream**. notification-service is a worker in a **consumer group**, with no Service and no inbound port.
- Reuse the existing Redis instead of adding RabbitMQ or Kafka.

## Alternatives rejected
- **Synchronous HTTP to notification**: couples checkout availability to SMS delivery.
- **RabbitMQ / Kafka / NATS**: correct in production, but 150–500 MB+ RAM on small lab nodes, and not a Kubernetes-object lesson.

## Consequences
- ✅ Checkout keeps working when notification is down; events queue up in the stream.
- ✅ Teaches a Deployment without a Service, exec probes, and egress-only NetworkPolicy.
- ⚠️ Redis becomes more critical (cache + queue). It needs persistence (AOF) on a PVC, or events are lost on restart.
- ⚠️ At-least-once delivery: a notification may be sent twice after a crash. The worker must be idempotent (skip if the order id is already notified).
