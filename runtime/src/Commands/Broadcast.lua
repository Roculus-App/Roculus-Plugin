--!strict
--[=[
	Broadcast — universe-wide announcement via MessagingService.

	When a moderator clicks "Announce → All servers in this game" on the
	dashboard, the backend dispatches the command to ONE Bridge in the
	universe (the long-poll happens to pick it up). That Bridge does the
	local announce AND publishes via MessagingService so every OTHER server
	in the universe also announces.

	Payload:
	  {
	    message: string,
	    title:   string?,
	  }

	Local execution: identical to Announce.
	Cross-server execution: publish via BroadcastBus → every subscribed
	Bridge receives → runs the same Announce path locally.

	Returns:
	  { ok=true, local_notified=N, propagated=true|false, propagation_error=string? }
]=]

local BroadcastBus = require(script.Parent.Parent.Core.BroadcastBus)
local Announce = require(script.Parent.Announce)

return function(state, payload: { message: string?, title: string? }): { [string]: any }
	if type(payload.message) ~= "string" or payload.message == "" then
		return { ok = false, error_code = "invalid_payload", error_message = "broadcast requires message" }
	end

	-- 1. Local announce on the server that picked up the command.
	local local_result = Announce(state, payload)
	local localNotified = (local_result.ok and local_result.players_notified) or 0

	-- 2. Fan out via MessagingService so every OTHER server in the universe
	--    runs its own Announce. BroadcastBus.publish returns (ok, err).
	local published, pubErr = BroadcastBus.publish(state, "announce", payload)

	return {
		ok = local_result.ok or false,
		local_notified = localNotified,
		propagated = published,
		propagation_error = pubErr,
		mode = state.chatVersion,
	}
end
