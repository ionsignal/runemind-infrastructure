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

## Nova

TODO: These commands need to be confirmed and updated, do not use this as is...

```bash
/nova pack
/nova generate
/nova updatepack
/nova reload
/nova zip
```

## WorldEdit

```bash
//wand # get the wan tool

//pos1 -192,-64,-192 # create a selection manually with values (p1 worldborder example)
//pos2 192,319,192 # create a selection manually with values (p2 worldborder example)

//hpos1 # create a selection of the block you're looking (p1)
//hpos2 # create a selection of the block you're looking (p2)

//chunk # selects the entire chunk that you are currently standing in.
//size # dimensions of your current selection 

//sel # select your current selection
//desel # deselect your current selection
```
