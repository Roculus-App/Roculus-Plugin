--!strict
--[=[
	Command dispatcher — maps command "kind" strings to handler functions.

	Each handler signature: `function(state, payload) -> result | nil`

	  - state   = the global state table from init.lua
	  - payload = whatever the dashboard sent in the command body
	  - return  = a table with `ok` field + optional `error_code`,
	              `error_message`, and per-command return data;
	              OR nil/true for "success, no return data"

	Handlers run inside pcall in CommandPoller, so throwing is safe but
	wasteful — prefer returning `{ ok=false, error_code, error_message }`
	for expected failures (player not found, etc.) and only throw for
	unrecoverable bugs.

	Custom dev-registered commands (via Roculus:registerCommand) are also
	resolved here — they're checked LAST so built-in commands always win.
]=]

local Commands = {}

-- Built-in handlers. New ones get added here.
local builtin: { [string]: any } = {
	kick               = require(script.Kick),
	soft_kick          = require(script.SoftKick),
	shutdown           = require(script.Shutdown),
	mute               = require(script.Mute),
	suspend            = require(script.Suspend),
	warn               = require(script.Warn),
	announce           = require(script.Announce),
	broadcast          = require(script.Broadcast),
	["player.snapshot"] = require(script.PlayerSnapshot),
}

--[=[
	Resolve a command kind to its handler function. Returns nil if no
	handler is registered (the poller treats this as an `unknown_command`
	failure and reports it back to the dashboard).

	Resolution order:
	  1. Built-in handlers (kick, mute, warn, etc.)
	  2. Dev-registered handlers via Roculus:registerCommand
]=]
function Commands.resolve(state, kind: string): any?
	local handler = builtin[kind]
	if handler then
		return handler
	end
	-- Check dev-registered commands. We only return the handler if it's
	-- also been opted into dashboard exposure — otherwise a moderator
	-- could craft a command kind matching a private registered command
	-- and invoke it through the queue, defeating the opt-in safety.
	if state.customCommands[kind] and state.dashboardExposed[kind] then
		return state.customCommands[kind]
	end
	return nil
end

return Commands
