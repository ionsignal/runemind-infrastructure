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

#### The Paradigm: Who is the Source of Truth?

To succeed long-term, we must strictly divide our "Truth" into three distinct pillars:

1.  **Postgres = The Business Truth.**
    - _What it knows:_ "User A owns an instance named `alpha-node`. They are allowed to use 4 CPUs. It is supposed to be a `papermc` app."
    - _What it DOES NOT know:_ How big the disk is, what IP address it has, or what the volumes are named.
2.  **The Blueprints (YAML) = The Genetic Code.**
    - _What it knows:_ "If someone asks to build a `papermc` app, here are the instructions (volumes, files, ports) to assemble it."
    - _What it DOES NOT know:_ Anything about existing servers. It is just a recipe book.
3.  **Incus (ZFS) = The Infrastructure Truth (The Data Plane).**
    - _What it knows:_ "I have a container named `alpha-node`. Attached to it are two ZFS datasets named `alpha-node-world` and `alpha-node-plugins`."

## Phase 1: Bare Metal Foundation & Hardening [COMPLETED]

_Objective: Establish a secure host environment, enforce network boundaries, integrate the Micro-CA, and provision raw storage._

- **[✓] Base OS & UEFI Clean-Up:** Secure Boot disabled. Ubuntu 24.04 LTS installed cleanly on the 250GB NVMe.
- **[✓] Host Hardening & Defense-in-Depth:** Root login and password authentication disabled. UFW configured with strict outbound fencing and restricted inbound access.
- **[✓] Static Network Configuration:** `bond0` configured in Active-Backup mode for high availability and ARP stability.
- **[✓] Zero-Trust Micro-CA Integration:** Caddy compiled natively with `acme-dns`, stripped of root privileges (`CAP_NET_BIND_SERVICE`), and configured to terminate wildcard SSL.
- **[✓] Incus Minimal Initialization:** Incus 6.x LTS installed, bound strictly to `127.0.0.1:8443`, and proxied securely through Caddy using an mTLS client-certificate bridge and BasicAuth.
- **[✓] High-Performance Storage Provisioning:** ZFS `is-nvme-pool` successfully created with `ashift=12`, `compression=lz4`, and `atime=off`. ZFS ARC clamped to 4GB to prevent host OOM conditions.

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

## Phase 3: Incus Containerization & Configuration Management

_Objective: Deploy a highly reproducible, stateless PaperMC base image and implement a GitOps-style "Configuration Drift Management" system. This phase eliminates environment variable limitations and establishes Postgres as the absolute source of truth for all container states, strictly decoupling ephemeral compute from persistent ZFS storage._

### **Completed Foundations (The Stateless Edge)**

- **[✓] Network Fencing & Security:** Host UFW configured. `security.ipv4_filtering=true` enforced on the `Incusbr0` bridge to prevent IP/MAC spoofing. (Note: Velocity Proxy will operate as Container 1 with a static IP on this bridge for upstream EFG port-forwarding).
- **[✓] Immutable "Dumb" Base Image (Distrobuilder):** Abandoned `cloud-init` for a declarative `papermc` base image (Ubuntu 24.04, OpenJDK 21, PaperMC). Uses a "Zero-Logic Entrypoint" (systemd directly executes Java via injected `jvm.env`), booting in milliseconds with zero artifact history.
- **[✓] Incus File API Transport (Data-Plane Push Model):** Refactored the monolithic Incus client into modular RESTful namespaces (`instances`, `files`). Cryptographic secrets and configs are pushed directly to disk via the File API with strict unprivileged ownership headers (`X-Incus-uid: 1000`).
- **[✓] Tier 1 Filesystem Architecture (Raw I/O):** Built `FileService` as a secure proxy to the Incus File API. It enforces chroot jails (`/opt/minecraft`) to prevent traversal attacks and verifies Postgres ownership before allowing read/write/delete operations.

### **Stateful Orchestration & Drift (Hybrid Architecture)**

_To support heterogeneous workloads (Minecraft, ComfyUI, vLLM) we are adopting a Hybrid State Model. The "Control Plane" (Postgres + Blueprints) strictly dictates infrastructure boundaries, while the "Data Plane" (ZFS Disk) acts as the absolute Source of Truth for application-level behaviors._

- **[✓] 3.1. Blueprints & The Hardware Ledger**
  _Separate "What an app is" (YAML Blueprints) from "Who owns it and what hardware it gets" (Postgres). This acts as the brain of the orchestrator, treating the Incus hypervisor as a "dumb" worker node._
  - **[✓] The Configuration Registry (Boot-Time Loading):** Implemented `DefinitionRegistryService`. On boot, Fastify scans `configs/applications/*.yaml`, parsing and strictly validating them against Zod schemas into an in-memory cache. Malformed blueprints trigger a fail-fast boot halt to guarantee configuration integrity.
  - **[✓] The Hardware Ledger (Postgres SSoT):** Expanded the Drizzle `instances` table with `definition`, `cpu`, and `memory` columns. This strictly decouples hardware quotas from static application configurations, allowing seamless underlying infrastructure updates.

- **[✓] 3.2. Execution & CSI Orchestration**
  _Refactored `InstanceService.create` into a generic state machine. It compiles the Incus payload by merging the Registry (Base Template) with the Ledger (Hardware Limits), completely removing hardcoded application logic from the backend._
  - **[✓] The Compilation Engine (Merging State):** When provisioning begins, Fastify dynamically generates the Incus API payload. It injects Postgres Ledger limits (e.g., `limits.memory`) into the Blueprint's `instance_template.config`, safely overriding base profile defaults.
  - **[✓] The Execution Pipeline (Incus API Saga):** Execute the compiled payload in a strict, orchestrated sequence:
    1. **Pre-Flight Storage (CSI):** Iterate over `provisioning.volumes`. Execute ZFS CoW clones or create empty datasets, automatically prefixing volume names (e.g., `<instanceName>-world`) to prevent tenant collisions.
    2. **Device Mapping:** Dynamically attach the newly provisioned ZFS volumes to the Incus `devices` map using the Blueprint's `mount_path`.
    3. **Container Creation:** Send the composed payload to the Incus `/instances` API.
    4. **Post-Flight File Injection:** Iterate over `provisioning.files`. Push interpolated files directly to the container disk via the Incus File API, enforcing `uid`/`gid` boundaries.
    5. **State Finalization:** Mark the instance as `offline` in Postgres and broadcast the NATS event.
  - **[✓] Template Variable Transformation:** Implemented context dictionaries and the `interpolate` utility to translate raw hardware limits into application-specific formats (e.g., `-Xms4G` for Java via `{{ limits.memory.java }}`).
  - **[✓] Dynamic Rollback Stack:** Implemented a LIFO (Last-In, First-Out) Saga rollback mechanism. If any step fails, the engine pops the stack sequentially, destroying the container and dynamically generated ZFS volumes to prevent orphaned "zombie" resources on the host.
  - **[✓] tRPC Hardware Quota Integration:** Updated the `instance.create` tRPC mutation to accept user-defined `cpu` and `memory` limits, passing them through to the execution pipeline.
  - **[ ] UI Hardware Quota Integration:** Update the Vue UI to expose CPU/Memory sliders and inputs, passing user selections to the `trpc.host.instance.create` mutation.
  - **[ ] Refactor Database Quota Types:** Change the `cpu` and `memory` columns in the Drizzle schema from `text` to `integer` to enforce stricter mathematical limits and validation logic.
  - **[ ] Micro-Engine Array Support:** Enhance the `interpolate` utility regex to safely parse and resolve array indices (e.g., `{{ network.ports[0] }}`) to support more complex blueprint variables.
  - **[ ] Build Configuration Cleanup:** Externalize the `yaml` dependency in `packages/ionhost/vite.config.ts` to prevent it from being bundled directly into the server distribution.

- **[ ] 3.3. Application State, Disk as SSoT, & Dynamic UI Generation**
  _The ZFS volume is the absolute source of truth for heterogeneous application configs (`server.properties`, ComfyUI `settings.json`). We do not store this state in Postgres. We leverage shared Zod schemas between the Vue 3 frontend and Fastify backend to adapt instantly to whichever file is loaded._
  - **[ ] Live Disk I/O Pipeline:** Utilizing the `application.editable_files` array in the Blueprint, Fastify reads the live file directly from the Incus container via `FileService`, parses it, and validates it against a shared Zod schema before sending it to the frontend.
  - **[ ] Atomic Writes & ETag Locking:** When the UI saves changes, Fastify converts the JSON back to the target format and pushes it to disk. It utilizes Incus `ETag` headers to ensure atomic writes and prevent race conditions with simultaneous SFTP or in-game edits.
  - **[ ] Raw Editor Fallback:** For unstructured files or complex configurations lacking a Zod schema, provide a raw Monaco (VSCode) text editor in the browser to allow admins to edit the disk string directly (preserving manual `# comments`).
  - **[ ] Schema-Driven Forms:** Build a recursive `<SchemaRenderer>` Vue component that iterates over the Zod object provided by the backend, automatically mapping types to Naive UI inputs based on the target file defined in the Blueprint.

## Deferred / Backlog

_Objective: Polish, edge-case hardware management, alternative workload support, and advanced user-facing features._

- **[ ] Multi-Tenant Web File Browser & Large-File Transport (The Sidecar Architecture):**
  _To support uploading and downloading massive binary files (5GB+ Minecraft worlds, 30GB+ `.safetensors` AI models) without bottlenecking the Fastify Node.js backend or the Incus hypervisor control plane, we will implement a dual-engine "Sidecar Container" architecture._
  - **The "Dumb Pipe" Sidecar:** Provision a dedicated, unprivileged `transfer` Incus container. This container runs two lightweight, high-performance binaries: **`tusd`** (for uploads) and **Caddy** (for static downloads).
  - **ZFS Multi-Attach (The Data Bridge):** When Fastify provisions a tenant's ZFS Custom Volume (e.g., `01-tenant-world`), it attaches that exact volume to _both_ the workload container (Minecraft/vLLM) and the `transfer` sidecar simultaneously via Incus `disk` devices. VFS idmapping (`security.shifted=true`) ensures seamless permission boundaries.
  - **Resumable Uploads (Uppy + Tus):** The Vue 3 frontend utilizes **Uppy** to chunk and stream large files directly to the `tusd` endpoint, providing enterprise-grade pause, resume, and automatic network retries. `tusd` validates authorization via a `pre-create` webhook to Fastify before writing to disk.
  - **Resumable Downloads (Caddy + Forward Auth):** Downloads are routed to the Caddy binary inside the sidecar, which utilizes kernel `sendfile` for zero-copy disk reads and natively supports HTTP `Range` requests for browser-level pause/resume. Caddy secures the files using `forward_auth`, forcing Fastify to validate the user's JWT before streaming begins.
  - **Zero-Overhead:** Fastify and the Incus API (`/1.0/instances/<name>/files`) are completely bypassed for large I/O. Data flows directly between the user and the ZFS dataset, appearing instantly in the workload container with zero network-sync overhead.
- **[ ] Event-Driven Drift Reconciliation (Self-Healing):** Utilize a real-time, Kubernetes-style Watch controller by expanding the Incus WebSocket connection to subscribe to `lifecycle` events. When Fastify detects a manual CLI alteration (e.g., `instance-updated`), it evaluates the incoming event against the Postgres Ledger (SSoT) and immediately issues a corrective API request to crush unauthorized configuration drift. A full state reconciliation (`InstanceService.reconcile`) runs exactly once on boot to cover any downtime windows.
- **[ ] Lifecycle & Archival Policy:** Instead of instant destruction, flag volumes in Postgres as "Archived" and utilize Incus to freeze the datasets for a 30-day grace period before executing physical ZFS destruction.
- **[ ] Fluid Hardware Hot-Plugging (GPU Leases):** Treat host GPUs as a requestable pool rather than static assignments. The orchestrator dynamically hot-plugs PCIe devices (`nvidia.runtime`) into offline containers just before boot, and releases them back to the hardware pool when the container spins down or goes idle.
- **[ ] Implement Gateway Authentication:** Secure the Caddy `@ai` reverse proxy route to prevent unauthorized inference requests from the broader Home Network. (Currently deferred; endpoint is openly routing to `10.10.10.50:8080`). Please note that we will hold off on this right now.
- **[ ] GPU Thermal Management:** Implement a cron/systemd service on the _host_ to monitor `nvidia-smi -q -d TEMPERATURE` and alert on thermal throttling, ensuring the high-RPM ASUS chassis fans are mitigating sustained inference loads. _(Deprioritized: Hardware is currently stable; will implement as final polish)._
- **[ ] SGLang Engine Support:** We maintain base declarative profiles (`sglang.yaml`) and `cloud-init` configurations for SGLang. _(Deprioritized: Currently shelved due to Ampere FP8 instruction limitations, but infrastructure remains ready if future models/updates require it)._
- **[ ] Formalize Local DNS (Split-Horizon):** Configure a local DNS record in the EFG router mapping `api.ionsignal.com` to the DMZ host IP `172.20.2.115`. _(Deprioritized: Currently using `/etc/hosts` overrides on the client laptop. Implement later to ensure universal LAN access and bypass Hairpin NAT overhead at the network edge)._
