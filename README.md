# Roculus Bridge

The Roculus Bridge is the Roblox Studio **plugin** + in-game **runtime** that
connects your experience to the [Roculus](https://roculus.dev) moderation
dashboard — so your team can moderate live games from the web.

> **Source-available.** This repository is published so studios can read and
> verify exactly what runs in their game before installing — and build the
> plugin themselves to confirm it matches the Creator Store version.

## What it does

From the Roculus dashboard, once the Bridge is installed, your team can:

- See who's in each live server in real time
- **Kick, mute, warn, announce,** and **shut down** servers
- Log actions from your own anti-cheat into the moderation audit trail

Without the Bridge, the dashboard's live moderation actions are inert. The Bridge
is what makes in-game moderation possible.

## Install

### Option 1 — Creator Store (recommended)
Install from the Roblox Creator Store:
**https://create.roblox.com/store/asset/127499489618942**
When a new version ships, Studio shows an **Update** button next to the installed
plugin in **Plugins → Manage Plugins** — one click to update. (Roblox plugins
don't update silently on their own.)

### Option 2 — From source (for studios who want to audit first)
1. Download `RoculusBridgePlugin.rbxmx` from [Releases](../../releases), **or**
   build it yourself (see below).
2. Drag it into Studio and use **Plugins → Save as Local Plugin**, or drop it in
   your local Roblox `Plugins` folder.

A locally-installed file does **not** auto-update — replace it by hand on a new release.

## Permissions it requests (and why)

When you install the Bridge, Roblox asks you to allow:

- **HTTP Requests** — to exchange moderation commands between your game and the
  Roculus backend.
- **Script insertion** — once, at setup, to install the Bridge runtime into your
  game's `ServerScriptService` so the published game can run it.

Your per-place token lives only inside your own place file and is never shared.

## How it works

- **`plugin/`** — the Studio plugin: connect (paste your place token) and install
  the runtime into `ServerScriptService`.
- **`runtime/`** — the in-game SDK that runs in your published game: heartbeats,
  command polling, and the moderation verbs.

The plugin **bundles** the runtime, so what you audit here is exactly what gets
installed in your game.

## Build from source

Requires [Rojo](https://rojo.space/) (this project is built with 7.5.1):

```bash
rojo build plugin/default.project.json -o RoculusBridgePlugin.rbxmx
```

The output `.rbxmx` is the complete plugin — UI plus the embedded runtime.

## Updating your game

Updating the plugin updates the **plugin**. To get a new in-game runtime into a
*published* game you must **re-pair** in the plugin and then **republish your
place** — Roblox does not hot-swap scripts in a live game.

## Repository layout

```
plugin/        Studio plugin source (UI, auth, installer) + vendored Roact
runtime/       In-game SDK (the code that runs in your game)
dev/           Local-dev Rojo bootstrap (example only — contains no tokens)
tests/         Test specs
```

## Security

Found a vulnerability? Please report it **privately** — see [SECURITY.md](SECURITY.md).
Don't open a public issue for security problems.

## Contributing

This is a **source-available mirror** for transparency and auditing. **Issues are
welcome**, but outside pull requests aren't accepted — releases are cut by the
Roculus team. You're free to fork under the license below.

## License

[MIT](LICENSE.txt). Vendored Roact (`plugin/vendor/Roact`) is © Roblox under its
own license.
