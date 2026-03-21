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
- **[ ] Execution Strategy 1: Finalize Attention Backend (Next Step):** Conclude the manual benchmark comparing `FLASHINFER` vs `FLASH_ATTN` to lock in the absolute highest decode Tokens-Per-Second.
- **[ ] Execution Strategy 2: Systemd Persistence:** Translate the optimized launch command and environment variables (e.g., `VLLM_ATTENTION_BACKEND`, `NCCL_DEBUG`) into a robust `systemd` service (`/etc/systemd/system/vllm.service`) inside the container. Ensure it runs under the unprivileged `vllm` user, sources the `uv` virtual environment, and auto-restarts on failure.

---

## Phase 3: LXD & Minecraft Decoupled State

_Objective: Establish a highly dynamic, ephemeral containerization layer for game servers using ZFS Copy-on-Write._

- **Decoupled State Architecture:** Treat Minecraft containers as ephemeral compute. Leverage ZFS Copy-on-Write to spin up base Ubuntu/PaperMC server images instantly. Persistent state (Worlds, Plugins) is decoupled into LXD Custom Storage Volumes on the SATA tier.
- **Network Fencing & Security:** Ensure the `lxdbr0` bridge routes correctly through `bond0` for NAT. Enforce hypervisor-level IP/MAC spoofing protection (`security.ipv4_filtering=true`). Host UFW drops internal scanning while allowing local access to the AI container (`10.10.10.50`).
- **Container Architecture:**
  - Container 1: Velocity Proxy (Static IP on `lxdbr0`).
  - Containers 2-N: PaperMC backend servers (Ephemeral, mounting Custom Storage Volumes).

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
