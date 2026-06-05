--!strict
--[=[
	RoculusBridge — runtime SDK that runs inside customer games.

	This is the entry module. Customers `require()` this from a script in
	`ServerScriptService`, call `:start({...})` once with their per-place
	token, and the Bridge takes care of:

	  1. First-run validation (HttpService.HttpEnabled? chat version?)
	  2. Hello handshake → backend learns about this place + server
	  3. Continuous heartbeat (every 5s) with roster + chat tail + uptime
	  4. Long-poll for incoming commands (Kick / Mute / Warn / etc.)
	  5. Command execution + result reporting
	  6. External action reporting API (`Roculus:reportAction({...})`)
	  7. Player snapshot API for moderator investigation
	  8. Custom command registration API (`Roculus:registerCommand(...)`)

	Public surface — what customers actually call:

	  Roculus:start({ token, apiBase })                  REQUIRED
	  Roculus:registerCommand(name, handler)             optional
	  Roculus:exposeToDashboard(name)                    optional
	  Roculus:registerPlayerSnapshot(fn)                 optional
	  Roculus:registerVipServerLink(linkCode)            optional
	  Roculus:reportAction({...})                        optional (anti-cheat hook)
	  Roculus:stop()                                     optional (graceful shutdown)

	Spec source: _Project_Brain/Moderation/BRIDGE_PLAN.md (locked 2026-05-19)
	             _Project_Brain/Moderation/BRIDGE_PLAN_SIMPLE.md (addendum 2026-05-20)
]=]

-- ─────────────────────────────────────────────────────────────────────
-- Module table + state
-- ─────────────────────────────────────────────────────────────────────

local Roculus = {}
Roculus.__index = Roculus

--[=[
	@within RoculusBridge

	Internal state. Customers should not touch this directly — read via
	the public API. Listed here so the rest of this file (and the test
	suite) has one place to discover what's tracked.
]=]
local state: {
	started: boolean,
	stopping: boolean,
	-- Post mig 0048 (2026-05-27): split refresh/access tokens.
	-- `refreshToken` is the long-lived `rcr_…` value the customer pastes
	-- into config — we hold it for the lifetime of the server so the
	-- background refresh loop can mint successors. `accessToken` is the
	-- short-lived `rca_…` bearer Http.lua puts on every Bridge request.
	-- Util/Http.lua reads `state.accessToken` directly.
	refreshToken: string?,
	accessToken: string?,
	accessTokenExpiresAtUnix: number?,
	-- Version handshake returned by /auth/exchange. If the running
	-- SDK is below minPluginVersion we refuse to start; if it's below
	-- latestPluginVersion we log a soft "update available" notice.
	minPluginVersion: string?,
	latestPluginVersion: string?,
	-- Auth refresh loop control. `authLoopVersion` lets a freshly-started
	-- loop signal any still-running prior loop body to exit (defends against
	-- rapid stop/start sequences spawning two concurrent loops).
	authLoopRunning: boolean,
	authLoopVersion: number,
	apiBase: string?,
	bridgeVersion: string,
	chatVersion: string?,
	customCommands: { [string]: (Player, { [string]: any }) -> any },
	dashboardExposed: { [string]: boolean },
	snapshotFn: ((Player) -> { [string]: any })?,
	vipServerLinkCode: string?,
	-- Sub-modules attached after start (lazily required to keep require-graph clean)
	auth: any?,
	bootstrap: any?,
	heartbeat: any?,
	commandPoller: any?,
	reporter: any?,
	logger: any?,
	warnChannel: any?,
	broadcastBus: any?,
} = {
	started = false,
	stopping = false,
	refreshToken = nil,
	accessToken = nil,
	accessTokenExpiresAtUnix = nil,
	minPluginVersion = nil,
	latestPluginVersion = nil,
	authLoopRunning = false,
	authLoopVersion = 0,
	apiBase = nil,
	bridgeVersion = "0.2.0", -- bumped per release tag. 2026-06-01: 0.1.0→0.2.0
	-- marks the June-1 runtime (warn-modal redesign, announce TextService filter,
	-- shutdown delay+message, max_players heartbeat, logo). Bump on EVERY runtime
	-- change so the dashboard version-skew badge tells old from new. Keep in
	-- lockstep with backend config.BRIDGE_PLUGIN_LATEST_VERSION.
	chatVersion = nil,
	customCommands = {},
	dashboardExposed = {},
	snapshotFn = nil,
	vipServerLinkCode = nil,
	auth = nil,
	bootstrap = nil,
	heartbeat = nil,
	commandPoller = nil,
	reporter = nil,
	logger = nil,
	warnChannel = nil,
	broadcastBus = nil,
}

-- Visible to tests via `_G.__roculusState` ONLY in non-production builds.
-- Real builds strip this; for now we leave it accessible for the test suite.
_G.__roculusState = state

-- ─────────────────────────────────────────────────────────────────────
-- Public API — :start (the only required call)
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Bootstrap the Bridge. Call this exactly once from a server script in
	`ServerScriptService`. Idempotent — re-calling logs a warning and
	returns without re-initialising.

	@param config { token: string, apiBase: string, debug: boolean? }
		`token`   — per-place secret from the Roculus dashboard
		`apiBase` — backend URL, e.g. "https://api.roculus.example.com"
		`debug`   — optional, default false. Verbose Output panel logging.

	@error "token must be a non-empty string" — config.token missing
	@error "apiBase must be a non-empty string" — config.apiBase missing
	@error "HttpService.HttpEnabled is false" — game setting, customer must enable

	@return true on successful boot, false (+ logged reason) on failure.
]=]
function Roculus:start(config: { token: string, apiBase: string, debug: boolean? }): boolean
	assert(type(config) == "table", "Roculus:start expects a config table")
	assert(type(config.token) == "string" and #config.token > 0,
		"token must be a non-empty string")
	assert(type(config.apiBase) == "string" and #config.apiBase > 0,
		"apiBase must be a non-empty string")

	if state.started then
		warn("[Roculus] start() called twice — ignoring second call")
		return false
	end

	-- Lazily require sub-modules so tests can stub them by replacing
	-- script.Parent's children before requiring this entry module.
	state.logger        = require(script.Util.Logger)
	state.auth          = require(script.Core.Auth)
	state.bootstrap     = require(script.Core.Bootstrap)
	state.heartbeat     = require(script.Core.Heartbeat)
	state.commandPoller = require(script.Core.CommandPoller)
	state.reporter      = require(script.Core.Reporter)
	state.warnChannel   = require(script.Core.WarnChannel)
	state.broadcastBus  = require(script.Core.BroadcastBus)

	-- Post mig 0048: config.token is now the long-lived REFRESH token
	-- (`rcr_…`). The SDK trades it for a short-lived access token via
	-- /auth/exchange before any other backend call. The customer-facing
	-- config field stays named `token` so the bootstrap snippet they
	-- pasted years ago still parses.
	state.refreshToken = config.token
	state.apiBase = config.apiBase:gsub("/$", "") -- strip trailing slash for clean joins
	state.logger.setDebug(config.debug == true)

	local logger = state.logger
	logger.info("Roculus Bridge v" .. state.bridgeVersion .. " starting")

	-- Step 1 — exchange refresh for access. Runs BEFORE Bootstrap.run
	-- because hello/heartbeat/etc. all require X-Roculus-Token, which
	-- Http.lua reads from state.accessToken.
	local authOk, authErr = state.auth.exchange(state)
	if not authOk then
		logger.error("Bridge failed to start: " .. tostring(authErr))
		return false
	end

	-- Step 1b — soft version gate. If our installed SDK is older than
	-- the server's `min_plugin_version`, refuse to start so we don't
	-- send malformed requests against a changed contract. The version
	-- comparison is string-lexical for now (matches semver-ish "0.1.0"
	-- shape we're using); revisit if we ever introduce two-digit minors.
	if state.minPluginVersion and state.bridgeVersion < state.minPluginVersion then
		logger.error(string.format(
			"SDK v%s is below the server's required minimum (v%s). Update Roculus_Bridge/runtime/ from the repo and re-deploy.",
			state.bridgeVersion, state.minPluginVersion
		))
		return false
	end
	if state.latestPluginVersion and state.bridgeVersion < state.latestPluginVersion then
		logger.info(string.format(
			"Update available — running v%s, latest is v%s.",
			state.bridgeVersion, state.latestPluginVersion
		))
	end

	-- Step 2 — boot sequence: HttpEnabled check, chat version detection,
	-- hello handshake. Hello now bears the access token so the backend
	-- can attribute the place + server to the right project.
	local ok, err = state.bootstrap.run(state)
	if not ok then
		logger.error("Bridge failed to start: " .. tostring(err))
		return false
	end

	state.started = true

	-- Step 3 — background refresh loop. Mints a successor access token
	-- ~60s before the current one expires so heartbeat never 401s.
	state.auth.startRefreshLoop(state)

	-- Companion subsystems — must come BEFORE the command poller starts
	-- so the first incoming command finds them ready.
	-- WarnChannel sets up the RemoteEvent + clones the client toast script
	-- into each player's PlayerGui.
	state.warnChannel.start(state)
	-- BroadcastBus subscribes to the MessagingService topic so incoming
	-- cross-server broadcasts route through the local Announce path.
	state.broadcastBus.start(state)
	state.broadcastBus.registerHandler("announce", function(payload)
		-- A peer Bridge published a universe-wide announce. Run it locally.
		local Announce = require(script.Commands.Announce)
		Announce(state, payload or {})
	end)

	logger.info("Bridge ready — heartbeat + command poller running")

	-- Heartbeat loop (every 5s) + command poller loop (long-poll 30-60s).
	-- Each runs in its own task.spawn so they don't block the start call.
	-- #111 — arm the moderator "Join flagged server" handler. Reads the signed
	-- launchData a moderator's launch link carried and teleports them to the
	-- exact target JobId (verified backend-side). After auth so accessToken ready.
	local JoinTeleport = require(script.Core.JoinTeleport)
	JoinTeleport.start(state)

	state.heartbeat.startLoop(state)
	state.commandPoller.startLoop(state)

	-- 2026-05-20 — auto-stop on game shutdown.
	--
	-- Without this, customers who forget to call Roculus:stop() in their own
	-- BindToClose handler leave the dashboard guessing — heartbeats simply
	-- stop coming and the server flips to "Bridge offline" after ~15-60s.
	-- Auto-binding ensures every clean shutdown sends `stopping=true` so the
	-- dashboard renders "cleanly stopped" instead of "not responding."
	-- Idempotent: stop() guards against double-calls.
	game:BindToClose(function()
		Roculus:stop()
	end)

	return true
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API — :stop (graceful shutdown)
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Graceful shutdown. Stops the heartbeat + command poller loops, sends
	a final "bridge.stopping" heartbeat so the dashboard shows the server
	as cleanly offline (not "Bridge not responding"). Safe to call from
	`game:BindToClose(...)`.

	Calling stop() before start() is a no-op.
]=]
function Roculus:stop(): ()
	if not state.started or state.stopping then
		return
	end
	state.stopping = true
	if state.logger then
		state.logger.info("Bridge stopping (graceful)")
	end

	-- Best-effort final heartbeat — fire-and-forget, don't block on
	-- the shutdown handler past whatever budget the caller gave us.
	if state.heartbeat then
		state.heartbeat.stop(state)
	end
	if state.commandPoller then
		state.commandPoller.stop(state)
	end

	-- Post mig 0048: stop the auth refresh loop AND revoke the active
	-- access token. Revoke is fire-and-forget so it doesn't block the
	-- shutdown budget; if it fails the access token will expire
	-- naturally within ~15 min anyway.
	if state.auth then
		state.auth.stopRefreshLoop(state)
		state.auth.revokeAccess(state)
	end

	state.started = false
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API — custom commands (dev extension hook)
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Register a dev-defined command that the Bridge will execute when the
	dashboard dispatches it. By default the command is NOT visible in the
	dashboard's actions menu — devs must explicitly opt in via
	`Roculus:exposeToDashboard(name)`. This prevents accidentally exposing
	money-flow commands (e.g. `givePass`) to moderators.

	@param name string — command name, lowercase + dot-separated by convention
	@param handler function(player, args) — runs server-side with full game access
]=]
function Roculus:registerCommand(name: string, handler: (Player, { [string]: any }) -> any): ()
	assert(type(name) == "string" and #name > 0, "command name required")
	assert(type(handler) == "function", "handler must be a function")
	if state.customCommands[name] then
		warn(string.format("[Roculus] Overwriting existing command '%s'", name))
	end
	state.customCommands[name] = handler
end

--[=[
	@within RoculusBridge

	Opt-in: make a registered custom command appear in the dashboard's
	actions menu. Required before moderators can invoke the command from
	the dashboard. Calling this on an unregistered command is a no-op
	with a warning.
]=]
function Roculus:exposeToDashboard(name: string): ()
	if not state.customCommands[name] then
		warn(string.format("[Roculus] Cannot expose '%s' — not registered. Call registerCommand first.", name))
		return
	end
	state.dashboardExposed[name] = true
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API — player snapshot (per-player investigation hook)
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Register a function that returns a curated snapshot of a player's
	session for moderator investigation. The Bridge calls this when the
	dashboard requests `player.snapshot` for a specific user. If no
	function is registered, the Bridge falls back to a default snapshot
	(identity, position, leaderstats, attributes).

	Use `<redacted>` as a value for fields you want to hide:
	  `{ password = "<redacted>" }`  — dashboard renders as collapsed.

	@param fn function(player) -> dict of fields to include in the snapshot
]=]
function Roculus:registerPlayerSnapshot(fn: (Player) -> { [string]: any }): ()
	assert(type(fn) == "function", "snapshot fn must be a function")
	state.snapshotFn = fn
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API — VIP server link code
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Register a VIP server link code so moderators can auto-join private
	servers from the dashboard. Without this, the dashboard's Join Server
	button shows a "private — needs invite" warning instead of a direct
	join link. Optional; only relevant for games using private/VIP servers.

	@param linkCode string — the code from the VIP server URL
]=]
function Roculus:registerVipServerLink(linkCode: string): ()
	assert(type(linkCode) == "string" and #linkCode > 0, "linkCode required")
	state.vipServerLinkCode = linkCode
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API — :reportAction (anti-cheat / external event hook)
-- ─────────────────────────────────────────────────────────────────────

--[=[
	@within RoculusBridge

	Report an action that the game itself took (anti-cheat kick, admin
	script ban, etc.) so it appears in the dashboard's audit log alongside
	manual moderator actions. Bridge wraps this into an HTTP POST to
	`POST /api/audit/external` — fire-and-forget, doesn't block.

	@param report {
		kind: string,           -- "kick" | "ban" | "mute" | "warn" | "anticheat.flag" | custom
		player: Player | { user_id: number },
		reason: string,
		evidence: { [string]: any }?,
		source: string?,        -- defaults to "custom"; convention: "anti_cheat" | "admin_script"
		source_detail: string?, -- optional sub-identifier (e.g. "speed_check_v2")
	}

	No error is raised on network failure — Bridge logs locally and moves
	on. We can't help if the dashboard is offline; the in-game action
	already happened.
]=]
function Roculus:reportAction(report: {
	kind: string,
	player: any,
	reason: string,
	evidence: { [string]: any }?,
	source: string?,
	source_detail: string?,
}): ()
	if not state.started then
		warn("[Roculus] reportAction called before start() — dropping")
		return
	end
	assert(type(report) == "table", "reportAction expects a table")
	assert(type(report.kind) == "string", "report.kind required")
	assert(type(report.reason) == "string", "report.reason required")
	state.reporter.send(state, report)
end

-- ─────────────────────────────────────────────────────────────────────
-- Module return
-- ─────────────────────────────────────────────────────────────────────

return Roculus
