--!strict
--[=[
	Scoped logger for the Bridge. Three reasons we don't just use print():

	1. Every line is prefixed `[Roculus]` so output panel scanning works.
	2. We respect a debug flag — verbose logs stay off in production.
	3. We can later route logs to the backend (e.g. error reports) without
	   touching call sites — they all funnel through one module.
]=]

local Logger = {}

local debugMode = false

function Logger.setDebug(enabled: boolean): ()
	debugMode = enabled == true
end

function Logger.isDebug(): boolean
	return debugMode
end

function Logger.info(msg: string): ()
	print("[Roculus] " .. msg)
end

function Logger.debug(msg: string): ()
	if debugMode then
		print("[Roculus][debug] " .. msg)
	end
end

function Logger.warn(msg: string): ()
	warn("[Roculus] " .. msg)
end

function Logger.error(msg: string): ()
	warn("[Roculus][error] " .. msg)
end

return Logger
