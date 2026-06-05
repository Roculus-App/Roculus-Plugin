--!strict
--[=[
	First-run validation + handshake.

	Runs once at the start of :start(). Order matters:

	  1. HttpService.HttpEnabled check — hard prerequisite. Bridge can't
	     talk to the backend without it. Halt loud if disabled — the
	     customer must fix this in game settings before the Bridge does
	     anything else.

	  2. Detect chat version — TextChatService vs Legacy Chat. Cached on
	     state so command modules can branch on it without re-detecting.

	  3. Hello handshake — POST /api/bridge/hello with:
	       - place_id  (game.PlaceId)
	       - place_version  (game.PlaceVersion)
	       - bridge_version  (state.bridgeVersion)
	       - chat_version    (legacy | TextChatService)
	       - is_studio       (RunService:IsStudio())
	       - server_id       (game.JobId, or "studio-session" if empty)
	     Backend uses this to register/refresh the place's bridge metadata.

	Returns (true, nil) on success, (false, errMessage) on any failure.
]=]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Bootstrap = {}

function Bootstrap.run(state): (boolean, string?)
	local Http = require(script.Parent.Parent.Util.Http)
	local ChatVersion = require(script.Parent.Parent.Util.ChatVersion)
	local logger = state.logger

	-- 1. HttpEnabled gate — hard prerequisite.
	if not HttpService.HttpEnabled then
		local msg = "HttpService.HttpEnabled is false — enable in Game Settings → Security"
		logger.error(msg)
		return false, msg
	end

	-- 2. Chat version detection — cache on state for command modules.
	state.chatVersion = ChatVersion.detect()
	logger.debug("Detected chat version: " .. state.chatVersion)

	-- 2b. Stable per-session server id (2026-05-20).
	--
	-- game.JobId is empty in Studio playtests, so the SDK historically used
	-- the literal "studio-session" for ALL playtests. That meant every new
	-- F5 reused the SAME bridge_servers row — including its previous
	-- chat_tail — which made testing genuinely confusing (you'd see old
	-- chat from a prior session leak into a fresh one). For real games
	-- this isn't an issue because the actual JobId is a unique GUID per
	-- server instance.
	--
	-- Fix: in Studio specifically, mint a unique GUID per :start() so each
	-- playtest gets its own server row. Cached on state so heartbeat +
	-- stop + every other call sees the same id.
	if game.JobId ~= "" then
		state.serverId = game.JobId
	else
		state.serverId = "studio-" .. HttpService:GenerateGUID(false):sub(1, 12)
	end
	logger.debug("Session server_id: " .. state.serverId)

	-- 2026-05-20 — track our own boot time for the uptime heartbeat field.
	-- `Workspace.DistributedGameTime` has been observed misbehaving in Studio
	-- (uptime jumping to "2320 days" mid-session). os.time() is plain Unix
	-- seconds, monotonic-enough for our use, and immune to whatever Studio
	-- quirk was producing the absurd values.
	state.bootTime = os.time()

	-- 3. Hello handshake — register this place + server with the backend.
	local helloBody = {
		place_id = game.PlaceId,
		place_version = game.PlaceVersion,
		bridge_version = state.bridgeVersion,
		chat_version = state.chatVersion,
		is_studio = RunService:IsStudio(),
		server_id = state.serverId,
		is_private = game.PrivateServerId ~= "",
		private_server_owner_id = game.PrivateServerOwnerId ~= 0 and game.PrivateServerOwnerId or nil,
	}

	local response = Http.request(state, "POST", "/api/v1/bridge/hello", helloBody)
	if not response.ok then
		local msg = string.format("Hello handshake failed: HTTP %d %s",
			response.status, response.message or "no message")
		logger.error(msg)
		-- Soft-fail: log the error but let the Bridge keep running.
		-- Heartbeats will retry the connection naturally. If the token is
		-- bad, every heartbeat will 401 and the dashboard will show "not
		-- responding" — the customer fixes it from there.
		return true, nil
	end

	logger.info(string.format("Hello accepted (place_id=%d, server_id=%s, chat=%s)",
		helloBody.place_id, helloBody.server_id, state.chatVersion))
	return true, nil
end

return Bootstrap
