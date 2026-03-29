## Infrastructure Roadmap

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

### **Stateful Orchestration & Drift (Hybrid Architecture)**

_Architectural Pivot: To support heterogeneous workloads (Minecraft, ComfyUI, vLLM) without brittle AST parsers, we are adopting a Hybrid State Model. The "Control Plane" (Postgres) strictly dictates infrastructure boundaries, while the "Data Plane" (ZFS Disk) acts as the absolute Source of Truth for application-level configurations._

- **[-] 3.1. Stateful Volume Orchestration (The CSI Pattern)**
  _Treat Fastify as a Container Storage Interface (CSI). Incus profiles remain strictly stateless. All tenant-specific ZFS datasets are dynamically provisioned, cloned, and attached by the backend during the deployment lifecycle._
  - **[✓] Expand Incus Client (`storage.ts`):** Implemented a dedicated sub-module interfacing with `/1.0/storage-pools/{pool}/volumes/custom` to handle volume creation, deletion, and near-instant ZFS cloning (`copy`).
  - **[✓] The Provisioning Pipeline (`InstanceService.create`):** Refactored creation logic into a robust orchestration pipeline with automated rollback on failure:
    1.  **Compute:** Initialize the offline container (`tenant-123`) from the `papermc` image.
    2.  **Provision State:** Dynamically execute ZFS CoW Clones of `is-world-vault` -> `01-tenant-world` and `is-plugins-vault` -> `01-tenant-plugins` with VFS idmapping (`security.shifted=true`).
    3.  **Attach State:** Map the volumes as `disk` devices to the container at `/opt/minecraft/...`.
    4.  **Inject Configs:** Push baseline `server.properties` and `jvm.env` via the `FileService`.
    5.  **Deferred Power On:** Container is safely locked into an `offline` state, awaiting explicit user start.
  - **[ ] ZFS Quota Enforcement:** Apply strict size limits (e.g., `size=10GiB`) to tenant `world` volumes during API creation to prevent runaway chunk generation from crashing the host NVMe pool. (Currently missing from the `config` payload).
  - **[ ] Lifecycle & Teardown Policy:** Refactor `InstanceService.delete` behavior. (Currently performs instant destruction; needs to be updated to flag volumes in Postgres as "Archived" for a 30-day grace period before physical ZFS destruction).
  - **[ ] Golden Master Rebase Strategy:** Engineer a mechanism to push updates from the `is-plugins-vault` (e.g., a new global `.jar`) to existing tenant clones that have already diverged.

- **[ ] 3.2. Layer 1: The Control Plane (Infrastructure State & SSoT)**
  _Postgres acts as the absolute dictator for container boundaries, networking, and resource limits. These files are never manually edited by users._
  - **Database-Driven Templating:** Store infrastructure variables (e.g., RAM limits, GPU allocation, port bindings) in Postgres.
  - **Boot-Time Injection:** During container startup, Fastify compiles these variables into strictly formatted environment files (e.g., `jvm.env`, `vllm.service`) and pushes them to the container.
  - **One-Way Enforcement (Anti-Drift):** If a user maliciously or accidentally alters these protected files via SFTP, the Control Plane blindly overwrites them on the next state transition, ensuring host routing and host memory are never compromised.

- **[ ] 3.3. Layer 2: The Data Plane (Application State & Disk as SSoT)**
  _The ZFS volume is the absolute source of truth for heterogeneous application configs (`server.properties`, `paper.yml`, ComfyUI `settings.json`). We do not store this state in Postgres, eliminating parser maintenance and respecting native app behaviors._
  - **Live Disk I/O Pipeline:** Fastify reads the live file directly from the Incus container via `FileService`, parses it (YAML/Properties/JSON), and validates the resulting object against a Zod schema before sending it to the frontend.
  - **Atomic Writes & ETag Locking:** When the UI saves changes, Fastify converts the JSON back to the target format and pushes it to disk. It utilizes Incus `ETag` headers to ensure atomic writes and prevent race conditions with simultaneous SFTP or in-game edits.
  - **Caveat - The "Destructive Save":** Accept the UX tradeoff that saving via the typed UI will normalize the file format and strip manual `# comments` or custom spacing created via SFTP.
  - **Raw Editor Fallback:** For unstructured files, complex Spigot configurations, or ComfyUI custom nodes that lack a Zod schema, provide a raw Monaco (VSCode) text editor in the browser to allow admins to edit the disk string directly (which _does_ preserve comments).
  - **Application Lifecycle Hooks:** Implement a mechanism to prompt the user to restart the container (or auto-trigger a reload) when Data Plane files are modified, as most applications do not hot-reload configuration files.

- **[ ] 3.4. Dynamic UI Generation (Zod Reflection)**
  _Leverage shared Zod schemas between the Vue 3 frontend and Fastify backend to eliminate hardcoded forms, adapting instantly to whichever file is loaded from the Data Plane._
  - **Schema-Driven Forms:** Build a recursive `<SchemaRenderer>` Vue component. It iterates over the Zod object (e.g., `ServerPropertiesSchema`) provided by the backend, automatically mapping types to Naive UI inputs (booleans to toggles, enums to selects, numbers to sliders).
  - **Metadata Tooltips:** Extract `.describe()` metadata from the Zod schemas to automatically generate helpful UI tooltips for complex application settings, providing self-documenting infrastructure without maintaining separate UI text.

---

## Phase 5: Deferred / Backlog

_Objective: Polish, edge-case hardware management, and alternative workload support._

- **[ ] GPU Thermal Management:** Implement a cron/systemd service on the _host_ to monitor `nvidia-smi -q -d TEMPERATURE` and alert on thermal throttling, ensuring the high-RPM ASUS chassis fans are mitigating sustained inference loads. _(Deprioritized: Hardware is currently stable; will implement as final polish)._
- **[ ] SGLang Engine Support:** We maintain base declarative profiles (`sglang.yaml`) and `cloud-init` configurations for SGLang. _(Deprioritized: Currently shelved due to Ampere FP8 instruction limitations, but infrastructure remains ready if future models/updates require it)._
- **[ ] Formalize Local DNS (Split-Horizon):** Configure a local DNS record in the EFG router mapping `api.ionsignal.com` to the DMZ host IP `172.20.2.115`. _(Deprioritized: Currently using `/etc/hosts` overrides on the client laptop. Implement later to ensure universal LAN access and bypass Hairpin NAT overhead at the network edge)._
