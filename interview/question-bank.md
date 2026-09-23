# Interview Question Bank

Collected as we go. Answer each in your own words first, then compare with the concept file.

## Architecture & design
1. The client wants microservices for 50 concurrent users. What do you tell them? *(Hint: charter §3)*
2. When would you use a synchronous call vs an async event between two services? Give an example from GaramChai. *(ADR-002)*
3. Why is discount-service not exposed through the ingress, even though the frontend needs discounts?
4. Why does notification-service have no Kubernetes Service?
5. "Database per service" with a single Postgres instance: is that cheating? Defend it.
6. Why did we avoid ingress-nginx? *(ADR-001)*

## Objects
*(Added per phase.)*
