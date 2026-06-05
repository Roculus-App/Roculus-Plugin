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

Download **`RoculusBridgePlugin.rbxmx`** from the
**[latest release](../../releases/latest)** (or build it yourself — see below), then:

1. Drop the file into your Studio plugins folder — `%LOCALAPPDATA%/Roblox/Plugins/`
   on Windows — **or** open it in Studio and use **Plugins → Save as Local Plugin**.
2. Restart Studio. The **Roculus Bridge** button appears in the Plugins toolbar.
3. Open it and connect with the place token from your Roculus dashboard.

**Updating:** download the newer file and replace the old one — the Roculus dashboard
shows a banner when a new version is out.

> **Why a direct download and not the Creator Store?** Roculus Bridge installs as a
> file you download and review yourself, so you can read and verify every line before
> it touches your game. That auditability is the whole point of this repo.

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
