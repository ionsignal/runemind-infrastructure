# Nerrus Infrastructure Roadmap: Source of Truth

**Mission:** Architect and maintain a high-performance, hybrid-workload edge server balancing a ~30B parameter MoE LLM (AI Inference) and real-time Minecraft game servers (LXD) within a strict Zero-Trust DMZ environment. All workloads, including the AI engine, operate strictly within unprivileged containers to ensure absolute host isolation.

### Environment & Hardware Baseline

- **Hostname:** `is-compute-01`
- **Hardware:** ASUS ESC4000 G3 (High-RPM cooling, thermal throttling risk under sustained AI load).
- **Compute:** 4x NVIDIA RTX A4000 GPUs (64GB VRAM total).
- **Network Zone:** DMZ (VLAN 2) | Subnet: `172.20.2.0/24` | Gateway: `172.20.2.1` (EFG).
- **Host IP:** `172.20.2.115` (Static via `bond0` Active-Backup; LACP 10GbE intentionally deferred for baseline setup).
- **Storage Layout:**
  - _OS Drive:_ 250GB NVMe (`/dev/nvme0n1`, Ubuntu 24.04 LTS, ext4, No LVM).
  - _AI Vault:_ 2TB NVMe (`/dev/nvme1n1`, ZFS Pool `nvme-pool`, dedicated to LXD for high-speed LLM model weight loading).
  - _Game Tier:_ 4x 500GB SATA HDDs/SSDs (`/dev/sda` - `/dev/sdd`, ZFS Pool configured for LXD Custom Storage Volumes).

### Architectural Constraints

- **Zero-Trust DMZ:** The host cannot initiate outbound connections to Internal (`192.168.x.x`, `10.x.x.x`) or Home (`172.20.3.0/24`) networks.
- **Defense-in-Depth Containerization:** No workloads run directly on the bare-metal host OS. Both the AI Inference Engine and Game Servers operate inside heavily restricted, unprivileged LXD containers.
- **Micro-CA SSL:** Wildcard certificates (`*.ionsignal.com`) are generated securely via Caddy using the `acme-dns` plugin. The `acme-dns` service runs on an isolated AWS ARM64 instance to prevent storing highly privileged AWS Route 53 IAM credentials on the on-premise DMZ host.

---

## Phase 1: Bare Metal Foundation & Hardening [COMPLETED]

_Objective: Establish a secure host environment, enforce network boundaries, integrate the Micro-CA, and provision raw storage._

- **[✓] Base OS & UEFI Clean-Up:** Secure Boot disabled. Ubuntu 24.04 LTS installed cleanly on the 250GB NVMe.
- **[✓] Host Hardening & Defense-in-Depth:** Root login and password authentication disabled. UFW configured with strict outbound fencing (blocking internal RFC1918 subnets) and restricted inbound access.
- **[✓] Static Network Configuration:** `bond0` configured in Active-Backup mode for high availability and ARP stability.
- **[✓] Zero-Trust Micro-CA Integration:** Caddy compiled natively with `acme-dns`, stripped of root privileges using Linux capabilities (`CAP_NET_BIND_SERVICE`), and configured to terminate wildcard SSL. AWS ARM64 instance configured as the authoritative ACME DNS server.
- **[✓] LXD Minimal Initialization:** LXD 6.x LTS installed, bound strictly to `127.0.0.1:8443`, and proxied securely through Caddy using an mTLS client-certificate bridge and BasicAuth.
- **[✓] High-Performance Storage Provisioning:** ZFS pools successfully created and handed over to LXD (`nvme-pool` on `/dev/nvme1n1` for AI, and a secondary ZFS pool spanning the SATA drives for game data). ZFS ARC clamped to 4GB to prevent host OOM conditions.

---

## Phase 2: AI Infrastructure Containerization (Current Phase)

_Objective: Deploy the Qwen ~30B MoE LLM securely within an unprivileged LXD container, utilizing GPU passthrough to maintain bare-metal PCIe efficiency._

- **NVIDIA Host Stack:** Install proprietary v535+ drivers natively on the host OS to initialize the PCIe devices (CUDA toolkit installation on host is no longer required due to containerization).
- **Containerized Engine Deployment (Pivot B):**
  - Provision a dedicated, unprivileged LXD container for the AI engine.
  - Utilize LXD's native GPU passthrough (`lxc config device add [container] gpu gpu`) to map the 4x RTX A4000s directly into the container namespace.
  - Install Docker _nested_ inside this LXD container to run the vLLM (or SGLANG) image, isolating the host from potential RCE vulnerabilities in the AI API.
- **Execution Strategy:** Launch the inference engine utilizing FP8 Quantization and `--tensor-parallel-size 4` to stripe the model perfectly across the passed-through GPUs.
- **Thermal Management:** Implement a cron/systemd service on the _host_ to monitor `nvidia-smi -q -d TEMPERATURE` and alert on thermal throttling, ensuring the high-RPM ASUS chassis fans are mitigating the sustained inference load.

---

## Phase 3: LXD & Minecraft Decoupled State

_Objective: Establish a highly dynamic, ephemeral containerization layer for game servers using ZFS Copy-on-Write._

- **Decoupled State Architecture (Pivot A):**
  - Minecraft containers are treated as **ephemeral, disposable compute**.
  - Leverage ZFS Copy-on-Write to spin up base Ubuntu/PaperMC server images in milliseconds.
  - Persistent state (Player Worlds, Shared Plugins, Configurations) is completely decoupled into **LXD Custom Storage Volumes**. These volumes are attached at runtime and survive container teardowns, allowing for independent snapshotting and backups.
- **Network Fencing:** Ensure the `lxdbr0` bridge routes correctly through the host's `bond0` interface. Apply strict LXD network ACLs to ensure Minecraft containers cannot access the AI container's API port unless explicitly authorized.
- **Container Architecture:** Deploy unprivileged Ubuntu containers using declarative YAML profiles.
  - Container 1: Velocity Proxy (Static IP on `lxdbr0`).
  - Containers 2-N: PaperMC backend servers (Ephemeral, mounting Custom Storage Volumes).

---

## Phase 4: Edge Routing & SSL Termination

_Objective: Connect workloads to the public internet securely and route internal HTTPS._

- **DDoS & Edge:** Player traffic hits `play.ionsignal.com` (or `runemind.com`) via TCPShield.
- **Firewall Routing:** The upstream EFG firewall port-forwards TCP 25565 directly to the Velocity Proxy container IP on the `lxdbr0` network.
- **Proxy Protocol:** Velocity MUST be configured to accept the Proxy Protocol (v2) from TCPShield so backend PaperMC servers log the true player IPs.
- **Internal API Routing:** Caddy continues to act as the primary reverse proxy. It will securely route authenticated AI API requests from the network directly into the AI LXD container's IP (e.g., `10.x.x.x:8080`) while stripping buffering (`flush_interval -1`) to allow zero-latency LLM token streaming (SSE).
