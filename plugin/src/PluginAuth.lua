--!strict
--[=[
	Plugin-side auth controller.

	Bridges PluginPane click handlers to the runtime SDK's Auth module.
	The runtime SDK lives at script.Parent.EmbeddedRuntime (vendored into
	the plugin via the rojo project tree).

	Why we don't just use Roculus:start():
	  The runtime's :start() also spins up heartbeat + command poller +
	  player snapshot etc. — which only makes sense from inside a running
	  game. The plugin only needs the auth half: exchange the refresh,
	  hold the access token in memory, refresh it before expiry, revoke
	  on disconnect.

	Token storage:
	  Refresh token persists across Studio sessions via plugin:SetSetting.
	  Access tokens are RAM only (and auto-refreshed before expiry).

	IMPORTANT — install_fingerprint:
	  Plugin minted on first install, persisted in plugin:SetSetting under
	  "install_fingerprint". On every exchange we send it so the backend
	  can alert on the same refresh being used from a different install.
]=]

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)
local State = require(script.Parent.State)
local Installer = require(script.Parent.Installer)
local Auth = require(script.Parent.EmbeddedRuntime.Core.Auth)
local Logger = require(script.Parent.EmbeddedRuntime.Util.Logger)

local PluginAuth = {}

-- ─────────────────────────────────────────────────────────────────────
-- Semver compare — replaces the string `<` that read "0.10.0" as OLDER
-- than "0.9.0". Unparseable input -> false (never nag on a bad version).
-- ─────────────────────────────────────────────────────────────────────
local function parseSemver(v: string?): { number }?
	if type(v) ~= "string" then return nil end
	local nums: { number } = {}
	for part in string.gmatch(v, "%d+") do
		table.insert(nums, tonumber(part) or 0)
		if #nums >= 3 then break end
	end
	if #nums == 0 then return nil end
	while #nums < 3 do table.insert(nums, 0) end
	return nums
end

local function versionLt(a: string?, b: string?): boolean
	local pa, pb = parseSemver(a), parseSemver(b)
	if not pa or not pb then return false end
	for i = 1, 3 do
		if pa[i] ~= pb[i] then return pa[i] < pb[i] end
	end
	return false
end

local SETTING_REFRESH_TOKEN = "roculus.refreshToken"
local SETTING_INSTALL_FINGERPRINT = "roculus.installFingerprint"

local pluginRef: Plugin? = nil  -- set via PluginAuth.bind(plugin, …)
-- The plugin tree's EmbeddedRuntime instance — set by bind() and handed
-- to the Installer when we copy the SDK into ServerScriptService.
local embeddedRuntimeRef: Instance? = nil

-- The runtime SDK's Auth module expects a `state` table with these fields.
-- We construct one here and keep it private to PluginAuth — components only
-- ever see State.lua (the plugin-side UI state), never this auth state.
local authState: { [string]: any } = {
	logger = Logger,
	refreshToken = nil,
	apiBase = Config.apiBase or "http://localhost:8000",
	bridgeVersion = Config.runtimeVersion or "0.1.0",
	accessToken = nil,
	accessTokenExpiresAtUnix = nil,
	authLoopRunning = false,
	authLoopVersion = 0,
	minPluginVersion = nil,
	latestPluginVersion = nil,
}

-- ─────────────────────────────────────────────────────────────────────
-- Install-fingerprint helpers
-- ─────────────────────────────────────────────────────────────────────

local function ensureInstallFingerprint(): string
	assert(pluginRef, "PluginAuth.bind not called")
	local existing = pluginRef:GetSetting(SETTING_INSTALL_FINGERPRINT)
	if type(existing) == "string" and #existing > 0 then
		return existing
	end
	local fp = HttpService:GenerateGUID(false)
	pluginRef:SetSetting(SETTING_INSTALL_FINGERPRINT, fp)
	return fp
end

-- Monkey-patch Auth's exchange/refresh to inject our fingerprint into the
-- body. The runtime SDK sends nil for game-side; the plugin-side has a
-- real install identity stored in plugin:SetSetting. We override the
-- HTTP call shape by wrapping the call here instead of modifying Auth.lua.
local function exchangeWithFingerprint(): (boolean, string?)
	local fp = ensureInstallFingerprint()
	local origExchange = Auth.exchange
	-- Auth.lua uses an internal authPost helper that bakes install_fingerprint
	-- from a hardcoded `nil`. Cleanest workaround: temporarily stash the
	-- fingerprint on authState and use a small wrapper that overrides the
	-- body via a monkey-patch on the Auth module. Since Auth's authPost is
	-- file-local we can't see it from here — call the real HTTP endpoint
	-- ourselves with the right body shape.
	return PluginAuth._exchangeRaw(fp)
end

-- ─────────────────────────────────────────────────────────────────────
-- Raw HTTP — mirrors Auth.lua's authPost but injects install_fingerprint
-- ─────────────────────────────────────────────────────────────────────

local function authPost(path: string, body: { [string]: any }): {
	ok: boolean,
	status: number,
	body: { [string]: any }?,
	code: string?,
	message: string?,
}
	local request = {
		Url = authState.apiBase .. path,
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Accept"] = "application/json",
			["X-Bridge-Version"] = authState.bridgeVersion,
		},
		Body = HttpService:JSONEncode(body),
	}
	local ok, result = pcall(HttpService.RequestAsync, HttpService, request)
	if not ok then
		return { ok = false, status = 0, body = nil, code = "network_error", message = tostring(result) }
	end
	local response = result :: any
	local decoded: { [string]: any }? = nil
	if response.Body and #response.Body > 0 then
		local jsonOk, jsonResult = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if jsonOk then decoded = jsonResult end
	end
	return {
		ok = response.Success and response.StatusCode < 400,
		status = response.StatusCode,
		body = decoded,
		code = decoded and decoded.error and decoded.error.code,
		message = decoded and decoded.error and decoded.error.message,
	}
end

-- GET helper — for the public /bridge/latest version poll (no auth / no body).
local function authGet(path: string): { ok: boolean, status: number, body: { [string]: any }? }
	local ok, result = pcall(HttpService.RequestAsync, HttpService, {
		Url = authState.apiBase .. path,
		Method = "GET",
		Headers = { ["Accept"] = "application/json" },
	})
	if not ok then
		return { ok = false, status = 0, body = nil }
	end
	local response = result :: any
	local decoded: { [string]: any }? = nil
	if response.Body and #response.Body > 0 then
		local jsonOk, jsonResult = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if jsonOk then decoded = jsonResult end
	end
	return {
		ok = response.Success and response.StatusCode < 400,
		status = response.StatusCode,
		body = decoded,
	}
end

function PluginAuth._exchangeRaw(installFingerprint: string?): (boolean, string?)
	local body = {
		refresh_token = authState.refreshToken,
		place_id = game.PlaceId,
		install_fingerprint = installFingerprint,
		is_studio = true,
	}
	local response = authPost("/api/v1/bridge/auth/exchange", body)

	if not response.ok then
		-- Map backend error codes to UI error variants the State module knows.
		if response.status == 0 then
			-- Network failure — could be HttpService disabled or backend down.
			-- We don't distinguish here; the http_disabled state is for the
			-- specific "HttpService.HttpEnabled = false" case which fires a
			-- different pcall error. For now treat as auth error.
			return false, response.message or "network_error"
		end
		return false, response.code or "exchange_failed"
	end

	local data = response.body and response.body.data
	if not data or not data.access_token then
		return false, "no_access_token_in_response"
	end

	authState.accessToken = data.access_token
	authState.accessTokenExpiresAtUnix = os.time() + (tonumber(data.expires_in_seconds) or 900)
	authState.minPluginVersion = data.min_plugin_version
	authState.latestPluginVersion = data.latest_plugin_version
	return true, nil
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────

function PluginAuth.bind(p: Plugin, embeddedRuntime: Instance): ()
	pluginRef = p
	embeddedRuntimeRef = embeddedRuntime
end

-- Poll the backend for the latest published version + update the "update
-- available" flag LIVE. Called on plugin load + on a slow loop (Main), not
-- just at token paste — so the titlebar dot lights up even if you publish a
-- new version while the dock sits open. HttpService works in the plugin
-- without the game being published. Best-effort; silent if HTTP is off.
function PluginAuth.checkLatestVersion(): ()
	local response = authGet("/api/v1/bridge/latest")
	local data = response.ok and response.body and response.body.data
	if not data then return end

	if data.latest then authState.latestPluginVersion = data.latest end
	if data.minimum then authState.minPluginVersion = data.minimum end

	local outdated = versionLt(Config.pluginVersion, authState.latestPluginVersion)
	local was = State.get().updateAvailable
	-- 2026-06-04 — also push the fetched latest version into the SHARED State so
	-- the Settings → About "Latest version" row can read it. Before this, the value
	-- lived only in PluginAuth's private authState and the UI row (which reads
	-- State.latestPluginVersion) always fell through to "—". Same class of bug as
	-- the "Plugin version" row fixed 2026-06-02.
	State.set({ updateAvailable = outdated, latestPluginVersion = authState.latestPluginVersion })
	-- Toast only on a fresh transition into outdated; the titlebar dot carries
	-- the standing signal, so we don't nag on every poll.
	if outdated and not was then
		State.fireToast(
			string.format("Bridge update available — v%s", tostring(authState.latestPluginVersion)),
			6
		)
	end
end

function PluginAuth.getStoredRefreshToken(): string?
	if not pluginRef then return nil end
	local v = pluginRef:GetSetting(SETTING_REFRESH_TOKEN)
	if type(v) == "string" and #v > 0 then
		return v
	end
	return nil
end

-- Called from the NotConnected body's Connect click handler.
-- Drives the state machine through Connecting → Confirming → Connected
-- or → Error variants on failure.
function PluginAuth.connect(refreshToken: string): ()
	assert(pluginRef, "PluginAuth.bind not called")
	-- Persist immediately — even if the exchange fails the user can edit +
	-- retry without re-pasting (the input is pre-filled from settings).
	pluginRef:SetSetting(SETTING_REFRESH_TOKEN, refreshToken)
	authState.refreshToken = refreshToken

	State.set({ status = State.STATES.CONNECTING, errorVariant = nil })

	-- Brief visual handshake. Real network usually clears in <1s; we don't
	-- artificially pad, so if the call returns fast the user sees a
	-- brief flash — that's fine, it's truthful.
	task.spawn(function()
		State.set({ status = State.STATES.CONFIRMING })

		local fp = ensureInstallFingerprint()
		local ok, errCode = PluginAuth._exchangeRaw(fp)

		if ok then
			-- Install the runtime SDK + bootstrap into ServerScriptService
			-- so the published game actually calls the Bridge at runtime.
			-- Without this, "Connected" in the plugin would be a lie — the
			-- plugin paired but the game has nothing to run.
			if embeddedRuntimeRef then
				local installOk, installErr = pcall(function()
					Installer.install(embeddedRuntimeRef, refreshToken, authState.apiBase)
				end)
				if installOk then
					State.fireToast("Bridge SDK installed in ServerScriptService")
				else
					Logger.warn("Bridge SDK install failed: " .. tostring(installErr))
					State.fireToast("Connected, but SDK install failed — see Output")
				end
			end

			-- Connected. Use the place_id from the open .rbxl as the display
			-- key; place_name would require an extra MarketplaceService call
			-- (TODO future polish).
			State.set({
				status = State.STATES.CONNECTED,
				placeId = game.PlaceId,
				placeName = "Place " .. tostring(game.PlaceId),
				lastSyncSeconds = 0,
				updateAvailable = versionLt(Config.pluginVersion, authState.latestPluginVersion),
			})
			-- Kick off auto-refresh so the connection stays live across the
			-- ~15min TTL while the dock widget is open.
			Auth.startRefreshLoop(authState)
		else
			-- Map to the right error variant. The mockup has two: generic
			-- auth failure (red "Connection failed") and HttpService disabled
			-- (red, but with the 2-step recovery list).
			local variant = "auth"
			if errCode == "network_error" then
				-- Heuristic: if HttpService.HttpEnabled is false we'd get a
				-- network_error code from the pcall. Check it now.
				if not game:GetService("HttpService").HttpEnabled then
					variant = "http_disabled"
				end
			end
			State.set({ status = State.STATES.ERROR_AUTH, errorVariant = variant })
		end
	end)
end

function PluginAuth.disconnect(): ()
	if authState.accessToken then
		-- Fire-and-forget; UI transitions immediately.
		task.spawn(function()
			pcall(authPost, "/api/v1/bridge/auth/revoke-access", {
				access_token = authState.accessToken,
			})
		end)
	end
	Auth.stopRefreshLoop(authState)
	authState.accessToken = nil
	authState.accessTokenExpiresAtUnix = nil

	-- Remove the installed SDK + bootstrap so the published game stops
	-- trying to authenticate with a token we just revoked. Re-pair will
	-- reinstall fresh.
	local uninstallOk, uninstallErr = pcall(Installer.uninstall)
	if uninstallOk then
		State.fireToast("Bridge SDK removed from ServerScriptService")
	else
		Logger.warn("Bridge SDK uninstall failed: " .. tostring(uninstallErr))
	end

	State.set({
		status = State.STATES.NOT_CONNECTED,
		placeName = State.REMOVE,
		placeId = State.REMOVE,
		errorVariant = State.REMOVE,
	})
end

-- Convenience for the debug switcher / restore-on-open flows. Returns
-- the current internal auth state for diagnostics. Not for app code.
function PluginAuth._debugState(): { [string]: any }
	return {
		hasRefresh = authState.refreshToken ~= nil,
		hasAccess = authState.accessToken ~= nil,
		expiresAt = authState.accessTokenExpiresAtUnix,
		minPluginVersion = authState.minPluginVersion,
		latestPluginVersion = authState.latestPluginVersion,
	}
end

return PluginAuth
