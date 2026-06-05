--!strict
--[=[
	External event reporter — backs the Roculus:reportAction({...}) public API.

	When the customer's game (anti-cheat, admin script, etc.) calls
	reportAction, the Bridge wraps it into POST /api/audit/external so
	the dashboard's audit log gets the event alongside dashboard-initiated
	commands.

	Fire-and-forget: we log network failures but don't retry indefinitely.
	The in-game action already happened — the dashboard missing one audit
	entry is worse than the dashboard being slow, but worse-still would be
	the Bridge eating CPU retrying forever.
]=]

local Reporter = {}

local function normalisePlayer(player: any): { user_id: number?, username: string? }
	if type(player) == "userdata" or (type(player) == "table" and player.UserId) then
		-- Player instance or something quacking like one.
		return {
			user_id = player.UserId,
			username = player.Name,
		}
	elseif type(player) == "table" then
		return {
			user_id = player.user_id,
			username = player.username,
		}
	end
	return { user_id = nil, username = nil }
end

function Reporter.send(state, report): ()
	task.spawn(function()
		local Http = require(script.Parent.Parent.Util.Http)
		local logger = state.logger

		local body = {
			kind = report.kind,
			player = normalisePlayer(report.player),
			reason = report.reason,
			evidence = report.evidence,
			source = report.source or "custom",
			source_detail = report.source_detail,
			-- Bridge-injected metadata so the dashboard knows where this came from.
			server_id = game.JobId ~= "" and game.JobId or "studio-session",
			place_id = game.PlaceId,
			bridge_version = state.bridgeVersion,
			occurred_at = os.time(),
		}

		local response = Http.request(state, "POST", "/api/v1/bridge/audit/external", body)
		if not response.ok then
			logger.warn(string.format("reportAction(%s) failed: HTTP %d %s",
				report.kind, response.status, response.message or "no message"))
		end
	end)
end

return Reporter
