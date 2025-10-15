# Servers

## Default

### Minecraft Server Lobby Install

Download and install Paper JAR

```bash
lxc launch ubuntu-minimal:22.04 mc-runemind-lobby --profile minecraft-base --profile minecraft-lobby
lxc exec mc-runemind-lobby -- bash
sudo -u minecraft -s
git clone git@github.com:ionsignal/runemind-infrastructure.git ./infrastructure
cd /opt/minecraft/server
wget -O paper.jar https://fill-data.papermc.io/v1/objects/8de7c52c3b02403503d16fac58003f1efef7dd7a0256786843927fa92ee57f1e/paper-1.21.8-60.jar
java -jar paper.jar --nogui # Generate init and EULA
```

Agree to EULA:

```bash
vim eula.txt # Change eula=false to eula=true
```

Initial run to generate necessary files:

```bash
java -jar paper.jar --nogui # wait for startup, then > 'stop'
```

### Create Service

```bash
sudo vim /etc/systemd/system/minecraft.service
```

```ini
[Unit]
Description=Minecraft Server (Paper)
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=minecraft
Group=minecraft
WorkingDirectory=/opt/minecraft/server

# Use tmux to run the server in a detached session
# The session is named 'minecraft'
ExecStart=/usr/bin/tmux new-session -d -s minecraft /usr/bin/java -Xms10G -Xmx10G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -XX:+EnableDynamicAgentLoading -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -jar paper.jar --nogui

# Send the 'stop' command to the tmux session for a graceful shutdown
# Then, wait until the tmux session (and the server) has fully terminated
ExecStop=/usr/bin/tmux send-keys -t minecraft "stop" C-m ; /bin/sleep 10

Restart=on-failure
RestartSec=10
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

#### Reload and Test the Service

```bash
sudo systemctl daemon-reload
sudo systemctl start minecraft
sudo systemctl status minecraft
sudo systemctl stop minecraft
```

#### Attaching to the Server Console

As the 'minecraft' user:
To detach from the console without stopping the server, press: Ctrl+b, then d

```bash
sudo -u minecraft -s
tmux attach-session -t minecraft
```

Don't forget to delete the old version of the plugin before restarting

### Inject Compiled Plugins (LXD)

TODO: add code to get the uid and gid

```bash
scp -P 2222 ./ ubuntu@office.ionsignal.com:~
lxc file push ~/ mc-server-lobby/opt/minecraft/server/plugins/ --uid=109 --gid=114
```

### Anonymous Git Configuration

This is needed to successfully compile some of the plugins

```bash
git config --global user.name "anon"
git config --global user.email "anon@anon.com"
```

#### Performance Tuning for 100-200 Players

With the server running, it's time to optimize its configuration files for a high player count. These files are located in `/opt/minecraft/server/`. Stop your server (`sudo systemctl stop minecraft`) before editing these files.

The key files are:

* `server.properties`: Vanilla Minecraft settings.
* `bukkit.yml`: Settings from the Bukkit API.
* `spigot.yml`: Settings from the Spigot API.
* `config/paper-world-defaults.yml`: Paper's powerful, per-world configuration defaults.

##### Key Concept: `view-distance` vs. `simulation-distance`

Understanding this distinction is crucial for performance.

* **`view-distance`**: Determines how many chunks of terrain are *visible* to a player. It primarily impacts network bandwidth and client-side rendering.
* **`simulation-distance`**: Determines how many chunks around a player are actively *ticking*—processing mobs, growing crops, and running redstone. This has a massive impact on CPU performance.

For a server with 100+ players, you must keep `simulation-distance` low. A higher `view-distance` can be used to give players a better sense of scale without the same performance hit.

##### Recommended Configuration Changes

1. **`server.properties`**
    * `view-distance`: `10` (A good starting point. You can lower it to `8` if needed.)
    * `simulation-distance`: `4` or `5` (This is one of the most important performance settings. Do not set this high.)
    * `network-compression-threshold`: `256` (Reduces CPU usage for network packets.)

2. **`bukkit.yml`**
    * `spawn-limits`: Adjust these based on your server type. For survival, you might lower `monsters` to `50` and `animals` to `10`.
    * `chunk-gc.period-in-ticks`: `400` (Cleans up unused chunks less frequently.)
    * `ticks-per.monster-spawns`: `4` (Slightly reduces how often monster spawn attempts are made.)

3. **`spigot.yml`**
    * `entity-activation-range`: Lowering these values prevents entities far from players from being ticked. Set `animals` to `16`, `monsters` to `24`, and `misc` to `8`.
    * `mob-spawn-range`: Set this to be one less than your `simulation-distance`. For a simulation distance of 5, set this to `4`.
    * `merge-radius.item`: `4.0`
    * `merge-radius.exp`: `6.0` (Merges dropped items and XP orbs more aggressively to reduce entities.)

4. **`config/paper-world-defaults.yml`** (This file contains Paper's most impactful optimizations)
    * `optimize-explosions`: `true` (Uses Paper's highly efficient explosion algorithm.)
    * `mob-spawner-tick-rate`: `2` (Reduces how often mob spawners are checked, with minimal impact on rates.)
    * `use-faster-eigencraft-redstone`: `true` (Enables a faster redstone implementation.)
    * `prevent-moving-into-unloaded-chunks`: `true` (Prevents players from causing lag by moving into chunks that haven't loaded yet.)
    * `per-player-mob-spawns`: `true` (This is a game-changer. It spawns mobs based on individual players rather than a global cap, resulting in a much more consistent and fair mob spawning experience in multiplayer.)
    * `despawn-ranges`: Set soft to `28` and hard to `96`. This will more aggressively despawn mobs that are far away from players.
    * `max-auto-save-chunks-per-tick`: `8` (Reduces lag spikes from world saving by spreading the load over more time.)

After making these changes, start your server again (`sudo systemctl start minecraft`). You now have a solid, performance-tuned Paper server ready for your community.
