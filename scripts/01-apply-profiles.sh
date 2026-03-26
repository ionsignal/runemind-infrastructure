#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
# Ensure we are running from the directory containing the configs folder
if [ ! -d "configs/lxd" ]; then
  echo "Error: Run this script from the workspace root (where configs/ is located)."
  exit 1
fi
echo "Applying LXD Infrastructure-as-Code..."
# Restore Server Config
echo "-> Syncing Server Configuration..."
cat configs/lxd/server/core.yaml | lxc config edit
# Restore Network
echo "-> Syncing Network (lxdbr0)..."
cat configs/lxd/networks/lxdbr0.yaml | lxc network edit lxdbr0
# Restore Storage Pools
# Note: Assumes the underlying pools (dir and zfs) are already initialized on the host.
echo "-> Syncing Storage Pools..."
cat configs/lxd/storage/default.yaml | lxc storage edit default
cat configs/lxd/storage/nvme.yaml | lxc storage edit is-nvme-pool
# Provision Custom Volumes (Dependency for the vllm profile)
echo "-> Verifying ZFS Model Vault..."
if ! lxc storage volume show is-nvme-pool model-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'model-vault'..."
    lxc storage volume create is-nvme-pool model-vault
fi
# Enforce the 100GB thin-provisioned quota
lxc storage volume set is-nvme-pool model-vault size=100GiB
# Restore Profiles
echo "-> Syncing Profiles..."
cat configs/lxd/profiles/default.yaml | lxc profile edit default
if ! lxc profile show vllm >/dev/null 2>&1; then
    echo "   Creating empty 'vllm' profile..."
    lxc profile create vllm
fi
cat configs/lxd/profiles/vllm.yaml | lxc profile edit vllm
# Provision the Minecraft Plugin Template
echo "-> Verifying ZFS Plugin Template..."
if ! lxc storage volume show is-nvme-pool plugins >/dev/null 2>&1; then
    echo "   Creating custom volume 'plugins'..."
    lxc storage volume create is-nvme-pool plugins
fi
# Apply the declarative configuration (Description, flags, etc.)
if [ -f "configs/lxd/volumes/plugins.yaml" ]; then
    cat configs/lxd/volumes/plugins.yaml | lxc storage volume edit is-nvme-pool plugins
fi
echo "LXD Sync Complete!"
