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
incus storage volume set is-nvme-pool is-model-vault size=100GiB || echo "   -> Notice: Could not update size (volume may be in use)."
# Create [is-plugins-vault]:
echo "-> Verifying ZFS Plugin Template Vault..."
if ! incus storage volume show is-nvme-pool is-plugins-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-plugins-vault'..."
    incus storage volume create is-nvme-pool is-plugins-vault
fi
incus storage volume set is-nvme-pool is-plugins-vault security.shifted=true || echo "   -> Notice: Could not update shifted flag (volume may be in use)."
# Create [is-world-vault]:
echo "-> Verifying ZFS World Template Vault..."
if ! incus storage volume show is-nvme-pool is-world-vault >/dev/null 2>&1; then
    echo "   Creating custom volume 'is-world-vault'..."
    incus storage volume create is-nvme-pool is-world-vault
fi
incus storage volume set is-nvme-pool is-world-vault security.shifted=true || echo "   -> Notice: Could not update shifted flag (volume may be in use)."
# ---------------------------------------------------------
# Stateless Templates (Declarative Profiles)
# ---------------------------------------------------------
echo "-> Syncing Profiles..."
# Loop through all profiles to reduce code duplication
PROFILES=("default" "builder" "papermc" "vllm" "minecraft")
for profile in "${PROFILES[@]}"; do
    # Check if profile exists, create if it doesn't
    if ! incus profile show "$profile" >/dev/null 2>&1; then
        echo "   Creating empty '$profile' profile..."
        incus profile create "$profile"
    fi
    # If the YAML definition exists, pipe it directly into Incus
    if [ -f "configs/incus/profiles/$profile.yaml" ]; then
        echo "   Applying configuration for '$profile'..."
        cat "configs/incus/profiles/$profile.yaml" | incus profile edit "$profile"
    else
        echo "   WARNING: configs/incus/profiles/$profile.yaml not found, skipping edit."
    fi
    # Inject cloud-init user-data if an init file exists
    if [ -f "configs/incus/init/$profile.yaml" ]; then
        echo "   Injecting cloud-init configuration for '$profile'..."
        incus profile set "$profile" user.user-data - < "configs/incus/init/$profile.yaml"
    fi
done
echo "Incus Sync Complete!"
