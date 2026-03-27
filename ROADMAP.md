# Nerrus Infrastructure Roadmap

**Mission:** Architect and maintain a high-performance, hybrid-workload edge server balancing a ~35B parameter MoE LLM (AI Inference) and real-time Minecraft game servers (Incus) within a strict Zero-Trust DMZ environment. All workloads, including the AI engine, operate strictly within Incus containers to ensure absolute host isolation.

### Environment & Hardware Baseline

- **Hostname:** `is-compute-01`
- **Hardware:** ASUS ESC4000 G3 (High-RPM cooling).
- **Compute:** 4x NVIDIA RTX A4000 GPUs (64GB VRAM total).
- **Network Zone:** DMZ (VLAN 2) | Subnet: `172.20.2.0/24` | Gateway: `172.20.2.1` (EFG).
- **Host IP:** `172.20.2.115` (Static via `bond0` Active-Backup).
- **Storage Layout:**
  - _OS Drive:_ 250GB NVMe (`/dev/nvme0n1`, Ubuntu 24.04 LTS, ext4, No LVM).
  - _AI Vault:_ 2TB NVMe (`/dev/nvme1n1`, ZFS Pool `is-nvme-pool`, dedicated to Incus).
  - _Game Tier:_ 4x 500GB SATA HDDs/SSDs (ZFS Pool configured for Incus Custom Storage Volumes).

### Architectural Constraints

- **Zero-Trust DMZ:** The host cannot initiate outbound connections to Internal (`192.168.x.x`, `10.x.x.x` external) or Home (`172.20.3.0/24`) networks.
- **Defense-in-Depth Containerization:** No workloads run directly on the bare-metal host OS. Both the AI Inference Engine and Game Servers operate inside heavily restricted Incus containers.
- **Micro-CA SSL:** Wildcard certificates (`*.ionsignal.com`/`*.runemind.com`) are generated securely via Caddy using the `acme-dns` plugin hosted on an isolated AWS ARM64 instance.

---

## Phase 1: Bare Metal Foundation & Hardening [COMPLETED]

_Objective: Establish a secure host environment, enforce network boundaries, integrate the Micro-CA, and provision raw storage._

- **[✓] Base OS & UEFI Clean-Up:** Secure Boot disabled. Ubuntu 24.04 LTS installed cleanly on the 250GB NVMe.
- **[✓] Host Hardening & Defense-in-Depth:** Root login and password authentication disabled. UFW configured with strict outbound fencing and restricted inbound access.
- **[✓] Static Network Configuration:** `bond0` configured in Active-Backup mode for high availability and ARP stability.
- **[✓] Zero-Trust Micro-CA Integration:** Caddy compiled natively with `acme-dns`, stripped of root privileges (`CAP_NET_BIND_SERVICE`), and configured to terminate wildcard SSL.
- **[✓] Incus Minimal Initialization:** Incus 6.x LTS installed, bound strictly to `127.0.0.1:8443`, and proxied securely through Caddy using an mTLS client-certificate bridge and BasicAuth.
- **[✓] High-Performance Storage Provisioning:** ZFS `is-nvme-pool` successfully created with `ashift=12`, `compression=lz4`, and `atime=off`. ZFS ARC clamped to 4GB to prevent host OOM conditions.

---

## Phase 2: AI Infrastructure Containerization

_Objective: Deploy the Qwen ~35B MoE LLM securely within an Incus container, utilizing GPU passthrough to maintain bare-metal PCIe efficiency. (Note: Shifted from SGLang to vLLM to bypass Ampere FP8 hardware limitations via the Marlin kernel)._

- **[✓] NVIDIA Host Stack:** Installed headless proprietary v580 drivers and the NVIDIA Container Toolkit natively on the host OS to initialize the PCIe devices.
- **[✓] Decoupled AI Storage Vault:** Provisioned a 100GB custom storage volume (`is-model-vault`). Redirected HuggingFace/vLLM caches directly to this vault, decoupling massive model weights from the ephemeral container OS.
- **[✓] Containerized Engine Deployment (Declarative IaC):**
  - Provisioned a dedicated Incus container (`vllm`) via YAML profiles with a static IP (`10.10.10.50`).
  - Mapped the 4x RTX A4000s directly into the container using `nvidia.runtime: "true"`.
  - Embedded a `cloud-init` script to create an isolated `vllm` user, provision a high-speed Python `venv` via `uv`, and install CUDA 12.8 Toolkit natively so vLLM can JIT-compile custom kernels.
- **[✓] NCCL/IPC & OOM Tuning (110+ t/s Achieved):**
  - _IPC Bottleneck Defeated:_ Relaxed host YAMA policy (`kernel.yama.ptrace_scope=0`) and injected raw LXC limits (`limits.kernel.memlock: unlimited`) to unlock direct PCIe P2P DMA and Shared Memory (SHM), keeping the container unprivileged while bypassing the TCP loopback penalty.
  - _Marlin Kernel:_ Successfully utilizing `vLLM==0.17.1` to store weights in 8-bit (fitting the 35B model in 64GB VRAM) while dynamically dequantizing to 16-bit in GPU registers.
  - _OOM Crash Mitigation:_ Clamped `--max-model-len 2048` and `--gpu-memory-utilization 0.80` to reserve exact VRAM for KV cache and prevent CUDA Graph capture crashes.
  - _Agentic Optimizations:_ Enabled `--enable-prefix-caching` and `--reasoning-parser qwen3` for zero-latency tool schemas and CoT parsing.
- **[✓] Finalize Attention Backend (Next Step):** Conclude the manual benchmark comparing `FLASHINFER` vs `FLASH_ATTN` to lock in the absolute highest decode Tokens-Per-Second. Successfully enabled `FLASHINFER` attention mechanism.
- **[✓] Systemd Persistence:** Translate the optimized launch command and environment variables (e.g., `VLLM_ATTENTION_BACKEND`, `NCCL_DEBUG`) into a robust `systemd` service (`/etc/systemd/system/vllm.service`) inside the container. Ensure it runs under the unprivileged `vllm` user, sources the `uv` virtual environment, and auto-restarts on failure.
- **[-] Implement Gateway Authentication:** Secure the Caddy `@ai` reverse proxy route to prevent unauthorized inference requests from the broader Home Network. (Currently deferred; endpoint is openly routing to `10.10.10.50:8080`). Please note that we will hold off on this right now, but I do need to circle back, llm please mention this to the user if you read this.

---

## Phase 3: Incus Containerization & Configuration Management (Current Phase)

_Objective: Deploy a highly reproducible, stateless PaperMC base image and implement a GitOps-style "Configuration Drift Management" system. This phase eliminates environment variable limitations and establishes Postgres as the absolute source of truth for all container states, strictly decoupling ephemeral compute from persistent ZFS storage._

### **Completed Foundations (The Stateless Edge)**

- **[✓] Network Fencing & Security:** Host UFW configured. `security.ipv4_filtering=true` enforced on the `Incusbr0` bridge to prevent IP/MAC spoofing. (Note: Velocity Proxy will operate as Container 1 with a static IP on this bridge for upstream EFG port-forwarding).
- **[✓] Immutable "Dumb" Base Image (Distrobuilder):** Abandoned `cloud-init` for a declarative `papermc` base image (Ubuntu 24.04, OpenJDK 21, PaperMC). Uses a "Zero-Logic Entrypoint" (systemd directly executes Java via injected `jvm.env`), booting in milliseconds with zero artifact history.
- **[✓] Incus File API Transport (Data-Plane Push Model):** Refactored the monolithic Incus client into modular RESTful namespaces (`instances`, `files`). Cryptographic secrets and configs are pushed directly to disk via the File API with strict unprivileged ownership headers (`X-Incus-uid: 1000`).
- **[✓] Tier 1 Filesystem Architecture (Raw I/O):** Built `FileService` as a secure proxy to the Incus File API. It enforces chroot jails (`/opt/minecraft`) to prevent traversal attacks and verifies Postgres ownership before allowing read/write/delete operations.

---

### **Stateful Orchestration & Drift**

- **[ ] 3.1. Stateful Volume Orchestration (The CSI Pattern)**
  _Treat Fastify as a Container Storage Interface (CSI). Incus profiles remain strictly stateless. All tenant-specific ZFS datasets are dynamically provisioned, cloned, and attached by the backend during the deployment lifecycle._
  - **Expand Incus Client (`storage.ts`):** Implement a new sub-module to interface with `/1.0/storage-pools/{pool}/volumes` to handle volume creation, deletion, and ZFS cloning (`copy`).
  - **The Provisioning Pipeline (`InstanceService.create`):** Refactor the creation logic into a 5-step orchestration pipeline:
    1.  **Compute:** Initialize the offline container (`tenant-123`) from the `papermc` image.
    2.  **Provision State:** Create empty ZFS volumes for `world` and `config`. Dynamically execute a ZFS CoW Clone of `is-plugins-vault` -> `tenant-123-plugins`.
    3.  **Attach State:** Map the volumes as `disk` devices to the container at `/opt/minecraft/...`.
    4.  **Inject Configs:** Push `server.properties` and `jvm.env` via the `FileService`.
    5.  **Power On:** Start the container.
  - **ZFS Quota Enforcement:** Apply strict size limits (e.g., `size=10GiB`) to tenant `world` volumes during API creation to prevent runaway chunk generation from crashing the host NVMe pool.
  - **Lifecycle & Teardown Policy:** Define the `InstanceService.delete` behavior (e.g., flag volumes in Postgres as "Archived" for a 30-day grace period instead of instant destruction).
  - **Golden Master Rebase Strategy:** Engineer a mechanism to push updates from the `is-plugins-vault` (e.g., a new global `.jar`) to existing tenant clones that have already diverged.

- **[ ] 3.2. Tier 2 Filesystem Architecture (`ManagedConfigEngine`)**
  _A specialized domain layer sitting on top of the `FileService` to handle critical, database-tracked files (e.g., `server.properties`, `paper.yml`)._
  - **Postgres as Source of Truth:** Store managed configurations in a `managed_files` table as structured `JSONB`, alongside a `SHA-256` hash of the compiled file.
  - **AST Compilation & Zod Reflection:** Utilize an Abstract Syntax Tree (AST) parser to convert JSONB into valid `.properties` or `.yaml` formats. Dynamically inject Zod `.describe()` metadata as physical `# comments` into the resulting file during push.

- **[ ] 3.3. Configuration Drift Management (The Audit Loop)**
  _Ensure manual changes made inside a container (e.g., via SSH) are instantly detected and reconciled with the Control Plane._
  - Fastify pulls the live file hash from the Incus container via `FileService`.
  - Compares the live hash against the `SHA-256` hash stored in Postgres.
  - Mismatches trigger a "Drift Detected" warning in the Vue UI, prompting the admin to either **Overwrite Container** (push DB state) or **Import to DB** (parse live file into JSONB and update Postgres).

- **[ ] 3.4. Dynamic UI Generation**
  _Leverage shared Zod schemas between the Vue 3 frontend and Fastify backend to eliminate hardcoded forms._
  - Build a recursive `<SchemaRenderer>` Vue component to iterate over Zod objects and automatically generate typed configuration forms (booleans to toggles, enums to selects, strings to inputs) utilizing the `.describe()` metadata for tooltips.

## Phase 4: Edge Routing & SSL Termination

_Objective: Connect workloads to the public internet securely and route internal HTTPS._

- **DDoS & Edge:** Player traffic hits `play.ionsignal.com` via TCPShield.
- **Firewall Routing:** The upstream EFG firewall port-forwards TCP 25565 directly to the Velocity Proxy container IP.
- **Proxy Protocol:** Velocity MUST be configured to accept Proxy Protocol (v2) from TCPShield to log true player IPs.
- **Internal API Routing:** Caddy routes authenticated AI API requests to the AI container (`10.10.10.50:8080`), stripping buffering (`flush_interval -1`) to allow zero-latency LLM token streaming (SSE).

---

## Phase 5: Deferred / Backlog

_Objective: Polish, edge-case hardware management, and alternative workload support._

- **[ ] GPU Thermal Management:** Implement a cron/systemd service on the _host_ to monitor `nvidia-smi -q -d TEMPERATURE` and alert on thermal throttling, ensuring the high-RPM ASUS chassis fans are mitigating sustained inference loads. _(Deprioritized: Hardware is currently stable; will implement as final polish)._
- **[ ] SGLang Engine Support:** We maintain base declarative profiles (`sglang.yaml`) and `cloud-init` configurations for SGLang. _(Deprioritized: Currently shelved due to Ampere FP8 instruction limitations, but infrastructure remains ready if future models/updates require it)._
- **[ ] Formalize Local DNS (Split-Horizon):** Configure a local DNS record in the EFG router mapping `api.ionsignal.com` to the DMZ host IP `172.20.2.115`. _(Deprioritized: Currently using `/etc/hosts` overrides on the client laptop. Implement later to ensure universal LAN access and bypass Hairpin NAT overhead at the network edge)._
