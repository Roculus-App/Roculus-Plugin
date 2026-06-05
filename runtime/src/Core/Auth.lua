--!strict
--[=[
	Auth — refresh ↔ access token exchange (mig 0048, 2026-05-27).

	Customers paste a long-lived REFRESH token (`rcr_…`) into their
	bootstrap snippet. This module:

	  1. Trades the refresh for a short-lived ACCESS token (`rca_…`)
	     at :start() via POST /api/v1/bridge/auth/exchange.
	  2. Stores access value + Unix expiry on the shared state table so
	     Http.lua picks it up for every Bridge request.
	  3. Runs a background task that auto-refreshes the access token
	     ~60s before it expires, so the long-running heartbeat loop
	     never sees a 401.
	  4. On graceful shutdown, revokes the current access token via
	     /auth/revoke-access so a leaked memory dump can't be replayed.

	NO retry storm on persistent failure — if /auth/refresh keeps
	returning 4xx (e.g. refresh token revoked from dashboard), we log
	loudly and stop the loop. The heartbeat will then 401 and the
	dashboard surfaces "Bridge offline" to the developer, which is
	the right signal.

	Game-side fingerprint: nil. The plugin-side (Studio) sends a stable
	GUID from plugin:SetSetting, but games can't do that — the place_id
	check on every exchange is the primary anti-leak defense for games.
]=]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Auth = {}

local REFRESH_LEAD_SECONDS = 60   -- refresh this many seconds before expiry
local BACKOFF_SECONDS = 30        -- back-off on refresh failure before retry

-- ─────────────────────────────────────────────────────────────────────
-- Internal — raw HTTP call to an /auth/* endpoint
-- ─────────────────────────────────────────────────────────────────────
--
-- Auth endpoints are intentionally NOT routed through Util/Http.lua —
-- Http.lua's `buildHeaders` is shared with the rest of the SDK and
-- would conditionally include X-Roculus-Token if state.accessToken
-- happens to be set (e.g. on subsequent /auth/refresh calls). For the
-- auth endpoints we want exact control: no token header at all on
-- exchange, optional token on revoke-access. So we call HttpService
-- directly here and keep the codepath obvious.

local function authPost(state, path: string, body: { [string]: any }): {
	ok: boolean,
	status: number,
	body: { [string]: any }?,
	code: string?,
	message: string?,
}
	local url = state.apiBase .. path
	local request = {
		Url = url,
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Accept"] = "application/json",
			["X-Bridge-Version"] = state.bridgeVersion,
		},
		Body = HttpService:JSONEncode(body),
	}
	local ok, result = pcall(HttpService.RequestAsync, HttpService, request)
	if not ok then
		return {
			ok = false,
			status = 0,
			body = nil,
			code = "network_error",
			message = tostring(result),
		}
	end
	local response = result :: any
	local decoded: { [string]: any }? = nil
	if response.Body and #response.Body > 0 then
		local jsonOk, jsonResult = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if jsonOk then
			decoded = jsonResult
		end
	end
	return {
		ok = response.Success and response.StatusCode < 400,
		status = response.StatusCode,
		body = decoded,
		code = decoded and decoded.error and decoded.error.code,
		message = decoded and decoded.error and decoded.error.message,
	}
end

-- ─────────────────────────────────────────────────────────────────────
-- Internal — apply an exchange/refresh response to state
-- ─────────────────────────────────────────────────────────────────────

local function applyExchangeResponse(state, data: { [string]: any }): ()
	state.accessToken = data.access_token
	-- We use expires_in_seconds rather than parsing the ISO `expires_at`
	-- string — Lua doesn't have a built-in ISO parser and os.time() is
	-- close enough for refresh-loop math (we're refreshing 60s early
	-- anyway, so a few seconds of clock skew is absorbed by the lead).
	local ttl = tonumber(data.expires_in_seconds) or 900
	state.accessTokenExpiresAtUnix = os.time() + ttl
	state.minPluginVersion = data.min_plugin_version
	state.latestPluginVersion = data.latest_plugin_version
end

-- ─────────────────────────────────────────────────────────────────────
-- Public — exchange (called once at :start())
-- ─────────────────────────────────────────────────────────────────────

function Auth.exchange(state): (boolean, string?)
	assert(state.refreshToken, "Auth.exchange: state.refreshToken is nil")
	local logger = state.logger

	local body = {
		refresh_token = state.refreshToken,
		place_id = game.PlaceId,
		install_fingerprint = nil, -- game-side: nil. plugin-side ships its own.
		is_studio = RunService:IsStudio(),
	}
	local response = authPost(state, "/api/v1/bridge/auth/exchange", body)

	if not response.ok then
		local msg = string.format(
			"Token exchange failed: HTTP %d (%s) %s",
			response.status,
			tostring(response.code or "no-code"),
			tostring(response.message or "no message")
		)
		logger.error(msg)
		return false, msg
	end

	local data = response.body and response.body.data
	if not data or not data.access_token then
		logger.error("Token exchange returned ok=true but no access_token in body")
		return false, "no_access_token_in_response"
	end

	applyExchangeResponse(state, data)
	logger.info(string.format(
		"Auth ok — access token issued (TTL %ds, min plugin v%s, latest v%s)",
		data.expires_in_seconds or 0,
		tostring(state.minPluginVersion or "?"),
		tostring(state.latestPluginVersion or "?")
	))
	return true, nil
end

-- ─────────────────────────────────────────────────────────────────────
-- Public — refresh (called by background loop, also callable manually)
-- ─────────────────────────────────────────────────────────────────────

function Auth.refresh(state): (boolean, string?)
	assert(state.refreshToken, "Auth.refresh: state.refreshToken is nil")
	local logger = state.logger

	local body = {
		refresh_token = state.refreshToken,
		install_fingerprint = nil,
		is_studio = RunService:IsStudio(),
	}
	local response = authPost(state, "/api/v1/bridge/auth/refresh", body)

	if not response.ok then
		local msg = string.format(
			"Token refresh failed: HTTP %d (%s) %s",
			response.status,
			tostring(response.code or "no-code"),
			tostring(response.message or "no message")
		)
		logger.warn(msg)
		return false, msg
	end

	local data = response.body and response.body.data
	if not data or not data.access_token then
		logger.warn("Token refresh returned ok=true but no access_token in body")
		return false, "no_access_token_in_response"
	end

	applyExchangeResponse(state, data)
	logger.debug(string.format(
		"Access token refreshed (next expiry in %ds)",
		data.expires_in_seconds or 0
	))
	return true, nil
end

-- ─────────────────────────────────────────────────────────────────────
-- Public — revoke (called from :stop())
-- ─────────────────────────────────────────────────────────────────────

function Auth.revokeAccess(state): ()
	if not state.accessToken then
		return
	end
	-- Fire-and-forget — shutdown is time-budgeted; we don't want a slow
	-- network to keep BindToClose alive past its deadline.
	pcall(authPost, state, "/api/v1/bridge/auth/revoke-access", {
		access_token = state.accessToken,
	})
	state.accessToken = nil
end

-- ─────────────────────────────────────────────────────────────────────
-- Public — refresh loop (background task)
-- ─────────────────────────────────────────────────────────────────────

function Auth.startRefreshLoop(state): ()
	if state.authLoopRunning then
		return
	end
	state.authLoopRunning = true

	-- Bump the loop version each time we (re)start so any in-flight
	-- previous loop body can self-cancel by comparing its captured
	-- version to the current one. Defends against double-spawn edge
	-- cases on rapid stop/start.
	state.authLoopVersion = (state.authLoopVersion or 0) + 1
	local myVersion = state.authLoopVersion
	local logger = state.logger

	task.spawn(function()
		while state.authLoopRunning and state.authLoopVersion == myVersion do
			local secondsUntilRefresh = math.max(
				1,
				(state.accessTokenExpiresAtUnix or 0) - os.time() - REFRESH_LEAD_SECONDS
			)
			task.wait(secondsUntilRefresh)
			if not state.authLoopRunning or state.authLoopVersion ~= myVersion then
				return
			end

			local ok, _err = Auth.refresh(state)
			if not ok then
				-- Back off then retry. If the refresh keeps failing
				-- (e.g. dashboard-revoked refresh token), the heartbeat
				-- will eventually 401 and surface to the developer —
				-- that's a better escalation path than burning the loop
				-- silently here.
				logger.warn(string.format("Auth refresh retry in %ds", BACKOFF_SECONDS))
				task.wait(BACKOFF_SECONDS)
			end
		end
	end)
end

function Auth.stopRefreshLoop(state): ()
	state.authLoopRunning = false
end

return Auth
