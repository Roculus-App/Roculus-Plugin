--!strict
--[=[
	Warn — private notice to one player, rendered as a toast on their screen.

	Server fires a RemoteEvent via WarnChannel; the companion LocalScript
	(ClientCompanion/WarnToast.client.lua) renders the UI.

	Payload:
	  {
	    user_id:     number,         -- target player
	    message:     string,
	    title:       string?,        -- defaults to "Moderator Warning"
	    require_ack: boolean?,       -- if true, toast stays until clicked
	  }

	Returns:
	  { ok=true, warned_user_id=N, delivered=true }
	  { ok=false, error_code, error_message }
]=]

local Players = game:GetService("Players")

return function(state, payload: { user_id: number?, message: string?, title: string?, require_ack: boolean? }): { [string]: any }
	local userId = payload.user_id
	if type(userId) ~= "number" then
		return { ok = false, error_code = "invalid_payload", error_message = "warn requires user_id" }
	end
	if type(payload.message) ~= "string" or payload.message == "" then
		return { ok = false, error_code = "invalid_payload", error_message = "warn requires message" }
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return {
			ok = false,
			error_code = "player_not_in_server",
			error_message = string.format("No player with user_id %d in this server", userId),
		}
	end

	local WarnChannel = require(script.Parent.Parent.Core.WarnChannel)
	WarnChannel.fireClient(player, {
		kind = "warn",
		title = payload.title,
		message = payload.message,
		require_ack = payload.require_ack == true,
	})

	state.logger.info(string.format(
		"Warn delivered to %s (%d): %s",
		player.Name, userId, payload.message:sub(1, 60)))

	return {
		ok = true,
		warned_user_id = userId,
		warned_username = player.Name,
		delivered = true,
	}
end
