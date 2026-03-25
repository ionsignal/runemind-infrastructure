# Nerrus Infrastructure Roadmap

**Mission:** Architect and maintain a high-performance, hybrid-workload edge server balancing a ~35B parameter MoE LLM (AI Inference) and real-time Minecraft game servers (LXD) within a strict Zero-Trust DMZ environment. All workloads, including the AI engine, operate strictly within LXD containers to ensure absolute host isolation.

### Environment & Hardware Baseline

- **Hostname:** `is-compute-01`
- **Hardware:** ASUS ESC4000 G3 (High-RPM cooling).
- **Compute:** 4x NVIDIA RTX A4000 GPUs (64GB VRAM total).
- **Network Zone:** DMZ (VLAN 2) | Subnet: `172.20.2.0/24` | Gateway: `172.20.2.1` (EFG).
- **Host IP:** `172.20.2.115` (Static via `bond0` Active-Backup).
- **Storage Layout:**
  - _OS Drive:_ 250GB NVMe (`/dev/nvme0n1`, Ubuntu 24.04 LTS, ext4, No LVM).
  - _AI Vault:_ 2TB NVMe (`/dev/nvme1n1`, ZFS Pool `is-nvme-pool`, dedicated to LXD).
  - _Game Tier:_ 4x 500GB SATA HDDs/SSDs (ZFS Pool configured for LXD Custom Storage Volumes).

### Architectural Constraints

- **Zero-Trust DMZ:** The host cannot initiate outbound connections to Internal (`192.168.x.x`, `10.x.x.x` external) or Home (`172.20.3.0/24`) networks.
- **Defense-in-Depth Containerization:** No workloads run directly on the bare-metal host OS. Both the AI Inference Engine and Game Servers operate inside heavily restricted LXD containers.
- **Micro-CA SSL:** Wildcard certificates (`*.ionsignal.com`) are generated securely via Caddy using the `acme-dns` plugin hosted on an isolated AWS ARM64 instance.

---

## Phase 1: Bare Metal Foundation & Hardening [COMPLETED]

_Objective: Establish a secure host environment, enforce network boundaries, integrate the Micro-CA, and provision raw storage._

- **[✓] Base OS & UEFI Clean-Up:** Secure Boot disabled. Ubuntu 24.04 LTS installed cleanly on the 250GB NVMe.
- **[✓] Host Hardening & Defense-in-Depth:** Root login and password authentication disabled. UFW configured with strict outbound fencing and restricted inbound access.
- **[✓] Static Network Configuration:** `bond0` configured in Active-Backup mode for high availability and ARP stability.
- **[✓] Zero-Trust Micro-CA Integration:** Caddy compiled natively with `acme-dns`, stripped of root privileges (`CAP_NET_BIND_SERVICE`), and configured to terminate wildcard SSL.
- **[✓] LXD Minimal Initialization:** LXD 6.x LTS installed, bound strictly to `127.0.0.1:8443`, and proxied securely through Caddy using an mTLS client-certificate bridge and BasicAuth.
- **[✓] High-Performance Storage Provisioning:** ZFS `is-nvme-pool` successfully created with `ashift=12`, `compression=lz4`, and `atime=off`. ZFS ARC clamped to 4GB to prevent host OOM conditions.

---

## Phase 2: AI Infrastructure Containerization (Current Phase)

_Objective: Deploy the Qwen ~35B MoE LLM securely within an LXD container, utilizing GPU passthrough to maintain bare-metal PCIe efficiency. (Note: Shifted from SGLang to vLLM to bypass Ampere FP8 hardware limitations via the Marlin kernel)._

- **[✓] NVIDIA Host Stack:** Installed headless proprietary v580 drivers and the NVIDIA Container Toolkit natively on the host OS to initialize the PCIe devices.
- **[✓] Decoupled AI Storage Vault:** Provisioned a 100GB custom storage volume (`is-model-vault`). Redirected HuggingFace/vLLM caches directly to this vault, decoupling massive model weights from the ephemeral container OS.
- **[✓] Containerized Engine Deployment (Declarative IaC):**
  - Provisioned a dedicated LXD container (`vllm`) via YAML profiles with a static IP (`10.10.10.50`).
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

## Phase 3: LXD Containerization & Configuration Management

_Objective: Deploy a highly reproducible, stateless PaperMC base image and implement a GitOps-style "Configuration Drift Management" system. This phase eliminates environment variable limitations and establishes Postgres as the absolute source of truth for all container states._

- **Network Fencing & Security:** Ensure the `lxdbr0` bridge routes correctly through `bond0` for NAT. Enforce hypervisor-level IP/MAC spoofing protection (`security.ipv4_filtering=true`). Host UFW drops internal scanning while allowing local access to the AI container (`10.10.10.50`).
- **Container Architecture:**
  - Container 1: Velocity Proxy (Static IP on `lxdbr0`).
  - Containers 2-N: PaperMC backend servers (Ephemeral, mounting Custom Storage Volumes).

### **3.1. The "Dumb" Base Image (Distrobuilder)**

To maintain an immutable "Edge PaaS" architecture, we abandon manual container snapshots and `cloud-init` scripts. Instead, we use **Distrobuilder** to compile a pristine, declarative `minecraft-base` image from scratch.

- **Declarative YAML:** The image is defined in a single Distrobuilder YAML file containing the Ubuntu 24.04 rootfs, OpenJDK 21, the PaperMC `.jar`, and an unprivileged `minecraft` service user.
- **Zero-Logic Entrypoint:** The container contains **no bash scripts** to parse environment variables. The `systemd` service executes Java directly, natively loading dynamic JVM arguments via an `EnvironmentFile=-/etc/ion/jvm.env` pushed by Fastify before boot. Standard configurations (e.g., `server.properties`) are injected directly to disk, completely bypassing command-line parsing.- **Result:** The image is cryptographically verifiable, boots in milliseconds, and leaves zero artifact history (like bash logs or old SSH keys).

### **3.2. The LXD File API (Data-Plane Push Model)**

Instead of passing complex configurations and secrets via environment variables (which are insecure, leak easily into crash logs, and lack type safety), Fastify injects configuration files directly into the container's disk _before_ it boots. This establishes a "Data-Plane Push Model" utilizing the LXD File API over our mTLS bridge.

#### **3.2.1. Client Transport Refactoring (Modularization)**

As the LXD API integration grows, the monolithic `client.ts` file has become a bottleneck. To maintain a clean architecture, the LXD client is broken apart into a dedicated `./client` namespace:

- **`./client/index.ts`**: The core `LxdClient` class that initializes the `undici` agent, manages the WebSocket event stream, and aggregates the sub-modules.
- **`./client/instances.ts`**: Handles standard JSON-enveloped requests for power states, creation, and deletion.
- **`./client/files.ts`**: A dedicated `LxdFileClient` that strictly maps to RESTful HTTP verbs (`get`, `post`, `delete`). Crucially, this module bypasses standard JSON parsing for `get` requests, as the LXD File API returns raw byte buffers (e.g., binary `.jar` files or raw `.yaml` text).

#### **3.2.2. Hybrid Identity & Secrets Delivery**

We utilize a strict separation of concerns for container initialization:

- **Immutable Identity (LXD Env Vars):** The container's core identity (e.g., `ION_TENANT_ID`) is injected via LXD configuration environment variables. This is immutable from inside the container and allows the Java engine to instantly discover its routing prefix via `System.getenv()`.
- **Cryptographic Secrets (LXD File API):** Highly sensitive data, such as scoped NATS tokens (`nats.cred`), are pushed directly to the disk via the File API. This keeps secrets entirely out of the process environment space.

#### **3.2.3. Unprivileged Execution & Permissions**

When pushing files via the `post` method, the transport layer explicitly injects `X-LXD-*` headers. Files are written with strict permissions (e.g., `X-LXD-mode: 0600`, `X-LXD-uid: 1000`, `X-LXD-gid: 1000`) ensuring they are owned exclusively by the unprivileged `minecraft` service user defined in our Distrobuilder base image.

### **3.3. Two-Tiered Filesystem Architecture**

To securely manage container files from the Fastify backend, the `@ionsignal/ionhost` package implements a two-tiered service approach, separating raw disk access from structured configuration logic.

#### **3.3.1. Tier 1: General `FileService` (Raw Disk Access & Boundary)**

This tier acts as a secure, RESTful proxy to the `LxdFileClient` (`get`, `post`, `delete`) and enforces strict access boundaries.

- **Chroot Jail & Sanitization:** Implements `path.posix.normalize` to resolve user-provided paths against a hardcoded container root (e.g., `/opt/minecraft`). This strictly prevents directory traversal attacks (e.g., `../../../../etc/shadow`) before the request ever reaches the LXD hypervisor.
- **Ownership Verification:** Validates against Postgres that the requesting user actually owns the target LXD instance before executing any I/O.
- **UI Integration:** Powers the web-based File Explorer in the Vue UI, allowing admins to stream logs, upload plugins, or delete crash reports without touching the database.

#### **3.3.2. Tier 2: `ManagedConfigEngine` (State Management & Zod)**

A specialized domain layer that sits on top of the `FileService` to handle critical, database-tracked files (e.g., `server.properties`, `paper.yml`).

- **Postgres as the Source of Truth:** Managed configurations are stored in a `managed_files` database table as structured `JSONB`, alongside a `SHA-256` hash of the compiled file.
- **AST Compilation & Zod Reflection:** When pushing a config, this engine utilizes an Abstract Syntax Tree (AST) parser to convert the Postgres `JSONB` into valid `.properties` or `.yaml` formats. During compilation, it dynamically extracts `.describe()` metadata from the shared Zod schemas and injects them as physical `# comments` into the resulting file.
- **Drift Detection:** By comparing the live file's hash (fetched via `FileService.get`) against the database hash, the system can instantly alert the Vue UI if a user has manually altered a file inside the container via SSH, allowing for immediate reconciliation.

#### 3.3.1 **Separation of Concerns:**

    - `InstanceService` = Power state (Start/Stop).
    - `FileService` = Disk state (Read/Write/Upload).
    - `ConfigEngine` = Logic state (Zod/AST/Postgres Drift).

### **3.4. Configuration Drift Management & Zod Reflection**

This system ensures that manual changes made inside a container (e.g., via SSH) are instantly detected and can be reconciled with the web UI.

- **Postgres as Source of Truth:** Managed files are tracked in a `managed_files` database table, storing the structured data (`JSONB`) and a cryptographic hash (`SHA-256`) of the compiled file.
- **"Zod as Documentation":** Shared Zod schemas define the configuration structure and utilize `.describe()` to store human-readable documentation (e.g., `z.boolean().describe("Allows Nether travel")`).
- **AST Compilation:** When Fastify pushes a config to LXD, it uses an Abstract Syntax Tree (AST) parser to convert the JSONB into `.properties` or `.yaml`. During this process, it dynamically injects the Zod `.describe()` strings as physical `# comments` into the file.
- **The Audit Loop (Drift Detection):**
  1. Fastify pulls the live file from the LXD container via the `FileService`.
  2. It hashes the live file and compares it against the `SHA-256` hash stored in Postgres.
  3. If a mismatch occurs, the Vue UI displays a "Drift Detected" warning, allowing the admin to either **Overwrite the Container** (push DB state) or **Import to DB** (parse the live file into JSONB and update Postgres).

### **3.5. Dynamic UI Generation**

Because the Vue 3 frontend and the Fastify backend share the exact same Zod schemas, the frontend requires almost zero hardcoded forms.

- A recursive `<SchemaRenderer>` Vue component iterates over the Zod object.

---

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
