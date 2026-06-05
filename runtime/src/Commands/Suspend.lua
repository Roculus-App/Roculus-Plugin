--!strict
--[=[
	Suspend — fires the in-game suspend overlay (with countdown), then
	kicks the player. The PERSISTENCE half (preventing rejoin until the
	suspension expires) is the dashboard's responsibility — a
	bridge_alerts / player_bans / similar row that the server-side auth
	check consults when the player tries to join again. This command
	only owns the in-server experience: tell the player why, count down,
	disconnect.

	Payload shape (from dashboard):
	  {
	    user_id: number,
	    duration_seconds: number?,   -- shapes the duration_label; if absent,
	                                  -- the overlay shows "indefinite"
	    reason: string?,             -- shown in the overlay body
	    lifts_at_iso: string?,       -- optional human-readable timestamp,
	                                  -- e.g. "2026-06-03 · 14:42 UTC". The
	                                  -- backend computes this from
	                                  -- duration; surfaced verbatim in the
	                                  -- overlay's detail row so the player
	                                  -- knows exactly when they can return.
	    countdown_seconds: number?,  -- defaults to 8s; how long the client
	                                  -- shows the overlay before we kick.
	  }

	Returns:
	  { ok=true,  suspended_user_id=N, kicked=true|false }
	  { ok=false, error_code, error_message }

	Race notes:
	  - If the player leaves during the countdown, the eventual Kick is a
	    no-op (Players:GetPlayerByUserId returns nil). Their seat in the
	    persistence table on the dashboard is what keeps them out next
	    time — this command's job ends at the door.
	  - The Kick fires regardless of the player acknowledging the
	    overlay. The overlay is informational, not consent.
]=]

local Players = game:GetService("Players")

local DEFAULT_COUNTDOWN_S = 8

local function formatDurationLabel(seconds: number?): string
	if not seconds or seconds <= 0 then
		return "indefinite"
	end
	if seconds < 60 then
		return string.format("%d seconds", seconds)
	end
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return string.format("%d minute%s", minutes, minutes == 1 and "" or "s")
	end
	local hours = math.floor(minutes / 60)
	if hours < 24 then
		return string.format("%d hour%s", hours, hours == 1 and "" or "s")
	end
	local days = math.floor(hours / 24)
	return string.format("%d day%s", days, days == 1 and "" or "s")
end

return function(state, payload: {
	user_id: number?,
	duration_seconds: number?,
	reason: string?,
	lifts_at_iso: string?,
	countdown_seconds: number?,
}): { [string]: any }
	local logger = state.logger
	local userId = payload.user_id

	if type(userId) ~= "number" then
		return {
			ok = false,
			error_code = "invalid_payload",
			error_message = "Suspend requires payload.user_id (number)",
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

	local username = player.Name
	local durationLabel = formatDurationLabel(payload.duration_seconds)
	local countdown = type(payload.countdown_seconds) == "number" and payload.countdown_seconds or DEFAULT_COUNTDOWN_S

	logger.info(string.format(
		"Suspending %s (%d) — duration=%s, countdown=%ds, reason=%s",
		username, userId, durationLabel, countdown, tostring(payload.reason)
	))

	-- 1. Fire the in-game overlay. The client renders a full-screen dim
	--    + center modal with the new PanelShell + red accent strip
	--    (ClientCompanion/WarnToast.client.lua → buildSuspend). The
	--    overlay ticks the countdown locally; this server-side timer
	--    runs in parallel and does the actual disconnect.
	pcall(function()
		local WarnChannel = require(script.Parent.Parent.Core.WarnChannel) :: any
		WarnChannel.fireClient(player, {
			kind = "suspend",
			duration_label = durationLabel,
			reason = payload.reason,
			lifts_at = payload.lifts_at_iso,
			countdown = countdown,
		})
	end)

	-- 2. Wait for the countdown, then kick. Spawned task so the command
	--    response can return immediately to the dashboard (don't block
	--    the long-poll response thread on a multi-second wait).
	task.spawn(function()
		task.wait(countdown)
		local fresh = Players:GetPlayerByUserId(userId)
		if fresh then
			local kickReason
			if payload.reason and payload.reason ~= "" then
				kickReason = string.format(
					"Suspended for %s — %s%s",
					durationLabel,
					payload.reason,
					payload.lifts_at_iso and ("\n\nLifts: " .. payload.lifts_at_iso) or ""
				)
			else
				kickReason = string.format(
					"Suspended for %s%s",
					durationLabel,
					payload.lifts_at_iso and ("\nLifts: " .. payload.lifts_at_iso) or ""
				)
			end
			fresh:Kick(kickReason)
			logger.info(string.format("Suspend countdown elapsed for %d — player kicked", userId))
		else
			logger.info(string.format("Suspend countdown elapsed for %d — player already left", userId))
		end
	end)

	return {
		ok = true,
		suspended_user_id = userId,
		suspended_username = username,
		duration_label = durationLabel,
		countdown_seconds = countdown,
	}
end
