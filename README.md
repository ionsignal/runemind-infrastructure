# System Infrastructure Guide

## Base OS Installation & UEFI Initialization

### **1. Install IPMI Tools install**

```bash
sudo apt update
sudo apt install ipmitool
sudo modprobe ipmi_devintf
sudo modprobe ipmi_si
sudo vim /etc/modules
```

```
ipmi_devintf
ipmi_si
```

### **2. JournalD Configuration**

```bash
sudo vim /etc/systemd/journald.conf
```

```ini
[Journal]
Compress=yes
Storage=persistent
Seal=no
SyncIntervalSec=5m
SystemMaxUse=1G
SystemMaxFileSize=8M
SystemMaxFiles=100
RuntimeMaxUse=1G
MaxRetentionSec=1month
MaxFileSec=1month
Audit=no
```

```bash
sudo systemctl restart systemd-journald
```

### **3. UEFI & NVRAM Baseline**

- **Boot Mode:** UEFI Only (Disable Legacy/CSM).
- **Secure Boot:** Disabled (Required for NVIDIA driver/CUDA compilation).
- **NVRAM Cleanup:** `sudo efibootmgr` -> delete stale entries (e.g., `sudo efibootmgr -b XXXX -B`).
- **OS Target:** Ubuntu 24.04 LTS on 250GB NVMe (`ext4`, **No LVM**).

### **4. Static Network Configuration (Netplan)**

To prevent ARP flux on the DMZ switch and provide a highly available, stable default gateway for the Incus containers, the dual 1GbE interfaces are bonded using Active-Backup (Mode 1). This ensures zero-downtime failover without requiring 802.3ad (LACP) configuration on the upstream EFG.

```bash
sudo vim /etc/netplan/50-cloud-init.yaml
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

### **5. Safely Apply and Verify**

Apply the configuration using `try` to prevent lockouts during the interface transition.

```bash
# Update the plan, check if SSH is stable
sudo netplan try

# Verify the IP is now exclusively bound to bond0
ip -br a

# Verify the kernel bonding module status
cat /proc/net/bonding/bond0
```

### **6. SSH Access Control**

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

### **7. Zero-Trust Firewall (UFW)**

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
sudo ufw allow out to 10.10.10.0/24 comment 'Priority: Allow Host to Incus subnet'
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
sudo ufw allow from 172.20.3.119 to any port 22 proto tcp comment 'Allow SSH Home LAN'

# HTTPS (Port 443) - Caddy / Incus UI Access
sudo ufw allow from 172.20.1.0/24 to any port 443 proto tcp comment 'Allow HTTPS Management'
sudo ufw allow from 172.20.3.0/24 to any port 443 proto tcp comment 'Allow HTTPS Home'

# Allow the Fastify Control Plane (TCP 8443) to reach the Incus API, Deny others
sudo ufw allow in on incusbr0 from 10.10.10.20 to 10.10.10.1 port 8443 proto tcp comment 'Allow Fastify to Incus API'
sudo ufw deny in on incusbr0 from 10.10.10.0/24 to 10.10.10.1 port 8443 proto tcp comment 'Deny Game Servers to Incus API'

# Explicitly allow DHCP (UDP 67) from containers to the host
sudo ufw allow in on incusbr0 to any port 67 proto udp comment 'Incus DHCP'

# Explicitly allow DNS (TCP/UDP 53) from containers to the host
sudo ufw allow in on incusbr0 to any port 53 proto udp comment 'Incus DNS UDP'
sudo ufw allow in on incusbr0 to any port 53 proto tcp comment 'Incus DNS TCP'

# Game Ingress (Incus Proxy Device Architecture)
sudo ufw allow in on bond0 to any port 25565 proto tcp comment 'Allow Inbound Velocity Proxy'

# ==========================================
# 5. ROUTED TRAFFIC (The FORWARD Chain)
# ==========================================

# Fencing: Prevent compromised containers from scanning internal networks
sudo ufw route deny in on incusbr0 out on bond0 to 172.16.0.0/12 comment 'Block Incus outbound to Internal 172.x'
sudo ufw route deny in on incusbr0 out on bond0 to 10.0.0.0/8 comment 'Block Incus outbound to Internal 10.x'
sudo ufw route deny in on incusbr0 out on bond0 to 192.168.0.0/16 comment 'Block Incus outbound to Internal 192.168.x'

# Internet Access: Allow containers to reach the public internet
sudo ufw route allow in on incusbr0 out on bond0 comment 'Allow Incus Outbound Internet'

# ==========================================
# 6. ENABLE AND APPLY
# ==========================================
sudo ufw enable
sudo ufw reload
sudo ufw status numbered
```

### **8. High-Performance ZFS Storage Provisioning (NVMe)**

Provision the drives as a unified, high-performance ZFS storage pool dedicated entirely to Incus. This allows Incus to manage ephemeral containers, persistent decoupled states (Custom Volumes), and a strictly isolated, GPU-passthrough.

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

We create the ZFS pool manually on the host OS first rather than letting Incus do it. This allows us to strictly enforce NVMe-specific performance flags.

- `ashift=12`: Aligns the pool to 4K/8K NVMe sectors (prevents massive write amplification).
- `compression=lz4`: Virtually zero CPU overhead, massive read speed boost for model weights.
- `xattr=sa`: Stores extended attributes directly in the inode. Crucial for Incus because unprivileged containers heavily rely on POSIX ACLs for UID/GID shifting.
- `atime=off`: Completely disables access-time tracking, reducing write-amplification and speeding up Minecraft chunk loading and AI model reads.
- `-m none`: Prevents the host OS from mounting the pool, reserving it entirely for Incus.

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

#### **Step 5.4: Clamp the ZFS ARC (Memory Protection)**

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

### **5. Edge Routing & SSL Configuration (caddyfile)**

Define the reverse proxy rules and instruct Caddy to use the `acme-dns` credentials for zero-downtime, automated wildcard certificate renewals. Add /etc/caddy/caddyfile configuration, adjusting the reverse proxy ports to match your specific vLLM/SGLANG and LXD setups. Set the correct ownership and permissions for the configuration file:

```bash
sudo chown caddy:caddy /etc/caddy/caddyfile
sudo chmod 644 /etc/caddy/caddyfile
```

### **6. Systemd Service Integration**

Create a systemd unit file to manage the Caddy process. This configuration enforces the unprivileged `caddy` user while explicitly passing the network binding capabilities through systemd's security boundary.

```bash
sudo vim /etc/systemd/system/caddy.service
```

Reload the systemd daemon, enable the service to start on boot, and start it immediately:

```bash
sudo systemctl daemon-reload
sudo systemctl enable caddy
sudo systemctl start caddy
sudo systemctl status caddy

```

## Micro-CA Deployment on AWS (ARM64)

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

### Install TXT Record Managment on Micro-CA

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

#### **6. Route 53 CNAME for `ionsignal.com`**

Go to your AWS Route 53 Console, open the Hosted Zone for **`ionsignal.com`**, and create this record:

- **Record Name:** `_acme-challenge.ionsignal.com`
- **Record Type:** `CNAME`
- **Value:** `[uuid].auth.ionsignal.com` _(Paste your exact `fulldomain` string here)._

## Incus Installation & Zero-Trust UI Proxy

_Objective: Deploy the Incus container hypervisor. To maintain strict Zero-Trust boundaries, Incus is bound exclusively to `localhost`. Caddy acts as an authenticated mTLS bridge, terminating the wildcard SSL and protecting the Web UI with Basic Authentication._

### **1. Install Incus (Zabbly Stable Repository)**

Install Incus natively via `apt` using the official Zabbly repository. This ensures a cleaner host environment, avoids loop-device clutter, and provides the most up-to-date stable releases.

```bash
# 1. Create the keyrings directory if it doesn't exist
sudo mkdir -p /etc/apt/keyrings

# 2. Download the Zabbly repository signing key
sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

# 3. Add the Zabbly Incus Stable repository dynamically based on OS codename (noble)
cat <<EOF | sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

# 4. Update apt and install Incus alongside the Canonical UI
sudo apt-get update
sudo apt-get install -y incus incus-ui-canonical

# 5. Grant your user full access to the Incus socket
sudo usermod -aG incus-admin $USER
newgrp incus-admin

# Verify the installation
incus --version
```

### **2. Host Network Preparation**

Incus containers rely on the host's IP for outbound NAT. IP forwarding must be permanently enabled at the kernel level before Incus builds its network bridge.

```bash
# Enable IPv4 forwarding permanently
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

# Apply the change immediately
sudo sysctl -p
```

### **3. Minimal Initialization (Deferred Storage)**

To isolate variables and test the network proxy, we initialize Incus without any storage pools. The optimized NVMe ZFS pools will be attached later.

Run the initialization wizard:

```bash
sudo incus admin init
```

Provide the following exact answers to bind Incus securely to localhost, establish the `incusbr0` bridge, and disable IPv6:

- **Would you like to use Incus clustering?** `no`
- **Do you want to configure a new storage pool?** `no`
- **Would you like to create a new local network bridge?** `yes`
- **What should the new bridge be called?** `incusbr0`
- **What IPv4 address should be used?** `10.10.10.1/24`
- **Would you like to NAT IPv4 traffic on your bridge?** `yes`
- **What IPv6 address should be used?** `none` _(Crucial: Disables IPv6 in the DMZ)_
- **Would you like the Incus server to be available over the network?** `yes`
- **Address to bind Incus to (not including port):** `127.0.0.1` _(Crucial: Change this Later)_
- **Port to bind Incus to:** `8443`
- **Trust password for new clients:** `[Enter a secure password]`
- **Would you like stale cached images to be updated automatically?** `yes`
- **Would you like a YAML "incus init" preseed to be printed?** `no`

### **4. Lock the Internal Network Subnet and Attach the ZFS NVMe Pool**

Because we hardcoded the `10.10.10.1/24` CIDR block during initialization, the network is already securely established. However, we must still restrict the DHCP pool to leave `.2` through `.99` available for Static IPs (Velocity, AI, Fastify).

```bash
# Shift the API bind from localhost to the newly created bridge IP
sudo incus config set core.https_address 10.10.10.1:8443

# Restrict the DHCP pool to leave room for Static IPs
incus network set incusbr0 ipv4.dhcp.ranges 10.10.10.100-10.10.10.200

# Explicitly disable IPv6 NAT routing on the bridge (Defense in Depth)
incus network set incusbr0 ipv6.nat false

# Verify the network is locked down
incus network show incusbr0

# Tell Incus to consume the existing 'is-nvme-pool' ZFS pool
incus storage create is-nvme-pool zfs source=is-nvme-pool

# Verify Incus sees the new storage pool
incus storage list
```

### **5. The Proxy Authentication Bridge (mTLS)**

Incus requires a Client Certificate (mTLS) for API and UI access. Because Caddy (a Layer 7 proxy) cannot pass a user's browser-based client certificate through to the backend, we must give Caddy its own master certificate to authenticate to Incus automatically, and then protect Caddy's front-door with Basic Authentication.

#### **5.1. Generate Caddy's Client Certificate**

```bash
# Create a secure directory for the keys
sudo mkdir -p /etc/caddy/incus-certs
cd /etc/caddy/incus-certs

# Generate a 10-year client certificate for the Caddy daemon
sudo openssl req -x509 -newkey rsa:4096 -nodes -keyout caddy.key -out caddy.crt -days 3650 -subj "/CN=caddy-proxy"

# Lock down permissions so ONLY the 'caddy' user can read the private key
sudo chown caddy:caddy caddy.key caddy.crt
sudo chmod 600 caddy.key
```

#### **5.2. Inject Certificate into Incus Trust Store**

```bash
# Tell Incus to permanently trust Caddy's client certificate using the new add-certificate command
incus config trust add-certificate /etc/caddy/incus-certs/caddy.crt --name caddy-proxy

# Verify it was added successfully (You should see 'caddy-proxy' listed)
incus config trust list
```

#### **5.3. Generate BasicAuth Password for the Web UI**

Generate a `bcrypt` hashed password. This will be the password you type into the browser prompt to access the Incus dashboard.

```bash
caddy hash-password
# Copy the resulting hash (e.g., $2a$14$...)
```

#### **5.4. Update Caddyfile**

Update `/etc/caddy/caddyfile` (see config file) and update the proxy block to implement the BasicAuth and mTLS bridge.

Reload Caddy to apply the changes:

```bash
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

_(You can now access the fully authenticated UI at `https://incus.ionsignal.com`)_

## Host NVIDIA Driver Preparation (Production LTS / Headless)

To support current RTX A4000s and future-proof the host for bleeding-edge hardware (e.g., RTX 6000 Ada/Pro), we utilize the official NVIDIA Network Repository.

We utilize NVIDIA's modern compute-only packaging and explicitly pin the system to the **580 Production Branch**. This avoids known power-state and clock-throttling bugs in the volatile 590/595 feature branches, ensuring zero-latency token streaming for SGLang/vLLM. To maintain strict host hygiene in the DMZ, we **do not** install the CUDA Toolkit, Python, or PyTorch on the bare metal.

### **1. Add the Modern NVIDIA CUDA Keyring (v1.1)**

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

### **2. Pin the Branch & Install Compute-Only Drivers**

We lock `apt` to the 580 branch and install only the headless compute libraries and DKMS. DKMS (Dynamic Kernel Module Support) is mandatory; it ensures the proprietary NVIDIA kernel modules automatically rebuild if Ubuntu updates the host's kernel.

```bash
# Lock the system safely to the 580 Production Branch
sudo apt install -y nvidia-driver-pinning-580

# Install the 580-specific compute libraries, utils (for nvidia-smi), and DKMS
sudo apt install -y libnvidia-compute-580 nvidia-utils-580 nvidia-dkms-580

# Reboot the server to load the new kernel modules
sudo reboot
```

### **3. Post-Reboot Verification & Performance Tuning (The Source of Truth)**

Once the server is back online, verify the PCIe devices are initialized. We also enable Persistence Mode to prevent the GPUs from dropping into low-power P-States when idle, ensuring the AI engine can instantly respond to API requests.

```bash
# 1. Verify driver initialization (Check Driver Version and ensure all 4x GPUs are listed)
nvidia-smi

# 2. Verify the device nodes were successfully created for Incus passthrough
ls -l /dev/nvidia*

# 3. Enable Persistence Mode (Lock to Maximum Performance State)
# (Prevents cold-start latency on inference requests)
sudo nvidia-smi -pm 1
```

_(Note: The `CUDA Version` displayed in `nvidia-smi` is simply the maximum supported API version by the driver; it does not mean the toolkit is installed on the host)._

### **4. Install NVIDIA Container Toolkit (Incus Bridge)**

While the host now possesses the kernel-space drivers, Incus requires the NVIDIA Container Toolkit to seamlessly bind-mount the user-space libraries (`libcuda.so`, `nvidia-smi`) into our unprivileged containers. This allows us to use the `nvidia.runtime: "true"` flag in our Incus profiles, completely avoiding version-mismatch dependency hell inside the container.

```bash
# Add the official NVIDIA Container Toolkit repository and GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update apt and install the toolkit
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Restart the Incus snap daemon so it detects the toolkit binaries
sudo systemctl restart incus
```

## Incus Infrastructure-as-Code Synchronization

_Objective: Synchronize the declarative Incus profiles (`builder`, `papermc`, `default`) and provision the isolated ZFS storage vaults (`is-model-vault`, `is-plugins-vault`) before launching any containers. This script enforces the baseline state of the hypervisor._

### **1. Apply Declarative Profiles**

Navigate to the root of your infrastructure repository. The synchronization script must be executed from this location to correctly resolve the `configs/incus` directory paths.

```bash
# Navigate to the workspace root
cd ~/runemind-infrastructure

# Grant execution permissions to the script
chmod +x scripts/01-apply-profiles.sh

# Execute the synchronization pipeline
./scripts/01-apply-profiles.sh
```

## Launching the AI Engine (vLLM)

_Objective: Deploy the Qwen ~35B MoE LLM using vLLM to bypass hardware FP8 instruction limitations on Ampere GPUs (via the Marlin kernel). To achieve maximum bare-metal throughput (80-90+ t/s) and prevent NCCL from falling back to the TCP loopback interface, we must systematically dismantle host-level IPC barriers, provision dedicated NVMe storage, and securely escalate the container's PCIe privileges._

### **1. Host-Level IPC Unlocking & Toolkit Hook**

By default, Ubuntu's YAMA security module prevents cross-process memory attachment (CMA). NVIDIA's NCCL library relies heavily on CMA for Shared Memory (SHM) synchronization when coordinating tensor parallelism across multiple GPUs. We must relax this policy on the bare-metal host.

```bash
# Temporarily relax YAMA to allow cross-process memory attachment for NCCL
sudo sysctl -w kernel.yama.ptrace_scope=0

# Make the relaxation persistent across host reboots
echo "kernel.yama.ptrace_scope=0" | sudo tee /etc/sysctl.d/10-ptrace.conf

# Apply system changes
sudo sysctl --system

# Restart incus to apply changes
sudo systemctl restart incus
```

### **2. Container Launch & Verification**

Launch the container using the official Ubuntu 24.04 image and apply our newly configured profiles. _(Crucial: Incus uses the community `images:` remote, not Canonical's proprietary `ubuntu:` remote)._

```bash
# Launch the container
incus launch images:ubuntu/24.04/cloud vllm --profile default --profile vllm

# Watch the automated cloud-init installation in real-time
incus exec vllm -- tail -f /var/log/cloud-init-output.log

# Verify the container received its static IP (10.10.10.50)
incus list vllm

# Verify the GPUs successfully passed through to the container
incus exec vllm -- nvidia-smi
```

### **3. Systemd Service Deployment**

Once `cloud-init` finishes compiling the environment, we wrap the vLLM engine into a robust `systemd` service.

To adhere to Enterprise Infrastructure-as-Code principles, we utilize **Total Decoupling**. The systemd unit file contains zero execution logic. All parameters, paths, and launch arguments (`VLLM_ARGS`) are strictly inherited from the `/etc/default/vllm` environment file provisioned by `cloud-init`. This allows us to rapidly tune model parameters without reloading systemd daemons, and forces systemd to "fail loudly" if the configuration file is missing.

```bash
# Drop into the container shell
incus exec vllm -- bash

# Create the systemd service file
sudo vim /etc/systemd/system/vllm.service
```

**File: `/etc/systemd/system/vllm.service` (see configuration)**

Apply the configuration and bring the AI engine online:

```bash
# Reload systemd to register the new unit file
systemctl daemon-reload

# Running server manually (recommended for first time)
su vllm
source /etc/profile.d/vllm.sh
source venv/bin/activate
python -m vllm.entrypoints.openai.api_server $API_SERVER_ARGS

# Enable the service to start automatically on container boot
systemctl enable --now vllm.service

# Monitor the engine startup, JIT compilation, and model loading in real-time
journalctl -fu vllm.service
```

_(Operational Note: To tune the model, adjust batch sizes, or swap Attention Backends, simply edit `/etc/default/vllm` inside the container and run `systemctl restart vllm`. No `daemon-reload` is necessary)._

_(Security Note: Gateway Authentication for the Caddy `@ai` reverse proxy route is currently deferred to prioritize internal throughput testing. The endpoint is openly routing to `10.10.10.50:8080`. This must be secured in a future phase before exposing the API beyond the DMZ/Home boundary)._

## Incus Clean-Room Image Builder & Vault Manager

_Objective: Maintain a pristine bare-metal host by isolating both the image compilation process and the management of our ZFS Golden Master vaults. To enforce strict security boundaries, we provision two dedicated Incus containers on the high-speed NVMe ZFS pool: a privileged "Clean Room" for compiling immutable Edge PaaS images (PaperMC, Velocity), and an unprivileged "Vault Manager" to safely inject files and lock down ownership for our ZFS storage templates._

### **1. Infrastructure-as-Code (Pre-Applied)**

The infrastructure is fully declarative and applied via the `01-apply-profiles.sh` script. This script automatically handles:

- **Storage:** Provisioning the three ZFS master vaults (`is-plugins-vault`, `is-world-vault`) with strict VFS idmapping (`security.shifted=true`).
- **Builder Profile (`builder.yaml`):** Granting root-level, privileged capabilities for `distrobuilder` to mount filesystems, forcing the container onto the NVMe pool.
- **Vault Manager Profile (`minecraft.yaml`):** Enforcing an unprivileged security baseline and statically attaching the three ZFS vaults to `/opt/minecraft/`.
- **Init Scripts (`init/*.yaml`):** Injecting `cloud-init` payloads. The builder auto-installs compilation dependencies (`snapd`, `distrobuilder`), while the vault manager natively provisions the `minecraft` (UID 1000) service user.

### **2. Provision the Utility Environments**

Because the infrastructure is pre-configured, provisioning the containers is entirely automated. We use the `/cloud` variant of the Ubuntu image so our `cloud-init` scripts are executed on first boot.

```bash
# Launch the Privileged Clean-Room Builder
incus launch images:ubuntu/24.04/cloud builder --profile default --profile builder

# Launch the Unprivileged Vault Manager
incus launch images:ubuntu/24.04/cloud minecraft --profile default --profile minecraft

# Wait for cloud-init to finish installing dependencies and configuring users (~30-60s)
incus exec builder -- cloud-init status --wait
incus exec minecraft -- cloud-init status --wait
```

### **3. The Compilation Pipeline (Standard Operating Procedure)**

When a new base image (e.g., `papermc.yaml`) needs to be compiled or updated, execute the following pipeline from the bare-metal host. This pushes the definition into the clean room, compiles the cryptographic artifacts, and pulls them back to the host's local image registry.

```bash
# Push the declarative image definition into the builder's workspace
incus file push ./configs/incus/images/papermc.yaml builder/workspace/

# Execute the build process inside the container
# (This downloads the rootfs, installs packages, and compresses the squashfs)
incus exec builder -- bash -c "cd /workspace && distrobuilder build-incus papermc.yaml"

# Pull the compiled artifacts back to the host's temporary directory
mkdir -p /tmp/incus-builds
incus file pull builder/workspace/incus.tar.xz /tmp/incus-builds/
incus file pull builder/workspace/rootfs.squashfs /tmp/incus-builds/

# Import the artifacts into the host's Incus image registry with an alias
incus image import /tmp/incus-builds/incus.tar.xz /tmp/incus-builds/rootfs.squashfs --alias papermc

# Clean up the host's temporary files
rm -rf /tmp/incus-builds

# Verify the image is available for Fastify to clone
incus image list
```

### **4. Stateful Vault Management (The Golden Masters)**

_Objective: Populate the ZFS Golden Master vaults (`plugins`, `world`) with baseline files. Because these vaults are permanently attached to the `minecraft` container, we can push files directly to them at any time and enforce strict unprivileged ownership before our Fastify backend clones them for new tenants._

Execute the following pipeline to update or initialize the global templates:

```bash
# Ensure the Vault Manager is running
incus start minecraft

# Populate the vaults (Pushing files directly from the host)
# The vaults are statically mounted at /opt/minecraft inside the container.
incus file push ./IonCore-v1.jar minecraft/opt/minecraft/plugins/
# Currently the vault manager doesn't build/run papermc
# incus file push ./server.properties minecraft/opt/minecraft/
# incus file push ./paper.yml minecraft/opt/minecraft/

# CRITICAL: Enforce Unprivileged Ownership
# Files pushed from the host may default to root ownership. We MUST shift ownership
# to the 'minecraft' user (UID 1000) so the unprivileged tenant clones can read/write to them.
incus exec minecraft -- chown -R 1000:1000 /opt/minecraft

# Verify ownership applied correctly (Should show minecraft:minecraft)
incus exec minecraft -- ls -la /opt/minecraft/plugins

# (Optional) Stop the utility containers to conserve host resources when not in use
incus stop builder
incus stop minecraft
```

## PaperMC Container Management

If you ever need to run a command as the minecraft user while logged in as root, you can temporarily override the shell constraint by running:

```bash
su -s /bin/bash minecraft
```
