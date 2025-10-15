# Plugin Help

## Server Plugin Installs

```bash
wget https://cdn.modrinth.com/data/NpvuJQoq/versions/cQ9Te0jw/ViaBackwards-5.5.2-SNAPSHOT.jar -O viabackwards-5.5.2.jar
wget https://cdn.modrinth.com/data/P1OZGk5p/versions/T2fG0MEB/ViaVersion-5.5.2-SNAPSHOT.jar -O viaversion-5.5.2.jar
wget https://cdn.modrinth.com/data/fALzjamp/versions/P3y2MXnd/Chunky-Bukkit-1.4.40.jar -O chunky-bukkit-1.4.40.jar
craftengine
huskclaims
fancyplugins
huskhomes
axiompaper
```

## General

```bash
/setworldspawn <x> <y> <z>
```

## Chunky

The following sets a tiny sized world border, that matches the `max-world-size=384` property in `server.properties`

```bash
/worldborder set 768 # max-world-size=384 (notice the 768/384 diameter vs radius)
/chunky world world # chunky select world
/chunky worldborder # chunky selection to match the world border
/chunky start # begin pre-chunking

/chunky trim world square 0 0 384 # trim chunks (remove)
/chunky trim world_name square 0.0 0.0 5000.0 5000.0 inside # delete the entire world in-game for re-generation (server/client restart required)
```
