# Study notes (PDF)

Phase-wise interview study notes built from what we actually did in the lab. Each one: plain explanations, analogies, diagrams, interview lines, a quiz and an answer key.

| # | PDF | Covers |
|---|---|---|
| 1 | [01-phase0-cluster-fundamentals.pdf](01-phase0-cluster-fundamentals.pdf) | Components and their jobs, tools, request flow, boot sequence and static pods, kubeadm init/join, default objects, namespaced vs cluster-scoped, Allocatable, taints, authN/authZ, certificates vs ServiceAccounts |
| 2 | [02-phase0-lab-networking.pdf](02-phase0-lab-networking.pdf) | The 4 networks, overlaps, packet journeys (IPIP, Services), ADR-003, split-horizon `k8s-api`, CoreDNS, production network design |
| 3 | [03-phase0-audit-incident-rebuild.pdf](03-phase0-audit-incident-rebuild.pdf) | Cluster audit, LVM disk fix, the etcd data-loss incident (evidence, root cause, STAR story), rebuild from kubeadm-config.yaml |
| 4 | [04-phase0-etcd-backup-restore.pdf](04-phase0-etcd-backup-restore.pdf) | Backup checklist, snapshot + PKI, systemd timer, restore step by step, validation |
| 5 | [05-phase1-requirements.pdf](05-phase1-requirements.pdf) | Functional requirements and order lifecycle, load and availability math, RPO/RTO, business case, data protection, cluster access |
| + | [../guides/high-availability-99.99.pdf](../guides/high-availability-99.99.pdf) | Bonus: 99.99 % on AWS (SLA/SLO/SLI, MTTR, DR, cost) |

**Rebuild the PDFs** after editing an `.html` file (Git Bash on Windows): `bash docs/study/build.sh`
