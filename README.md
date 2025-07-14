# Minecraft Server Network Guide

The following is a guide for System Administrators to install and maintain the various Minecraft network components.

## LXD

The following is how we inject an update into a LXD profile
Replace [profile] with the profile you are targeting

```bash
cat /workspace/minecraft-infrastructure/configs/lxd/[profile].yaml | lxc profile edit [profile]
lxc profile show minecraft-base
```

### Update Git Submodules

How to Get the Latest from a Submodule's Branch

If you do want a submodule to be at the latest commit of its main branch (which is a less common but sometimes necessary workflow), you would typically do this manually:
cd libs/huskhomes (or whichever submodule you want to update)

```bash
git submodule update --init --recursive
cd ../to/submodule
git checkout main (or master or the desired branch)
git pull origin main (or master)
cd ../.. (back to the superproject root)
git add to/submodule (to record the new commit hash that huskhomes is now pointing to)
git commit -m "Update submodule to latest main"
```

### Velocity Proxy Install

```bash
lxc launch ubuntu-minimal:22.04 mc-velocity-proxy --profile minecraft-base --profile minecraft-proxy
```

### Other

...
