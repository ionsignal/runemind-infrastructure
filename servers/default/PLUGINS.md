# Plugin Help

## Server Plugin Installs

```bash
viabackwards
viaversion
vault
wget https://cdn.modrinth.com/data/yCVqpwUy/versions/MZoF8npG/Nova-0.20-alpha.4%2BMC-1.21.7.jar -O nova-0.20-alpha.4-1.21.7.jar
wget https://cdn.modrinth.com/data/fALzjamp/versions/P3y2MXnd/Chunky-Bukkit-1.4.40.jar -O chunky-bukkit-1.4.40.jar
huskhomes
worldedit
worldguard
axiompaper
```

## Chunky

The following sets a dev sized world border, that matches the `max-world-size=176` property in `server.properties`

```
/worldborder set 176
/chunky worldborder
```

Trim off chunks that were created outside the world border.
TODO: test this to learn the best settings, like are we getting chunks trimmed on world initial creation? (we don't want that)

```
/chunky trim world square 0 0 88
```

Delete the entire world in-game for re-generation

```
/chunky trim world_name square 0.0 0.0 5000.0 5000.0 inside
```