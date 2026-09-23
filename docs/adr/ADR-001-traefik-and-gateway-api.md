# ADR-001: Traefik as the ingress controller (Ingress + Gateway API)

- **Status:** Accepted
- **Date:** 2026-09-23

## Context
We need one entry point for `https://garamchai.test` that routes by path to frontend, auth, menu and order services and terminates TLS. The learning goals include **both** `Ingress` and the newer **Gateway API** (`GatewayClass`, `Gateway`, `HTTPRoute`).

Options considered:
1. **ingress-nginx**: most tutorials use it, but the Kubernetes project **retired** it (maintenance ended March 2026). Building new work on a retired component is a bad habit.
2. **NGINX Gateway Fabric / Envoy Gateway**: good Gateway API implementations, but weaker or no support for the classic `Ingress` object.
3. **Traefik**: a single lightweight controller (~64–128 Mi) that supports **both** `Ingress` and Gateway API.

## Decision
Use **Traefik**, installed with Helm into namespace `traefik`, exposed via a MetalLB `LoadBalancer` Service. Phase 7 first routes with `Ingress`, then recreates the same routes with `Gateway` + `HTTPRoute`, so the two can be compared side by side.

## Consequences
- ✅ One controller, low RAM, both APIs learned on the same app.
- ✅ Gateway API is the direction Kubernetes is moving. Knowing it is an interview advantage.
- ⚠️ Traefik has its own CRDs (`IngressRoute`, `Middleware`). We **won't** use them for routing, so our manifests stay portable standard Kubernetes.
- ⚠️ Many online examples assume ingress-nginx annotations. Those won't work here. That's worth knowing: annotations are controller-specific, while Gateway API fields are standard.
