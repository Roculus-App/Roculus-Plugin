--!strict
--[=[
	Plugin-side configuration.

	`apiBase` is the Roculus backend URL. The plugin uses it for:
	  - Token validation (POST to /api/v1/bridge/hello with the pasted token)
	  - Linking to the dashboard's /settings/integrations/bridge page

	`runtimeVersion` is bumped per plugin release. The plugin embeds a copy
	of the SDK runtime at build time (via Rojo's `../runtime/src` mount); the
	version recorded here is written into ServerScriptService.RoculusBridge
	as an Attribute at install time so the Inspector can tell if an existing
	install is older than this plugin's embedded version.
]=]

local Config = {}

-- 2026-05-27 — staging-first by default. Caddy on the VPS fronts both
-- the FastAPI backend and the built Vite frontend under the same host
-- (`https://staging.roculus.dev`), so a single URL covers both. For
-- local Studio testing against an in-tree backend, swap these two
-- literals to `http://127.0.0.1:8000` and `http://localhost:8888` —
-- no env machinery yet; the plugin runs in Studio with no env access.
-- A Settings dropdown lets you flip at runtime is queued for v2.
Config.apiBase = "https://staging.roculus.dev"
Config.dashboardUrl = "https://staging.roculus.dev"
-- 2026-06-01 — bumped 0.1.0 → 0.2.0 in LOCKSTEP with the embedded runtime
-- (runtime/src/init.lua `bridgeVersion`). These two were MISSED in the first
-- 0.2.0 bump, so the plugin kept identifying as 0.1.0 no matter how often it was
-- rebuilt or rechecked — and the dashboard "outdated runtime" banner could never
-- clear. Keep all three in sync on every release: this file, init.lua, and the
-- backend's BRIDGE_PLUGIN_LATEST_VERSION.
Config.runtimeVersion = "0.2.0"
Config.pluginVersion = "0.2.0"

-- Where in the customer's game the runtime gets installed.
-- ServerScriptService is the standard, isolated, server-only location.
Config.installParentPath = "ServerScriptService"
Config.installModuleName = "RoculusBridge"
Config.bootstrapScriptName = "RoculusBridgeBootstrap"

-- The dashboard deep-link the plugin shows + copies so the user can grab a
-- token. Built in ONE place so the plugin pane (the visible URL field) and
-- Main's copy-to-clipboard never drift.
function Config.dashboardTokenUrl(placeId: number): string
	return string.format("%s/settings/places?place_id=%d&from=plugin", Config.dashboardUrl, placeId)
end

return Config
