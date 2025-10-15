
# **Final Recommended Plugin Stack**

## Core Systems

* **LuckPerms**
    The definitive permissions plugin. Its performance and web editor are essential for managing player and Persona permissions.
* **HuskHomes**
    A modern, high-performance replacement for essentials warps and homes. Its API will be used for Persona teleportation skills.
* **HuskClaims**
    A robust and API-driven land claiming system. Nerrus Personas will use its API to respect player property, check for build permissions, and manage their own designated areas.
* **LiteBans**
    A critical addition for server moderation. It handles bans, mutes, and kicks with database support, essential for a multi-server network.

## World & Gameplay

* **WorldGuard**
    Essential for creating the protected, immutable spawn hub. It defines the "civilized" space from which players and their Personas will expand.

## Economy & Immersion

* **Economist**
    Our chosen economy core. Its modern, `CompletableFuture`-based API is a perfect architectural match for the Nerrus Engine's asynchronous design, ensuring non-blocking, high-performance transactions.
* **EcoShop/Custom**
    Creates the foundation for a physical, player-driven market. This provides a tangible economic system that Personas can be programmed to observe and eventually participate in.
* **FancyHolograms**
    The best tool for non-intrusive, contextual information. We will use this to display Persona status (e.g., "Goal: Farming Wheat"), mark `SmartObjects`, and create tutorial guides.
* **Chatter**
    A modern, lightweight chat formatting plugin that supports MiniMessage. It fills the gap left by removing CMI/EssentialsX and allows for clean, permission-based chat formats for players and Personas.

## Administration & Web

* **Spark**
    A non-negotiable tool for performance profiling. With a complex AI system like Nerrus, being able to diagnose tick-rate issues or high memory usage is critical.
* **BlueMap**
    The web map that provides the "window" into our simulated world. Its integration with HuskClaims is seamless, and we will build a custom Nerrus addon to display Personas and their live statuses.
* **TAB**
    A powerful and highly configurable plugin for managing the player list (tab) and scoreboards. This is a key UI component for displaying server-wide economic data, Persona population, and other vital stats.
* **DriveBackupV2**
    An essential operational plugin for server safety. It will automatically create and upload backups of our world, plugin configurations, and Persona data to a cloud service, protecting against data loss.
