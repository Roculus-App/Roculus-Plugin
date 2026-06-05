--!strict
--[=[
	JoinTeleport — moderator "Join flagged server" (#111, 2026-05-30).

	When a moderator clicks "Join server" in the dashboard, the backend mints a
	signed launch token (encoding the target JobId) into a Roblox deep-link's
	`launchData`. The mod's client launches into SOME instance of this place;
	this module reads that `launchData` on join, asks the backend to verify it,
	and on a valid token teleports the mod into the exact target server via
	`TeleportService:TeleportToPlaceInstance`.

	Trust model: `launchData` is unsigned, client-supplied data, so it is NEVER
	trusted locally — the HMAC secret lives only on the backend, and this module
	just relays the token to `/api/v1/bridge/teleport/verify`. A forged token
	fails verification and the player is simply left where they landed.

	No loop risk: once teleported, `game.JobId == jobId` in the target instance,
	so the guard below returns early.
]=]

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local Http = require(script.Parent.Parent.Util.Http)

local JoinTeleport = {}

local TOKEN_PREFIX = "rclj." -- matches services/teleport_links.py

local function handlePlayer(state, player: Player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return
	end

	local launchData = joinData.LaunchData
	-- Cheap prefix gate first: only our tokens go to the backend.
	if type(launchData) ~= "string" or string.sub(launchData, 1, #TOKEN_PREFIX) ~= TOKEN_PREFIX then
		return
	end

	local logger = state.logger
	-- Verify backend-side (the SDK can't validate the HMAC — secret is server-only).
	local resp = Http.request(state, "POST", "/api/v1/bridge/teleport/verify", { token = launchData })
	local data = resp.ok and resp.body and resp.body.data
	if not (data and data.valid and data.job_id) then
		if logger then
			logger.debug("[JoinTeleport] launch token invalid/expired — leaving player in place")
		end
		return
	end

	local jobId = tostring(data.job_id)
	-- Already in the target instance? Nothing to do (also breaks any teleport loop).
	if game.JobId == jobId then
		if logger then
			logger.info("[JoinTeleport] moderator already in the target server")
		end
		return
	end

	local placeId = tonumber(data.place_id) or game.PlaceId
	if logger then
		logger.info(string.format("[JoinTeleport] teleporting %s to target server %s", player.Name, jobId))
	end

	local teleportOk, teleportErr = pcall(function()
		TeleportService:TeleportToPlaceInstance(placeId, jobId, player)
	end)
	if not teleportOk and logger then
		logger.error("[JoinTeleport] teleport failed: " .. tostring(teleportErr))
	end
end

--[=[
	Arm the join-handler. Called once from `Roculus:start` after auth, so
	`state.accessToken` is ready for the verify request. Only future joiners are
	relevant (the moderator who just launched), so no need to scan existing
	players.
]=]
function JoinTeleport.start(state)
	Players.PlayerAdded:Connect(function(player)
		-- Own thread so a slow verify request can't stall other join logic.
		task.spawn(handlePlayer, state, player)
	end)
	if state.logger then
		state.logger.info("[JoinTeleport] join-handler armed")
	end
end

return JoinTeleport
