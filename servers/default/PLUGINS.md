# Plugin Notes

## Server Plugin (wget)

```bash
wget https://cdn.modrinth.com/data/NpvuJQoq/versions/cQ9Te0jw/ViaBackwards-5.5.2-SNAPSHOT.jar -O viabackwards-5.5.2.jar
wget https://cdn.modrinth.com/data/P1OZGk5p/versions/T2fG0MEB/ViaVersion-5.5.2-SNAPSHOT.jar -O viaversion-5.5.2.jar
wget https://cdn.modrinth.com/data/fALzjamp/versions/P3y2MXnd/Chunky-Bukkit-1.4.40.jar -O chunky-bukkit-1.4.40.jar
wget https://cdn.modrinth.com/data/FIlZB9L0/versions/Ufl71nST/Terra-bukkit-6.6.6-BETA%2B451683aff-shaded.jar -O terra-bukkit-6.6.6.jar
```

## Server Plugin (source)

```bash
# terra
# TODO: make our terra pack standalone
cd /opt/minecraft/server/plugins/Terra
unzip default.zip -d ./default
# TODO: remove fancyplugins
# git clone https://github.com/FancyInnovations/FancyPlugins.git ./fancyplugins
# cd ./fancyplugins
# ./gradlew :plugins:fancyholograms:shadowJar
# mv plugins/fancyholograms/build/libs/FancyHolograms-3.0.0-SNAPSHOT.7.jar /opt/minecraft/server/plugins/fancyholograms-3.0.0.jar
# axiompaper
git clone https://github.com/Moulberry/AxiomPaperPlugin.git ./axiompaper
cd ./axiompaper
./gradlew clean build
mv ...[name-version]-all.jar
# huskclaims
git clone https://github.com/WiIIiam278/HuskClaims.git ./huskclaims
cd ./huskclaims
./gradlew clean build
mv paper/build/libs/HuskClaims-Paper-1.5.11-d26ee86-indev.jar /opt/minecraft/server/plugins/huskclaims-paper-1.5.11.jar
# huskhomes
git clone https://github.com/WiIIiam278/HuskHomes.git ./huskhomes
cd ./huskhomes
./gradlew clean build
mv paper/build/libs/HuskHomes-Paper-4.9.9-d26ee86-indev.jar /opt/minecraft/server/plugins/huskhomes-paper-4.9.9.jar
# craftengine
git clone https://github.com/Xiao-MoMi/craft-engine.git ./craftengine
cd ./craftengine
./gradlew shadowJar
mv craft-engine-paper-plugin-0.0.64.17.jar /opt/minecraft/server/plugins/
```

## Install Assets

```bash
cd ~/infrastructure/servers/default/assets
unzip vanilla-experience.zip -d ../../../../server/plugins/VanillaExperience
```

## General

```bash
/setworldspawn <x> <y> <z>
```

## Chunky

The following sets a tiny sized world border, that matches the `max-world-size=384` property in `server.properties`

```bash
# config borders
/worldborder set 768 # max-world-size=384 (notice the 768/384 diameter vs radius)
/chunky world world # chunky select world
/chunky worldborder # chunky selection to match the world border
/chunky start # begin pre-chunking

# trim chunks (remove)
/chunky trim world square 0 0 384 
/chunky trim world_name square 0.0 0.0 5000.0 5000.0 inside # delete the entire world in-game for re-generation (server/client restart required)
```

## CraftEngine

```bash
/ce reload [config|recipe|pack|all] # reload different parts of the CraftEngine plugin without a full server restart
/ce item get <id> [amount] # gives a player custom item(s) from the CraftEngine plugin
/ce item browser <id> # opens a GUI for browsing all registered custom items and their recipes
```
