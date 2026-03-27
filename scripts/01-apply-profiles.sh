#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status
# Ensure we are running from the directory containing the configs folder
if [ ! -d "configs/incus" ]; then
  echo "Error: Run this script from the workspace root (where configs/incus/ is located)."
  exit 1
fi
echo "Applying Incus Infrastructure-as-Code..."
# ---------------------------------------------------------
# Stateful Infrastructure
# ---------------------------------------------------------
echo "-> Verifying Storage Pools..."
# We DO NOT edit storage pools automatically. We just verify they exist.
incus storage show default >/dev/null || echo "WARNING: 'default' pool missing!"
incus storage show is-nvme-pool >/dev/null || echo "WARNING: 'is-nvme-pool' missing!"
# ---------------------------------------------------------
# Custom Volumes (The Vaults)
# ---------------------------------------------------------
# Create [is-model-vault]:
echo "-> Verifying ZFS Model Vault..."
if ! incus storage volume show is-nvme-pool is-model-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-model-vault'..."
    incus storage volume create is-nvme-pool is-model-vault
fi
# Safely set the size quota. We omit security.shifted to protect the existing vLLM data.
incus storage volume set is-nvme-pool is-model-vault size=100GiB
# Create [is-plugins-vault]:
echo "-> Verifying ZFS Plugin Template Vault..."
if ! incus storage volume show is-nvme-pool is-plugins-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-plugins-vault'..."
    incus storage volume create is-nvme-pool is-plugins-vault
fi
# Safely apply the VFS idmapping flag via CLI so unprivileged containers can read/write
incus storage volume set is-nvme-pool is-plugins-vault security.shifted=true
# ---------------------------------------------------------
# Stateless Templates (Declarative Profiles)
# ---------------------------------------------------------
echo "-> Syncing Profiles..."
# Loop through all profiles to reduce code duplication
PROFILES=("default") # TODO: Add back "vllm" "builder" "papermc" after testing
for profile in "${PROFILES[@]}"; do
    # Check if profile exists, create if it doesn't
    if ! incus profile show "$profile" >/dev/null 2>&1; then
        echo "   Creating empty '$profile' profile..."
        incus profile create "$profile"
    fi
    # If the YAML definition exists, pipe it directly into Incus
    if[ -f "configs/incus/profiles/$profile.yaml" ]; then
        echo "   Applying configuration for '$profile'..."
        cat "configs/incus/profiles/$profile.yaml" | incus profile edit "$profile"
    else
        echo "   WARNING: configs/incus/profiles/$profile.yaml not found, skipping edit."
    fi
done
echo "Incus Sync Complete!"
