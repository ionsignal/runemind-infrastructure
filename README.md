# System Infrastructure Guide

## Base OS Installation & UEFI Initialization

### **1. UEFI & NVRAM Baseline**

- **Boot Mode:** UEFI Only (Disable Legacy/CSM).
- **Secure Boot:** Disabled (Required for NVIDIA driver/CUDA compilation).
- **NVRAM Cleanup:** `sudo efibootmgr` -> delete stale entries (e.g., `sudo efibootmgr -b XXXX -B`).
- **OS Target:** Ubuntu 24.04 LTS on 250GB NVMe (`ext4`, **No LVM**).

### **2. Static Network Configuration (Netplan)**

To prevent ARP flux on the DMZ switch and provide a highly available, stable default gateway for the LXD containers, the dual 1GbE interfaces are bonded using Active-Backup (Mode 1). This ensures zero-downtime failover without requiring 802.3ad (LACP) configuration on the upstream EFG.

**1. Define the Bond Configuration**

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

Replace the default DHCP configuration with the static bond assignment:

```yaml
# /etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    enp7s0:
      dhcp4: false
    enp8s0:
      dhcp4: false
  bonds:
    bond0:
      interfaces:
        - enp7s0
        - enp8s0
      addresses:
        - 172.20.2.115/24
      routes:
        - to: default
          via: 172.20.2.1
      nameservers:
        addresses:
          - 172.20.2.1
          - 1.1.1.1
      parameters:
        mode: active-backup
        primary: enp8s0
        mii-monitor-interval: 100
```

**2. Safely Apply and Verify**

Apply the configuration using `try` to prevent lockouts during the interface transition.

```bash
# Update the plan, check if SSH is stable
sudo netplan try

# Verify the IP is now exclusively bound to bond0
ip -br a

# Verify the kernel bonding module status
cat /proc/net/bonding/bond0
```

### **3. SSH Access Control**

Enforce key-based authentication only.

```conf
# /etc/ssh/sshd_config.d/10-is-compute-hardening.conf
# Disable Root Login
PermitRootLogin no

# Enforce Key-Based Authentication Only
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes

# Restrict SSH access to specific users
AllowUsers oliver
```

```bash
sudo systemctl restart ssh
```

### **4. Zero-Trust Firewall (UFW)**

Implement strict inbound routing and outbound fencing to prevent lateral movement from the DMZ.

Run the following rules as a script to achieve the baseline state:

```bash
# This ensures we don't have lingering, conflicting rules.
sudo ufw --force reset

# 2. SET DEFAULT POLICIES
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

# ==========================================
# 3. HOST OUTBOUND (The OUTPUT Chain)
# ==========================================

# Priority Allows: Written first so they naturally become Rule 1 and Rule 2
sudo ufw allow out to 10.10.10.0/24 comment 'Priority: Allow Host to LXD subnet'
sudo ufw allow out to 172.20.2.0/24 comment 'Priority: Allow local DMZ subnet & Gateway'

# Block host from reaching any other internal networks (Zero-Trust)
sudo ufw deny out to 172.16.0.0/12 comment 'Block outbound to Internal 172.x'
sudo ufw deny out to 10.0.0.0/8 comment 'Block outbound to Internal 10.x'
sudo ufw deny out to 192.168.0.0/16 comment 'Block outbound to Internal 192.168.x'

# ==========================================
# 4. HOST INBOUND (The INPUT Chain)
# ==========================================

# SSH (Port 22) - Management, AWS Bastion, and Home Laptop
sudo ufw allow from 172.20.1.0/24 to any port 22 proto tcp comment 'Allow SSH Management'
sudo ufw allow from 13.52.160.148 to any port 22 proto tcp comment 'Allow SSH AWS Bastion'
sudo ufw allow from 172.20.3.158 to any port 22 proto tcp comment 'Allow SSH Home Laptop'

# HTTPS (Port 443) - Caddy / LXD UI Access
sudo ufw allow from 172.20.1.0/24 to any port 443 proto tcp comment 'Allow HTTPS Management'
sudo ufw allow from 172.20.3.0/24 to any port 443 proto tcp comment 'Allow HTTPS Home'

# Explicitly allow DHCP (UDP 67) from containers to the host
sudo ufw allow in on lxdbr0 to any port 67 proto udp comment 'LXD DHCP'

# Explicitly allow DNS (TCP/UDP 53) from containers to the host
sudo ufw allow in on lxdbr0 to any port 53 proto udp comment 'LXD DNS UDP'
sudo ufw allow in on lxdbr0 to any port 53 proto tcp comment 'LXD DNS TCP'

# Game Ingress (LXD Proxy Device Architecture)
sudo ufw allow in on bond0 to any port 25565 proto tcp comment 'Allow Inbound Velocity Proxy'

# ==========================================
# 5. ROUTED TRAFFIC (The FORWARD Chain)
# ==========================================

# Fencing: Prevent compromised containers from scanning internal networks
sudo ufw route deny in on lxdbr0 out on bond0 to 172.16.0.0/12 comment 'Block LXD outbound to Internal 172.x'
sudo ufw route deny in on lxdbr0 out on bond0 to 10.0.0.0/8 comment 'Block LXD outbound to Internal 10.x'
sudo ufw route deny in on lxdbr0 out on bond0 to 192.168.0.0/16 comment 'Block LXD outbound to Internal 192.168.x'

# Internet Access: Allow containers to reach the public internet
sudo ufw route allow in on lxdbr0 out on bond0 comment 'Allow LXD Outbound Internet'

# ==========================================
# 6. ENABLE AND APPLY
# ==========================================
sudo ufw enable
sudo ufw reload
sudo ufw status numbered
```

### **5. High-Performance ZFS Storage Provisioning (NVMe)**

Provision the drives as a unified, high-performance ZFS storage pool dedicated entirely to LXD. This allows LXD to manage ephemeral containers, persistent decoupled states (Custom Volumes), and a strictly isolated, GPU-passthrough.

#### **Step 5.1: Identify the Target Drive**

Before executing any destructive commands, you must positively identify the device path of the 2TB NVMe drive to ensure you do not accidentally overwrite the 250GB OS drive.

```bash
# List all block devices, focusing on NVMe drives and their physical models
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,MODEL | grep nvme

# Verify the exact size and sector count of the NVMe drives
sudo fdisk -l | grep -E "^Disk /dev/nvme"
```

_Look at the output and identify the relevent drives (e.g., `WD Green SN350 2TB`). Note its device identifier (usually `/dev/nvme1n1`). The following steps assume `/dev/nvme1n1` so adjust accordingly._

#### **Step 5.2: Obliterate Ghost Partitions and Data**

If the 2TB NVMe was previously used (e.g., contains old ZFS member labels or GPT headers), the kernel or ZFS daemon may reject new pool creation. We must completely sanitize the drive's partition tables and filesystem signatures.

```bash
# Ensure the drive is unmounted (fails safely if not mounted)
sudo umount /dev/nvme1n1* 2>/dev/null

# Wipe all filesystem signatures on the drive AND its partitions
sudo wipefs -a /dev/nvme1n1*

# Destroy the GPT/MBR partition tables completely
sudo sgdisk --zap-all /dev/nvme1n1

# Inform the kernel of the hardware changes
sudo partprobe /dev/nvme1n1
```

#### **Step 5.3: Create the Optimized ZFS Pool (`is-nvme-pool`)**

We create the ZFS pool manually on the host OS first rather than letting LXD do it. This allows us to strictly enforce NVMe-specific performance flags.

- `ashift=12`: Aligns the pool to 4K/8K NVMe sectors (prevents massive write amplification).
- `compression=lz4`: Virtually zero CPU overhead, massive read speed boost for model weights.
- `xattr=sa`: Stores extended attributes directly in the inode. Crucial for LXD because unprivileged containers heavily rely on POSIX ACLs for UID/GID shifting.
- `atime=off`: Completely disables access-time tracking, reducing write-amplification and speeding up Minecraft chunk loading and AI model reads.
- `-m none`: Prevents the host OS from mounting the pool, reserving it entirely for LXD.

```bash
# Install the ZFS management tools
sudo apt update
sudo apt install -y zfsutils-linux

# Load the ZFS kernel module
sudo modprobe zfs

# Create the optimized master pool
sudo zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O atime=off \
    -m none \
    is-nvme-pool /dev/nvme1n1

# Verify the pool is healthy and online
sudo zpool status is-nvme-pool
```

#### **Step 5.4: Hand the Pool to LXD**

Now that the pool is perfectly tuned for our hardware, we instruct LXD to take full ownership of it. LXD will register it in its database and automatically configure the necessary internal datasets for containers and custom volumes.

```bash
# Tell LXD to consume the existing 'is-nvme-pool' ZFS pool
lxc storage create is-nvme-pool zfs source=is-nvme-pool

# Verify LXD sees the new storage pool
lxc storage list
```

#### **Step 5.5: Clamp the ZFS ARC (Memory Protection)**

By default, ZFS will consume up to 50% of the host's system RAM for its read cache (ARC). To ensure the Minecraft Java Heaps and the AI Inference engine (vLLM) never experience Out-Of-Memory (OOM) kills, we must strictly clamp the ARC size to 4GB.

```bash
# Apply the 4GB limit dynamically (Takes effect immediately without reboot)
echo 4294967296 | sudo tee /sys/module/zfs/parameters/zfs_arc_max

# Make the limit persistent across reboots
echo "options zfs zfs_arc_max=4294967296" | sudo tee /etc/modprobe.d/zfs-arc.conf

# Update the boot environment to include the new parameter
sudo update-initramfs -u
```

## Compiling and Hardening Caddy

To maintain Zero-Trust principles within the DMZ, Caddy is compiled natively to include only the necessary DNS delegation module (`acme-dns`) and is explicitly stripped of root privileges using Linux capabilities.

### **1. Install Build Toolchain (xcaddy)**

Install the Go compiler, capability tools, and the official `xcaddy` build utility.

```bash
# Install Go and libcap2-bin (for setcap)
sudo apt update
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https golang libcap2-bin

# Add the cryptographically signed Cloudsmith repository for xcaddy
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-xcaddy.list

# Install xcaddy
sudo apt update
sudo apt install -y xcaddy
```

### **2. Compile Custom Binary**

Compile a statically linked Caddy binary containing the `acmedns` module and move it to the system path.

```bash
# Build Caddy with the acme-dns module
xcaddy build --with github.com/caddy-dns/acmedns

# Move to standard local bin path
sudo mv caddy /usr/local/bin/caddy
```

### **3. Enforce Principle of Least Privilege**

Create an isolated, shell-less service account for Caddy. The binary is owned by root (to prevent self-modification) but granted kernel capabilities to bind to privileged web ports (80/443) as an unprivileged user.

```bash
# Create a dedicated system group and user (No bash shell allowed)
sudo groupadd --system caddy
sudo useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy

# Set binary ownership to root to prevent malicious overwrites
sudo chown root:root /usr/local/bin/caddy
sudo chmod 755 /usr/local/bin/caddy
```

### **4. Secure API Credentials**

Create the configuration directory and provision the isolated AWS Route53 delegation credentials.

```bash
sudo mkdir -p /etc/caddy
sudo vim /etc/caddy/acmedns.json
```

Add your specific UUID credentials generated from the AWS `acme-dns` server (created later:)

```json
{
  "ionsignal.com": {
    "username": "your-uuid-string",
    "password": "your-secure-password",
    "fulldomain": "your-uuid-string.auth.ionsignal.com",
    "subdomain": "your-uuid-string",
    "server_url": "https://auth.ionsignal.com"
  }
}
```

Lock down the credentials file so it is exclusively readable by the `caddy` service account, preventing access from standard users or LXD containers.

```bash
# Restrict ownership and permissions (Read/Write for caddy user ONLY)
sudo chown caddy:caddy /etc/caddy/acmedns.json
sudo chmod 600 /etc/caddy/acmedns.json
```

### **5. Edge Routing & SSL Configuration (Caddyfile)**

Define the reverse proxy rules and instruct Caddy to use the `acme-dns` credentials for zero-downtime, automated wildcard certificate renewals.

```bash
sudo vim /etc/caddy/Caddyfile
```

Add the following configuration, adjusting the reverse proxy ports to match your specific vLLM/SGLANG and LXD setups:

```conf
# /etc/caddy/Caddyfile

# Global configuration
{
    email admin@ionsignal.com
    # UNCOMMENT DURING INITIAL TESTING TO AVOID LETS ENCRYPT RATE LIMITS
    # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

# Generate Wildcard Certificate via ACME-DNS Delegation
*.ionsignal.com {
    tls {
        dns acmedns /etc/caddy/acmedns.json
    }
    # Security Headers for the DMZ
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
    }
    # Route AI API Traffic (sglang)
    @ai host api.ionsignal.com
    handle @ai {
        reverse_proxy 127.0.0.1:8080 {
            # Disable buffering for zero-latency LLM token streaming (SSE)
            flush_interval -1
        }
    }
    # Route LXD UI Traffic
    @lxd host lxd.ionsignal.com
    handle @lxd {
        reverse_proxy 127.0.0.1:8443 {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
    # Fallback: Drop any requests to unconfigured subdomains
    handle {
        respond "404 Not Found - Unauthorized Subdomain" 404
    }
}
```

Set the correct ownership and permissions for the configuration file:

```bash
sudo chown caddy:caddy /etc/caddy/Caddyfile
sudo chmod 644 /etc/caddy/Caddyfile
```

### **6. Systemd Service Integration**

Create a systemd unit file to manage the Caddy process. This configuration enforces the unprivileged `caddy` user while explicitly passing the network binding capabilities through systemd's security boundary.

```bash
sudo nano /etc/systemd/system/caddy.service
```

```ini
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
# Crucial: Allows the non-root user to bind to ports 80/443
AmbientCapabilities=CAP_NET_BIND_SERVICE
# Grants write access to the isolated home directory for SSL cert storage
ReadWritePaths=/var/lib/caddy

[Install]
WantedBy=multi-user.target
```

Reload the systemd daemon, enable the service to start on boot, and start it immediately:

```bash
sudo systemctl daemon-reload
sudo systemctl enable caddy
sudo systemctl start caddy
sudo systemctl status caddy

```

## Micro-CA [acme-dns] Deployment on AWS (ARM64)

### **AWS Security Group (Firewall) Prep**

Log into your AWS Console and update the Security Group attached to your ARM64 instance. `acme-dns` needs to act as a public DNS server and expose a secure API.

- **Allow Inbound Port 53 (TCP & UDP)** from `0.0.0.0/0` (For Let's Encrypt to query the challenges).
- **Allow Inbound Port 80 & 443 (TCP)** from `0.0.0.0/0` (For the `acme-dns` API and its own SSL generation).
- **Allow Inbound Port 22 (TCP)** from your specific IP (For your SSH access).

### **Route 53 Base DNS Records**

Before installing the software, we must tell the internet that your AWS instance is an authoritative name server. Go to AWS Route 53 and create these two records:

1.  **A Record:**
    - **Name:** `acme-dns.ionsignal.com`
    - **Value:** `[aws-elastic-ip]`
    - **TTL:** 300 (simple policy)
2.  **NS (Name Server) Record:**
    - **Name:** `auth.ionsignal.com`
    - **Value:** `acme-dns.ionsignal.com`
    - **TTL:** 300 (simple policy)

### Install [acme-dns] on Micro-CA

To securely delegate Let's Encrypt DNS challenges, we must install the `acme-dns` service on the isolated AWS ARM64 instance. This avoids storing highly privileged AWS Route 53 IAM credentials on the on-premise DMZ host.

#### **1. Download and Build the Release**

```bash
# 1. Install required build tools
sudo apt update
sudo apt install -y golang git

# 2. Clone the repository and enter the directory
git clone https://github.com/acme-dns/acme-dns.git
cd acme-dns

# 3. Checkout the specific stable release tag
git checkout v2.0.2

# 4. Compile the binary natively for ARM64
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
go build -p 1 # slow
```

**NOTE:** Building this on a t4g.nano requires the swap and special flags for go build

#### **2. Install the Binary**

Move the executable to the system path and delete the downloaded archive to maintain a clean environment.

```bash
# 5. Provision configuration and database directories
sudo mkdir -p /etc/acme-dns
sudo mkdir -p /var/lib/acme-dns

# 6. Create the isolated service account
sudo adduser --system --group --no-create-home --home /var/lib/acme-dns --shell /usr/sbin/nologin acme-dns
sudo chown -R acme-dns:acme-dns /var/lib/acme-dns

# 7. Move the compiled binary to the system path
sudo mv acme-dns /usr/local/bin/acme-dns

# 8. Turn off and delete the swap file
sudo swapoff /swapfile
sudo rm /swapfile
```

#### **3. Copy the Default Config & Systemd Service**

Copy the default configuration template and systemd unit file directly from the cloned source code, then clean up the build environment.

```bash
# 8. Copy the config and systemd files directly from the v2.0.2 source code
sudo cp config.cfg /etc/acme-dns/config.cfg
sudo cp acme-dns.service /etc/systemd/system/acme-dns.service

# 9. Clean up the source code directory
cd ~
rm -rf acme-dns

# 10. Reload systemd to recognize the new service
sudo systemctl enable --now acme-dns
sudo systemctl daemon-reload
```

#### **4. Update Default Config**

Ensure you have updated /etc/acme-dns/config.cfg with your specific domain details:

```ini
[general]
# DNS interface. Note that systemd-resolved may reserve port 53 on 127.0.0.53
# In this case acme-dns will error out and you will need to define the listening interface
# for example: listen = "127.0.0.1:53"
listen = "172.30.12.208:53"
# protocol, "both", "both4", "both6", "udp", "udp4", "udp6" or "tcp", "tcp4", "tcp6"
protocol = "both"
# domain name to serve the requests off of
domain = "auth.ionsignal.com"
# zone name server
nsname = "acme-dns.ionsignal.com"
# admin email address, where @ is substituted with .
nsadmin = "admin.ionsignal.com"
# predefined records served in addition to the TXT
records = [
    # domain pointing to the public IP of your acme-dns server
    "auth.ionsignal.com. A 13.52.20.237",
    # specify that auth.example.org will resolve any *.auth.example.org records
    "auth.ionsignal.com. NS acme-dns.ionsignal.com.",
]
# debug messages from CORS etc
debug = false

[database]
# Database engine to use, sqlite or postgres
engine = "sqlite"
# Connection string, filename for sqlite3 and postgres://$username:$password@$host/$db_name for postgres
# Please note that the default Docker image uses path /var/lib/acme-dns/acme-dns.db for sqlite3
connection = "acme-dns.db"
# connection = "postgres://user:password@localhost/acmedns_db"

[api]
# listen ip eg. 127.0.0.1
ip = "172.30.12.208"
# disable registration endpoint
disable_registration = false
# listen port, eg. 443 for default HTTPS
port = "443"
# possible values: "letsencrypt", "letsencryptstaging", "cert", "none"
tls = "letsencrypt"
# only used if tls = "cert"
# tls_cert_privkey = "/etc/tls/example.org/privkey.pem"
# tls_cert_fullchain = "/etc/tls/example.org/fullchain.pem"
# only used if tls = "letsencrypt"
acme_cache_dir = "api-certs"
# optional e-mail address to which Let's Encrypt will send expiration notices for the API's cert
notification_email = ""
# CORS AllowOrigins, wildcards can be used
corsorigins = [
    "*"
]
# use HTTP header to get the client ip
use_header = false
# header name to pull the ip address / list of ip addresses from
header_name = "X-Forwarded-For"

[logconfig]
# logging level: "error", "warning", "info" or "debug"
loglevel = "info"
# possible values: stdout, file
logtype = "stdout"
# file path for logfile
logfile = "./acme-dns.log"
# format, either "json" or "text"
logformat = "json"
```

**NOTE:** Ensure to update the config with the _actual_ static private IP on the AWS interface assigned to [micro-ca].

#### **5. Generate the Payload**

Generate the token for your DMZ host

```bash
curl -X POST https://auth.ionsignal.com/register
```

The `curl` output must be manually wrapped in the "ionsignal.com": {} block before saving it to /etc/caddy/acmedns.json.

```json
{
  "ionsignal.com": {
    "username": "[UUID]",
    "password": "[SECRET]",
    "fulldomain": "[UUID].auth.ionsignal.com",
    "subdomain": "[UUID]",
    "server_url": "https://auth.ionsignal.com"
  }
}
```

Once you run the curl command and get your JSON payload, edit /etc/acme-dns/config.cfg:

```ini
disable_registration = true
```

```bash
sudo systemctl restart acme-dns
```

Then go into the caddy acme-dns config file and update it using your registration from acme-dns.

#### 6. Route 53 CNAME for `ionsignal.com`

Go to your AWS Route 53 Console, open the Hosted Zone for **`ionsignal.com`**, and create this record:

- **Record Name:** `_acme-challenge.ionsignal.com`
- **Record Type:** `CNAME`
- **Value:** `[uuid].auth.ionsignal.com` _(Paste your exact `fulldomain` string here)._

## LXD Installation & Zero-Trust UI Proxy

_Objective: Deploy the LXD 6.x LTS container hypervisor. To maintain strict Zero-Trust boundaries, LXD is bound exclusively to `localhost`. Caddy acts as an authenticated mTLS bridge, terminating the wildcard SSL and protecting the Web UI with Basic Authentication._

### **1. Enforce LXD 6.x LTS Track**

Ubuntu 24.04 defaults to the 5.21 track. We must force the upgrade to the modern 6.x LTS track to ensure long-term support and access to the modern mTLS UI.

```bash
# Verify current version
lxd --version

# Refresh snap to the 6.x LTS stable channel
sudo snap refresh lxd --channel=6/stable

# Verify upgrade success
lxd --version
```

### **2. Host Network Preparation**

LXD containers (like the Minecraft servers) rely on the host's IP for outbound NAT. IP forwarding must be permanently enabled at the kernel level before LXD builds its bridge.

```bash
# Enable IPv4 forwarding permanently
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# Apply the change immediately
sudo sysctl -p
```

### **3. Minimal Initialization (Deferred Storage)**

To isolate variables and test the network proxy, we initialize LXD using a minimal `dir` (directory) backend. The raw SATA SSDs (ZFS pool) will be attached later in Phase 3.

Run the initialization wizard:

```bash
sudo lxd init
```

Provide the following exact answers to bind LXD securely to localhost and disable IPv6:

- **Would you like to use LXD clustering?** `no`
- **Do you want to configure a new storage pool?** `yes`
- **Name of the new storage pool:** `default`
- **Name of the storage backend to use:** `dir` _(Uses a simple folder on the OS drive)_
- **Would you like to connect to a MAAS server?** `no`
- **Would you like to create a new local network bridge?** `yes`
- **What should the new bridge be called?** `lxdbr0`
- **What IPv4 address should be used?** `auto`
- **What IPv6 address should be used?** `none` _(Crucial: Disables IPv6 in the DMZ)_
- **Would you like the LXD server to be available over the network?** `yes`
- **Address to bind LXD to (not including port):** `127.0.0.1` _(Forces local-only access)_
- **Port to bind LXD to:** `8443`
- **Trust password for new clients:** `[Enter a secure password]`
- **Would you like stale cached images to be updated automatically?** `yes`
- **Would you like a YAML "lxd init" preseed to be printed?** `no`

### **4. Lock the Internal Network Subnet (Velocity Prerequisite)**

By default, LXD generates a random IPv4 subnet for the `lxdbr0` bridge. To support host-level UFW port forwarding and strict Velocity proxy routing (which requires hardcoded backend IPs), must lock the bridge to a static, predictable CIDR block (`10.10.10.1/24`). We also explicitly disable IPv6 to prevent routing leaks in the DMZ.

```bash
# Lock the bridge IP and define the container CIDR block
lxc network set lxdbr0 ipv4.address 10.10.10.1/24

# Restrict the DHCP pool to leave .2 through .99 available for Static IPs (Velocity, AI)
lxc network set lxdbr0 ipv4.dhcp.ranges 10.10.10.100-10.10.10.200

# Explicitly disable IPv6 on the bridge
lxc network set lxdbr0 ipv6.address none
lxc network set lxdbr0 ipv6.nat false

# Verify the network is locked down
lxc network show lxdbr0
```

### **5. The Proxy Authentication Bridge (mTLS)**

LXD 6.x requires either SSO (OIDC) or a Client Certificate (mTLS) for UI access. Because Caddy (a Layer 7 proxy) cannot pass a browser's client certificate through to the backend, we must give Caddy its own master certificate to authenticate to LXD automatically, and then protect Caddy's front-door with a password.

**A. Generate Caddy's Client Certificate**

```bash
# Create a secure directory for the keys
sudo mkdir -p /etc/caddy/lxd-certs
cd /etc/caddy/lxd-certs

# Generate a 10-year client certificate for the Caddy daemon
sudo openssl req -x509 -newkey rsa:4096 -nodes -keyout caddy.key -out caddy.crt -days 3650 -subj "/CN=caddy-proxy"

# Lock down permissions so ONLY the 'caddy' user can read the private key
sudo chown caddy:caddy caddy.key caddy.crt
sudo chmod 600 caddy.key
```

**B. Inject Certificate into LXD Trust Store**

```bash
# Tell LXD to permanently trust Caddy's new certificate
lxc config trust add /etc/caddy/lxd-certs/caddy.crt --name caddy-proxy

# Verify it was added successfully
lxc config trust list
```

**C. Generate BasicAuth Password for the Web UI**
Generate a `bcrypt` hashed password. This will be the password you type into the browser prompt to access the LXD dashboard.

```bash
caddy hash-password
# Copy the resulting hash (e.g., $2a$14$...)
```

**D. Update Caddyfile**
Edit `/etc/caddy/Caddyfile` and update the `@lxd` block to implement the BasicAuth and mTLS bridge:

```caddyfile
    # Route LXD UI & API Traffic
    @lxd host lxd.ionsignal.com
    handle @lxd {
        # Protect the URL with your hashed password
        basic_auth {
            admin <PASTE_YOUR_BCRYPT_HASH_HERE>
        }

        # Proxy to LXD and present the Client Certificate
        reverse_proxy 127.0.0.1:8443 {
            transport http {
                tls_insecure_skip_verify
                tls_client_auth /etc/caddy/lxd-certs/caddy.crt /etc/caddy/lxd-certs/caddy.key
            }
        }
    }
```

Reload Caddy to apply the changes:

```bash
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

_(You can now access the fully authenticated UI at `https://lxd.ionsignal.com`)_

### **6. Declarative Profile Management**

To maintain Infrastructure-as-Code (IaC) principles, LXD container profiles (network attachments, disk mapping, limits) are stored as YAML files in the workspace.

To inject or update an LXD profile directly from a YAML configuration file, use the following declarative command:

```bash
# Replace [profile] with the target profile name (e.g., minecraft-base)
cat /workspace/ionsignal-network/configs/lxd/[profile].yaml | lxc profile edit [profile]

# Verify the changes were applied
lxc profile show [profile]
```

_(Note: If the profile does not exist yet, you must first create it using `lxc profile create [profile]` before running the edit command)._

### **7. Host NVIDIA Driver Preparation (Production LTS / Headless)**

To support current RTX A4000s and future-proof the host for bleeding-edge hardware (e.g., RTX 6000 Ada/Pro), we utilize the official NVIDIA Network Repository.

We utilize NVIDIA's modern compute-only packaging and explicitly pin the system to the **580 Production Branch**. This avoids known power-state and clock-throttling bugs in the volatile 590/595 feature branches, ensuring zero-latency token streaming for SGLang/vLLM. To maintain strict host hygiene in the DMZ, we **do not** install the CUDA Toolkit, Python, or PyTorch on the bare metal.

#### **A. Add the Modern NVIDIA CUDA Keyring (v1.1)**

This dynamically detects your OS version (Ubuntu 24.04) and adds the official NVIDIA repository to your `apt` sources.

```bash
# Extract OS version dynamically
distribution=$(. /etc/os-release;echo $ID$VERSION_ID | sed -e 's/\.//g')

# Download and install the updated 1.1 keyring
wget https://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb

# Update apt to pull from the new NVIDIA repository
sudo apt update
```

#### **B. Pin the Branch & Install Compute-Only Drivers**

We lock `apt` to the 580 branch and install only the headless compute libraries and DKMS. DKMS (Dynamic Kernel Module Support) is mandatory; it ensures the proprietary NVIDIA kernel modules automatically rebuild if Ubuntu updates the host's kernel.

```bash
# Lock the system safely to the 580 Production Branch
sudo apt install -y nvidia-driver-pinning-580

# Install the 580-specific compute libraries, utils (for nvidia-smi), and DKMS
sudo apt install -y libnvidia-compute-580 nvidia-utils-580 nvidia-dkms-580

# Reboot the server to load the new kernel modules
sudo reboot
```

#### **C. Post-Reboot Verification & Performance Tuning (The Source of Truth)**

Once the server is back online, verify the PCIe devices are initialized. We also enable Persistence Mode to prevent the GPUs from dropping into low-power P-States when idle, ensuring the AI engine can instantly respond to API requests.

```bash
# 1. Verify driver initialization (Check Driver Version and ensure all 4x GPUs are listed)
nvidia-smi

# 2. Verify the device nodes were successfully created for LXD passthrough
ls -l /dev/nvidia*

# 3. Enable Persistence Mode (Lock to Maximum Performance State)
# (Prevents cold-start latency on inference requests)
sudo nvidia-smi -pm 1
```

_(Note: The `CUDA Version` displayed in `nvidia-smi` is simply the maximum supported API version by the driver; it does not mean the toolkit is installed on the host)._

#### **D. Install NVIDIA Container Toolkit (LXD Bridge)**

While the host now possesses the kernel-space drivers, LXD requires the NVIDIA Container Toolkit to seamlessly bind-mount the user-space libraries (`libcuda.so`, `nvidia-smi`) into our unprivileged containers. This allows us to use the `nvidia.runtime: "true"` flag in our LXD profiles, completely avoiding version-mismatch dependency hell inside the container.

```bash
# Add the official NVIDIA Container Toolkit repository and GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update apt and install the toolkit
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Restart the LXD snap daemon so it detects the toolkit binaries
sudo systemctl restart snap.lxd.daemon
```

### **8. Execution: Launching the AI Engine (vLLM)**

_Objective: Deploy the Qwen ~35B MoE LLM using vLLM to bypass hardware FP8 instruction limitations on Ampere GPUs (via the Marlin kernel). To achieve maximum bare-metal throughput (80-90+ t/s) and prevent NCCL from falling back to the TCP loopback interface, we must systematically dismantle host-level IPC barriers, provision dedicated NVMe storage, and securely escalate the container's PCIe privileges._

#### **8.1. Host-Level IPC Unlocking (YAMA Policy)**

By default, Ubuntu's YAMA security module prevents cross-process memory attachment (CMA). NVIDIA's NCCL library relies heavily on CMA for Shared Memory (SHM) synchronization when coordinating tensor parallelism across multiple GPUs. We must relax this policy on the bare-metal host before launching the container.

```bash
# Temporarily relax YAMA to allow cross-process memory attachment for NCCL
sudo sysctl -w kernel.yama.ptrace_scope=0

# Make the relaxation persistent across host reboots
echo "kernel.yama.ptrace_scope=0" | sudo tee /etc/sysctl.d/10-ptrace.conf

# Apply system changes
sudo sysctl --system
```

#### **8.2. Decoupled AI Storage Vault**

Create a dedicated 100GB custom volume on the high-performance ZFS NVMe pool. This isolates the massive HuggingFace/vLLM model weight caches from the ephemeral container OS.

```bash
# Verify pool capacity before provisioning
zfs list is-nvme-pool

# Provision the dedicated model vault
lxc storage volume create is-nvme-pool is-model-vault
lxc storage volume set is-nvme-pool is-model-vault size=100GiB
```

#### **8.3. Declarative Profile Escalation**

To allow the 4x RTX A4000s to communicate directly over the PCIe bus (bypassing the CPU entirely), the container requires `CAP_SYS_ADMIN` and raw LXC limits for `unlimited` memory locking. We apply these via our declarative Infrastructure-as-Code (IaC) YAML profiles.

> **Security Note:** This configuration escalates the container to `security.privileged: "true"`. While this breaks our strict unprivileged rule for the DMZ, this container sits behind the Caddy API gateway, has no inbound internet access (enforced by host UFW), and is dedicated solely to the AI engine. This is an accepted risk required to unlock bare-metal PCIe P2P DMA speeds.

```bash
# Navigate to the infrastructure repository
cd ~/runemind-infrastructure/configs/lxd/

# Create the empty profile
lxc profile create vllm

# Inject the hardware and network configuration
lxc profile edit vllm < profiles/vllm.yaml

# Inject the cloud-init bootstrap script
lxc profile set vllm user.user-data - < init/vllm.yaml
```

#### **8.4. Container Launch & Verification**

Launch the container using the official Ubuntu 24.04 image and apply our newly configured profile.

```bash
# Launch the container
lxc launch ubuntu:24.04 vllm --profile default --profile vllm

# Watch the automated cloud-init installation in real-time
lxc exec vllm -- tail -f /var/log/cloud-init-output.log

# Verify the container received its static IP (10.10.10.50)
lxc list vllm

# Verify the GPUs successfully passed through to the container
lxc exec vllm -- nvidia-smi
```

#### **8.5. Systemd Service Deployment**

Once `cloud-init` finishes compiling the environment, we wrap the vLLM engine into a robust `systemd` service.

To adhere to Enterprise Infrastructure-as-Code principles, we utilize **Total Decoupling**. The systemd unit file contains zero execution logic. All parameters, paths, and launch arguments (`VLLM_ARGS`) are strictly inherited from the `/etc/default/vllm` environment file provisioned by `cloud-init`. This allows us to rapidly tune model parameters without reloading systemd daemons, and forces systemd to "fail loudly" if the configuration file is missing.

```bash
# Drop into the container shell
lxc exec vllm -- bash

# Create the systemd service file
sudo vim /etc/systemd/system/vllm.service
```

**File: `/etc/systemd/system/vllm.service` (Inside Container)**

```ini
[Unit]
Description=vLLM AI Inference Engine (Qwen MoE)
Documentation=https://docs.vllm.ai/
After=network.target

[Service]
User=vllm
Group=vllm
WorkingDirectory=/opt/vllm
EnvironmentFile=/etc/default/vllm
ExecStart=/opt/vllm/venv/bin/python3 -m vllm.entrypoints.openai.api_server $API_SERVER_ARGS
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

Apply the configuration and bring the AI engine online:

```bash
# Reload systemd to register the new unit file
systemctl daemon-reload

# Enable the service to start automatically on container boot
systemctl enable --now vllm.service

# Monitor the engine startup, JIT compilation, and model loading in real-time
journalctl -fu vllm.service
```

_(Operational Note: To tune the model, adjust batch sizes, or swap Attention Backends, simply edit `/etc/default/vllm` inside the container and run `systemctl restart vllm`. No `daemon-reload` is necessary)._
