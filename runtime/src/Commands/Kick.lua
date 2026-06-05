--!strict
--[=[
	Kick command — disconnects a player from the server.

	Payload shape (from dashboard):
	  {
	    user_id: number,
	    reason: string,    -- shown to the player on the kick screen
	  }

	Returns:
	  { ok=true,  kicked_user_id=N, kicked_username="..." }
	  { ok=false, error_code="player_not_in_server", error_message="..." }
]=]

local Players = game:GetService("Players")

return function(state, payload: { user_id: number?, reason: string? }): { [string]: any }
	local logger = state.logger

	local userId = payload.user_id
	local reason = payload.reason or "You have been removed from this server."

	if type(userId) ~= "number" then
		return {
			ok = false,
			error_code = "invalid_payload",
			error_message = "Kick requires payload.user_id (number)",
		}
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return {
			ok = false,
			error_code = "player_not_in_server",
			error_message = string.format("No player with user_id %d in this server", userId),
		}
	end

	-- Capture before Kick because Player:Kick destroys the reference.
	local username = player.Name
	local displayName = player.DisplayName

	logger.info(string.format("Kicking %s (%d): %s", username, userId, reason))
	player:Kick(reason)

	return {
		ok = true,
		kicked_user_id = userId,
		kicked_username = username,
		kicked_display_name = displayName,
	}
end
