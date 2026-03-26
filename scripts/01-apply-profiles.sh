#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
# Ensure we are running from the directory containing the configs folder
if [ ! -d "configs/lxd" ]; then
  echo "Error: Run this script from the workspace root (where configs/ is located)."
  exit 1
fi
echo "Applying LXD Infrastructure-as-Code"
# ---------------------------------------------------------
# Stateful Infrastructure
# ---------------------------------------------------------
# TODO: Disabled for testing...
# echo "-> Configuring Server..."
# lxc config set core.https_address 10.10.10.1:8443
# echo "-> Configuring Network (lxdbr0)..."
# lxc network set lxdbr0 ipv4.address 10.10.10.1/24
# lxc network set lxdbr0 ipv4.dhcp.ranges 10.10.10.100-10.10.10.200
# lxc network set lxdbr0 ipv4.nat true
# lxc network set lxdbr0 ipv6.address none
# lxc network set lxdbr0 ipv6.nat false
echo "-> Verifying Storage Pools..."
# We DO NOT edit storage pools. We just verify they exist.
lxc storage show default >/dev/null || echo "WARNING: 'default' pool missing!"
lxc storage show is-nvme-pool >/dev/null || echo "WARNING: 'is-nvme-pool' missing!"
# ---------------------------------------------------------
# Custom Volumes (The Vaults)
# ---------------------------------------------------------
# Create [is-model-vault]:
echo "-> Verifying ZFS Model Vault..."
if ! lxc storage volume show is-nvme-pool is-model-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-model-vault'..."
    lxc storage volume create is-nvme-pool is-model-vault
fi
# Safely set the size quota. We omit security.shifted to protect the existing vLLM data.
# TODO: When we ultimately come back to this, let's correct security.shifted.
lxc storage volume set is-nvme-pool is-model-vault size=100GiB
# Create [is-plugins-vault]:
echo "-> Verifying ZFS Plugin Template Vault..."
if ! lxc storage volume show is-nvme-pool is-plugins-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-plugins-vault'..."
    lxc storage volume create is-nvme-pool is-plugins-vault
fi
# Safely apply the VFS idmapping flag via CLI
lxc storage volume set is-nvme-pool is-plugins-vault security.shifted=true
# ---------------------------------------------------------
# Stateless Templates (Declarative Profiles)
# ---------------------------------------------------------
echo "-> Syncing Profiles..."
# Loop through all profiles to reduce code duplication
PROFILES=("default" "builder" "papermc") # TODO: Add back "vllm" after testing
for profile in "${PROFILES[@]}"; do
    if ! lxc profile show "$profile" >/dev/null 2>&1; then
        echo "   Creating empty '$profile' profile..."
        lxc profile create "$profile"
    fi
    if [ -f "configs/lxd/profiles/$profile.yaml" ]; then
        cat "configs/lxd/profiles/$profile.yaml" | lxc profile edit "$profile"
    fi
done
echo "LXD Sync Complete!"