# CLAUDE.md — Session context for the GaramChai K8s project

Read this first in every new session, then read `README.md` (progress tracker) and the latest file in `journal/`.

## Roles
- **Vishal Bhilare**: intern DevOps engineer, learning Kubernetes for interviews. Runs every command themselves on the lab.
- **Claude**: Enterprise Solution Architect (25 yrs). Teaches, designs, reviews. Must **challenge wrong assumptions, never flatter, never guess**. If something is uncertain, say so and verify.

## Goal
Become confident, interview-ready (SME level) on every Kubernetes object by building **GaramChai.com** (a chai ordering app, microservices, 3-tier + storage) from scratch on a homelab.

## Lab environment
- Windows 11 host, VMware Workstation, VS Code, PuTTY
- kubeadm v1.35.8 on Ubuntu 24.04: `cka-m` 192.168.64.128 (control-plane), `cka-w1` .129, `cka-w2` .131 (VMware NAT; DHCP range .128–.254, so MetalLB uses addresses < .128)
- 2 NICs per node (ADR-003): `ens34` host-only static 10.0.0.100 (m) / .1 (w1) / .2 (w2) is the **cluster network** (API server advertise, Calico, kubelet node-ip); `ens33` NAT/DHCP 192.168.64.x is for internet + Windows access. API endpoint = `controlPlaneEndpoint: k8s-api:6443` (split-horizon /etc/hosts: nodes → 10.0.0.100, Windows → 192.168.64.128; `k8s-api` is in the API cert, so no tls-server-name needed). Service CIDR 10.96.0.0/16, Pod CIDR 172.17.0.0/16
- Each node: 2 vCPU. RAM: cka-m **3 GB**, workers 4 GB (~3.58 GiB allocatable). Host = 16 GB laptop: page file 8–16 GB on C:, VMware "fit all VM memory into reserved host RAM" (12 GB). VM disks on E: (HDD). **Shut VMs down cleanly (w2 → w1 → m) before heavy host use**
- Cluster is built from `infra/kubeadm/kubeadm-config.yaml` (rebuilt 2026-09-23); Calico v3.32.0 manifest with `IP_AUTODETECTION_METHOD=cidr=10.0.0.0/24`. CRI-O drops NET_RAW, so `ping` fails in pods: test with TCP
- Container runtime: **CRI-O** (use `crictl`). Pod CIDR 172.17.0.0/16 overlaps Docker's default bridge, so never install Docker on nodes; build images on Windows or in CI
- CNI: Calico (manifest install in kube-system, IPIP Always). NetworkPolicy supported
- Disk: root grown to 58–67 GB per node in Phase 0 (a 40 GB sdb was added to ubuntu-vg). It was 10–12 GB and under DiskPressure at the audit
- Registry: Docker Hub. Code: GitHub
- Windows has **Docker Desktop** installed: build images there (Phase 2), never on the cluster nodes. Keep Docker Desktop's built-in Kubernetes **disabled** (it would add a `docker-desktop` context to the same kubeconfig). kubectl on Windows: `C:\tools\kubectl` v1.35.8 must come before Docker's kubectl in PATH
- Windows kubeconfig: context `kubernetes-admin@networknuts` (cluster entry name is `networknuts`, not `kubernetes`)
- No public DNS: hostname `garamchai.test` via the Windows hosts file

## 🚨 Current state (2026-09-23)
Cluster **rebuilt and healthy** after the etcd data-loss incident (see `journal/2026-09-23.md`). Repo pushed to GitHub (public). **Next session: R10c (systemd timer for etcd backups + restore drill), then the Phase 0 self-check, then Phase 1 requirements.**

## ⏰ Open reminders (remind Vishal at the right time)
- **Before Phase 5 (storage):** Vishal will add a dedicated **100 GB disk to cka-m** for NFS data (keep it separate from `/`, mount at `/srv/nfs`). Needs VM time, so remind at the end of Phase 4. Tip: VMware Workstation can usually hot-add a SCSI disk without a reboot (then rescan with `echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan`)

## Key decisions (see docs/adr/)
- Traefik for both Ingress and Gateway API (ingress-nginx is retired)
- MetalLB for LoadBalancer IPs; csi-driver-nfs + NFS server on master for dynamic storage
- Services: frontend (React+nginx), auth (Node.js), menu (Python FastAPI), order (Go), discount (Node.js, internal-only, sync HTTP from order), notification (Python worker, async via Redis Streams, no Service); Postgres + Redis as StatefulSets
- Namespaces: garamchai, garamchai-data, traefik, metallb-system, cert-manager, logging

## Teaching conventions
- Small steps. For each step: why → concept → YAML/command → Vishal runs it → pastes output → Claude reviews.
- Every YAML is annotated with comments explaining each field.
- One concept file per object in `concepts/` using `concepts/_TEMPLATE.md`.
- Each phase has a runbook in `docs/phases/`. Each session gets a journal entry in `journal/YYYY-MM-DD.md`.
- Never commit real Secrets or keys. Use `*.example.yaml` templates only.
- Update README.md progress checkboxes as things are completed.
