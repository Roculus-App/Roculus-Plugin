--!strict
--[=[
	Heartbeat loop — every 5 seconds, POST /api/bridge/heartbeat with:

	  - server_id        (game.JobId)
	  - uptime_seconds   (workspace.DistributedGameTime)
	  - max_players      (Players.MaxPlayers — real per-server cap)
	  - roster           (list of players currently in the server)
	  - chat_tail        (last ~50 chat messages, ring-buffered)
	  - is_private       (game.PrivateServerId ~= "")
	  - private_server_owner_id  (if private)
	  - vip_server_link_code     (if dev registered one)
	  - bridge_version

	The dashboard's /moderation/servers page reads heartbeats to populate
	the live roster, the Chat tab's recent messages, the "Bridge last ping"
	stat, and the public/private status indicators.

	Cadence: 5 seconds. Roblox HttpService is rate-limited to 500 req/min
	per server; we use ~12 req/min for heartbeat which leaves plenty of
	budget for command pickup + result reporting.

	Failure handling: every failed heartbeat logs once + advances the
	internal "consecutive failures" counter. The loop never crashes —
	the dashboard simply shows "Bridge not responding" after >60s without
	a successful heartbeat. Self-healing on the next successful POST.
]=]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Heartbeat = {}

-- 2026-05-27 — bumped from 5s to 10s. Halves heartbeat HTTP load on the
-- VPS without changing the user-visible "Bridge offline" detection
-- window meaningfully (still <30s to flip to stale). At 50 CCU, 10s
-- cadence = 5 RPS vs 10 RPS at 5s.
local HEARTBEAT_INTERVAL_S = 10
local CHAT_TAIL_SIZE = 50

-- Ring-buffer of recent chat messages, populated by chat-version-aware listeners.
-- Each entry: { player_id: number, body: string, at: number (unix epoch), channel: string? }
local chatRing: { any } = {}

local function pushChat(entry: any): ()
	table.insert(chatRing, entry)
	while #chatRing > CHAT_TAIL_SIZE do
		table.remove(chatRing, 1)
	end
end

local function snapshotRoster(): { any }
	local roster = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(roster, {
			user_id = player.UserId,
			username = player.Name,
			display_name = player.DisplayName,
			-- Membership / age aren't free to query per-tick; skip in heartbeat.
			-- Dashboard fetches avatar/account-age via separate Roblox thumbnail
			-- and users endpoints from the user_id list.
		})
	end
	return roster
end

local function buildHeartbeatBody(state): { [string]: any }
	-- 2026-05-20 — include chat-capture health so the dashboard can warn
	-- moderators when our SDK can't bind to the chat system anymore (e.g.
	-- Roblox shipping yet another chat-API change). Safe to require here
	-- because the module is small + idempotent; only the TextChatService
	-- branch in bindChatListeners actually installs the dispatcher.
	local chatCapture: any = nil
	if state.chatVersion == "TextChatService" then
		local ok, ChatHooks = pcall(require, script.Parent.Parent.Util.ChatHooks)
		if ok then
			local ok2, snap = pcall(ChatHooks.healthSnapshot)
			if ok2 then chatCapture = snap end
		end
	elseif state.chatVersion == "Legacy" then
		chatCapture = { ok = true, channels_bound = 0, last_error = nil }
	end

	return {
		-- Stable per-session id minted by Bootstrap (handles Studio's
		-- empty-JobId case so each playtest gets a fresh bridge_servers row).
		server_id = state.serverId or (game.JobId ~= "" and game.JobId or "studio-session"),
		-- Self-tracked uptime (Bootstrap stamped bootTime via os.time()).
		-- Falls back to DistributedGameTime if for some reason bootTime
		-- isn't set, but clamps the fallback to a sane range so the
		-- dashboard never displays the "2320 days" Studio quirk.
		uptime_seconds = (
			state.bootTime and math.max(0, os.time() - state.bootTime)
			or math.max(0, math.min(86400 * 30, math.floor(Workspace.DistributedGameTime)))
		),
		bridge_version = state.bridgeVersion,
		chat_version = state.chatVersion,
		is_studio = RunService:IsStudio(),
		is_private = game.PrivateServerId ~= "",
		private_server_owner_id = game.PrivateServerOwnerId ~= 0
			and game.PrivateServerOwnerId or nil,
		vip_server_link_code = state.vipServerLinkCode,
		-- 2026-06-01 — report the real per-server player cap so the backend
		-- can store it instead of a hardcoded value. Players.MaxPlayers is the
		-- configured max for this server (a number). `Players` is the service
		-- already required at the top of this module (used by snapshotRoster).
		max_players = Players.MaxPlayers,
		roster = snapshotRoster(),
		chat_tail = chatRing, -- send the ring as-is; backend treats it as the latest N
		chat_capture = chatCapture,
	}
end

local function bindChatListeners(state): ()
	-- Bind once. Both legacy + TextChatService paths populate the same chatRing.
	if state.chatVersion == "TextChatService" then
		-- 2026-05-20 — REVISED chat-capture path.
		--
		-- Both `TextChatService.MessageReceived` AND `TextChannel.MessageReceived`
		-- are CLIENT-only — they fire when a client's UI receives a message.
		-- The Bridge runs server-side, so neither ever fired and `chat_tail`
		-- stayed empty in every heartbeat.
		--
		-- Per the official Roblox docs, the only server-side hooks are:
		--   - `TextChatService.OnIncomingMessage` (once per message, before delivery)
		--   - `TextChannel.ShouldDeliverCallback` (per recipient, gates delivery)
		--
		-- 2026-05-20 SECOND REWRITE — `OnIncomingMessage` errored at runtime
		-- with "can only be implemented on the client" too. The ONLY hook
		-- that runs server-side now is `TextChannel.ShouldDeliverCallback`.
		-- ChatHooks installs it per-channel and dedups by MessageId so we
		-- log once per message even though the callback fires once per
		-- recipient.
		local ChatHooks = require(script.Parent.Parent.Util.ChatHooks)
		ChatHooks.installOnce(state)
		ChatHooks.subscribeCapture(function(message)
			if not message.TextSource then return end
			-- 2026-05-27 — diagnostic log so we can see exactly which
			-- messages reach the SDK capture vs which get dropped by
			-- Roblox-side moderation or ChatHooks dedup. Useful when
			-- chasing "I typed the same message twice but it only
			-- appeared once" reports — typically that's the message
			-- failing Roblox's text filter on the second send, not an
			-- SDK bug. The log surfaces it in the Output panel for
			-- forensic review.
			state.logger.debug(string.format(
				"chat capture: uid=%d ch=%s body=%q",
				message.TextSource.UserId,
				(message.TextChannel and message.TextChannel.Name) or "All",
				message.Text or ""
			))
			pushChat({
				player_id = message.TextSource.UserId,
				body = message.Text,
				at = os.time(),
				channel = (message.TextChannel and message.TextChannel.Name) or "All",
			})
		end)
		state.logger.debug("Chat binding: ChatHooks capture subscriber registered")
	else
		-- Legacy Chat path — Player.Chatted fires per player per message.
		local function bindPlayer(player: Player)
			player.Chatted:Connect(function(msg)
				pushChat({
					player_id = player.UserId,
					body = msg,
					at = os.time(),
					channel = "All",
				})
			end)
		end
		Players.PlayerAdded:Connect(bindPlayer)
		for _, p in ipairs(Players:GetPlayers()) do
			bindPlayer(p)
		end
	end
end

function Heartbeat.startLoop(state): ()
	bindChatListeners(state)

	-- 2026-05-21 — snappier player-leave UX. PlayerRemoving fires when a
	-- player disconnects; without this hook, the dashboard's roster reflects
	-- the change only on the next scheduled heartbeat (up to 5s) + the
	-- dashboard's own polling cycle (up to 5s) = ~10s worst case lag. Firing
	-- a fire-and-forget heartbeat immediately on PlayerRemoving compresses
	-- that to "next dashboard poll" (~1-2s typical).
	Players.PlayerRemoving:Connect(function(_player)
		if not state.started or state.stopping then return end
		task.spawn(function()
			local Http = require(script.Parent.Parent.Util.Http)
			Http.request(state, "POST", "/api/v1/bridge/heartbeat", buildHeartbeatBody(state))
		end)
	end)

	task.spawn(function()
		local Http = require(script.Parent.Parent.Util.Http)
		local logger = state.logger
		local consecutiveFailures = 0

		while state.started and not state.stopping do
			local response = Http.request(state, "POST", "/api/v1/bridge/heartbeat",
				buildHeartbeatBody(state))

			if response.ok then
				if consecutiveFailures > 0 then
					logger.info(string.format("Heartbeat recovered after %d failures",
						consecutiveFailures))
				end
				consecutiveFailures = 0
			else
				consecutiveFailures += 1
				if consecutiveFailures == 1 or consecutiveFailures % 12 == 0 then
					-- Log every first failure + every ~minute thereafter.
					logger.warn(string.format("Heartbeat failed (%d in a row): HTTP %d %s",
						consecutiveFailures, response.status,
						response.message or "no message"))
				end
			end

			task.wait(HEARTBEAT_INTERVAL_S)
		end
	end)
end

function Heartbeat.stop(state): ()
	-- The loop checks state.stopping each iteration. Setting it elsewhere
	-- (in Roculus:stop) lets the loop exit cleanly on its next tick.
	-- Best-effort final heartbeat with status=stopping so dashboard sees a
	-- clean shutdown rather than a missed-heartbeat timeout.
	local Http = require(script.Parent.Parent.Util.Http)
	local body = buildHeartbeatBody(state)
	body.stopping = true
	-- Fire-and-forget — game is shutting down, no time to wait.
	task.spawn(function()
		Http.request(state, "POST", "/api/v1/bridge/heartbeat", body)
	end)
end

return Heartbeat
