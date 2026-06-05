--!strict
--[=[
	Command pickup loop — long-polls GET /api/bridge/commands/next.

	"Long poll" means: we issue a request, backend holds the connection
	open until either (a) a command becomes available, or (b) ~60s
	elapses with nothing to deliver. Then we get a response — either a
	command to execute, or an "empty" sentinel meaning "no work, poll
	again." Either way we immediately re-poll.

	This gives us near-realtime command delivery (~100ms from dashboard
	click to in-game execution when a command is ready) without needing
	WebSockets, which Roblox doesn't support reliably.

	Budget: ~1 req/min during quiet periods (just the 60s poll cycle).
	During heavy moderation activity (commands arriving in bursts), still
	~2 req/min. Plenty of HTTP budget left (limit is 500/min).

	Failure handling: same self-healing pattern as Heartbeat. The poller
	never crashes. On network failure, backs off briefly before retry.
]=]

local CommandPoller = {}

-- 2026-05-27 — bumped from 60→90 (backend bumped 50→80). Cuts long-poll
-- reconnect rate by ~1/3 on idle servers. Still well under Roblox's
-- HttpService 30s minimum-disconnect heuristic.
local POLL_TIMEOUT_SOFT_S = 90       -- backend should close the long-poll near this
local FAILURE_BACKOFF_S = 5          -- wait before retry on network errors
local SHUTDOWN_GRACE_S = 0           -- exit immediately when state.stopping is set

local function dispatch(state, command)
	-- command = { id, kind, payload, dispatched_at }
	-- We require the Commands module lazily to keep the require-graph clean
	-- and to support hot-swapping individual verb modules in tests.
	local Commands = require(script.Parent.Parent.Commands)
	local Http = require(script.Parent.Parent.Util.Http)
	local logger = state.logger

	logger.info(string.format("Command received: %s (id=%s)", command.kind, command.id))

	local startedAt = os.clock()
	local handler = Commands.resolve(state, command.kind)
	local result: { [string]: any }

	if not handler then
		logger.warn(string.format("No handler for command kind '%s'", command.kind))
		result = {
			ok = false,
			error_code = "unknown_command",
			error_message = "Bridge has no handler for command kind: " .. command.kind,
		}
	else
		local ok, handlerResult = pcall(handler, state, command.payload or {})
		if not ok then
			logger.error(string.format("Command '%s' threw: %s",
				command.kind, tostring(handlerResult)))
			result = {
				ok = false,
				error_code = "handler_threw",
				error_message = tostring(handlerResult),
			}
		else
			-- Handler returns either nil (success, no return value) or a table.
			if type(handlerResult) == "table" then
				result = handlerResult
				if result.ok == nil then
					result.ok = true
				end
			else
				result = { ok = true }
			end
		end
	end

	result.duration_ms = math.floor((os.clock() - startedAt) * 1000)

	-- POST result back. Fire-and-forget on failure — we logged it; the
	-- dashboard will surface "no result for command X" eventually.
	local resPath = string.format("/api/v1/bridge/commands/%s/result",
		assert(command.id, "command.id required"))
	task.spawn(function()
		Http.request(state, "POST", resPath, result)
	end)
end

function CommandPoller.startLoop(state): ()
	task.spawn(function()
		local Http = require(script.Parent.Parent.Util.Http)
		local logger = state.logger

		while state.started and not state.stopping do
			local response = Http.longPoll(state, "GET", "/api/v1/bridge/commands/next")

			if not (state.started and not state.stopping) then
				break -- raced with stop()
			end

			if response.ok then
				-- Body shape: { command: {...} | nil }. nil = empty long-poll, just re-poll.
				local body = response.body
				if body and body.data and body.data.command then
					dispatch(state, body.data.command)
				end
				-- Either way, loop immediately and re-poll.
			else
				if response.status ~= 0 then
					logger.warn(string.format("Long-poll error: HTTP %d %s — backing off %ds",
						response.status, response.message or "no message", FAILURE_BACKOFF_S))
				end
				task.wait(FAILURE_BACKOFF_S)
			end
		end
	end)
end

function CommandPoller.stop(_state): ()
	-- Loop checks state.stopping each iteration; nothing else to do here.
	-- The active long-poll request will time out naturally on the backend
	-- side; we don't try to cancel it.
end

return CommandPoller
