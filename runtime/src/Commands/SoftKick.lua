--!strict
--[=[
	Soft-kick — teleport the player to a lobby place instead of disconnecting.

	Payload:
	  {
	    user_id: number,            -- required
	    lobby_place_id: number,     -- required; usually customer's main lobby
	    reason: string?,            -- optional, passed via teleport data
	  }

	Returns:
	  { ok=true, sent_to_place_id=N, user_id=N }
	  { ok=false, error_code, error_message }
]=]

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

return function(state, payload: { user_id: number?, lobby_place_id: number?, reason: string? })
	local logger = state.logger
	local userId = payload.user_id
	local placeId = payload.lobby_place_id

	if type(userId) ~= "number" then
		return { ok = false, error_code = "invalid_payload", error_message = "soft_kick requires user_id" }
	end
	if type(placeId) ~= "number" then
		return { ok = false, error_code = "invalid_payload", error_message = "soft_kick requires lobby_place_id" }
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return {
			ok = false,
			error_code = "player_not_in_server",
			error_message = string.format("No player with user_id %d in this server", userId),
		}
	end

	-- TeleportService:Teleport(placeId, player, teleportData) — data passes to the
	-- target place so the lobby can show a custom message.
	local teleportData = {
		from = "roculus_bridge",
		reason = payload.reason,
		source_place_id = game.PlaceId,
		source_job_id = game.JobId,
	}

	logger.info(string.format("Soft-kicking %s (%d) to place %d", player.Name, userId, placeId))

	local ok, err = pcall(function()
		TeleportService:Teleport(placeId, player, teleportData)
	end)
	if not ok then
		return {
			ok = false,
			error_code = "teleport_failed",
			error_message = tostring(err),
		}
	end

	return {
		ok = true,
		sent_to_place_id = placeId,
		user_id = userId,
		username = player.Name,
	}
end
