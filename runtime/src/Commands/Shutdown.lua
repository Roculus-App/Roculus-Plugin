--!strict
--[=[
	Shutdown command — gracefully closes this server.

	Roblox shows players "this server is shutting down" and disconnects
	them. No way to display a custom message; that's Roblox's built-in UI.

	Payload:
	  {
	    pre_shutdown_seconds: number?,  -- countdown lead before kick (default 5)
	    message:              string?,  -- custom pre-shutdown banner text;
	                                    --   non-empty string overrides the
	                                    --   default countdown line
	    drain_seconds:        number?,  -- placeholder, currently ignored
	  }

	`drain_seconds` is reserved for future use — a graceful-drain shutdown
	(wait for players to leave, then shutdown) would use it as the max wait.
	For V1 the verb is immediate (after the pre_shutdown_seconds heads-up
	banner).

	Returns:
	  { ok=true, message="Server shutting down" }   -- this server never actually
	                                                 gets to send the response;
	                                                 the dashboard expects it
	                                                 and we set ok=true anyway
	                                                 so the audit log records
	                                                 a clean completion.
]=]

local Players = game:GetService("Players")

-- Shared moderator-text filter — the custom shutdown banner is moderator text
-- shown to every player, same risk class as an announcement. See
-- Core/TextFilter.lua.
local TextFilter = require(script.Parent.Parent.Core.TextFilter)

local DEFAULT_PRE_SHUTDOWN_S = 5

return function(state, payload: { drain_seconds: number?, pre_shutdown_seconds: number?, message: string? }): { [string]: any }
	local logger = state.logger
	local lead = type(payload.pre_shutdown_seconds) == "number"
		and payload.pre_shutdown_seconds
		or DEFAULT_PRE_SHUTDOWN_S

	-- 2026-06-01 — dashboard can send a custom pre-shutdown banner via
	-- payload.message. It's moderator-authored text shown to EVERY player, so
	-- it runs through the same broadcast text filter as an announcement. The
	-- countdown timing is always driven by `lead` (pre_shutdown_seconds), never
	-- by the message text.
	local defaultLine = string.format(
		"This server is shutting down in %d seconds. Rejoin in a moment.",
		lead
	)
	local banner = defaultLine
	if type(payload.message) == "string" and payload.message ~= "" then
		local ok, filtered = TextFilter.filterForBroadcast(payload.message)
		if ok and filtered ~= nil then
			banner = filtered
		else
			-- Filter unavailable — don't show raw moderator text. Fall back to
			-- the safe system line so players still get a heads-up; the
			-- shutdown itself still proceeds below.
			logger.warn("Shutdown: custom banner filter unavailable — using default line")
		end
	end
	logger.info(string.format(
		"Shutdown command received — announcing %ds in advance then calling game:Shutdown()",
		lead
	))

	-- 2026-05-27 — fire a full-bleed announce banner to every current
	-- player BEFORE the kick. Roblox's own "Shutting down" UI doesn't
	-- show why or give the player even a second of heads-up; this
	-- bridges the gap. Reuses the existing announce kind so we don't
	-- ship a fourth client renderer.
	pcall(function()
		local WarnChannel = require(script.Parent.Parent.Core.WarnChannel) :: any
		for _, p in ipairs(Players:GetPlayers()) do
			WarnChannel.fireClient(p, {
				kind = "announce",
				title = "Server shutdown",
				message = banner,
				color = "#DC2626", -- override the default navy strip with red
			})
		end
	end)

	-- Wait the lead, then KICK EVERY PLAYER explicitly, then close the server.
	-- 2026-06-03 — user: "the server shutdown still does not work ... just make
	-- it kick everyone in the server." game:Shutdown() alone is a no-op in a
	-- Studio solo-test and shows Roblox's generic kick UI with no reason; an
	-- explicit Player:Kick(reason) disconnects each player with a clear message
	-- in a live server and makes the "kick everyone" verb actually fire. We then
	-- still call game:Shutdown() so the now-empty instance doesn't linger (and
	-- so a player mid-join who dodged the kick loop is caught). Each Kick is
	-- pcall-guarded so one failure can't abort the rest of the loop.
	-- game:Shutdown() may not allow the result POST to complete after the kick
	-- screen renders — CommandPoller fires the result POST in task.spawn so it
	-- has its own scheduling window.
	task.delay(lead, function()
		local kickReason = "This server is shutting down. Rejoin in a moment."
		for _, p in ipairs(Players:GetPlayers()) do
			pcall(function()
				p:Kick(kickReason)
			end)
		end
		game:Shutdown()
	end)

	return {
		ok = true,
		message = string.format("Server shutting down in %ds (announce fired)", lead),
		pre_shutdown_seconds = lead,
	}
end
