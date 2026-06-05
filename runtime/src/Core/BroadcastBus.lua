--!strict
--[=[
	MessagingService subscriber for cross-server Bridge messages.

	One Bridge command (Broadcast) needs to fan out to every running server
	in the universe. We use Roblox's built-in MessagingService — the same
	pub/sub bus customers already use for inventory syncing, leaderboards,
	etc.

	Topic: `roculus.bridge.v1`

	Payload (JSON, max 974 chars per MessagingService docs):
	  {
	    kind: "announce" | "ban" | "mute" | (custom),
	    by_server_id: string,          -- the server that initiated
	    payload: { ... }               -- verb-specific
	  }

	On boot, each Bridge subscribes to this topic. When a message arrives,
	the Bridge routes it to the matching local handler (e.g. an incoming
	"announce" calls Announce.handleBroadcast(message)).

	Outbound publishes go through this module too — Broadcast command
	hands off to BroadcastBus.publish(...) instead of touching
	MessagingService directly. Means the encoding + length check + retry
	policy lives in one place.
]=]

local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local BroadcastBus = {}

local TOPIC = "roculus.bridge.v1"
local PAYLOAD_MAX_CHARS = 950 -- below Roblox's 974 cap so headers don't overflow

local handlers: { [string]: (any) -> () } = {}
local subscribed = false

--[=[
	Register a local handler for incoming broadcast messages of a given kind.
	Multiple registrations for the same kind overwrite (last-write-wins).
	Called by Announce.lua / Broadcast.lua during Bridge bootstrap so the
	subscriber can route incoming messages.
]=]
function BroadcastBus.registerHandler(kind: string, fn: (any) -> ()): ()
	handlers[kind] = fn
end

--[=[
	Subscribe to the broadcast topic. Idempotent — calling twice is a no-op.
	Studio sessions can't receive MessagingService publishes (Roblox
	limitation), so we skip subscription there but keep the publish path
	working (publishes from Studio also no-op gracefully).
]=]
function BroadcastBus.start(state): ()
	if subscribed then return end
	if RunService:IsStudio() then
		state.logger.debug("BroadcastBus: skipping subscribe (Studio session)")
		subscribed = true -- prevent retry attempts
		return
	end

	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function(message)
			local data = message.Data
			if type(data) ~= "string" then return end

			local decoded
			local decodeOk, decodeErr = pcall(function()
				decoded = HttpService:JSONDecode(data)
			end)
			if not decodeOk or type(decoded) ~= "table" then
				state.logger.warn("BroadcastBus: failed to decode incoming message: "
					.. tostring(decodeErr))
				return
			end

			-- Don't process our own publishes — MessagingService delivers to
			-- the publisher too.
			local myServerId = game.JobId ~= "" and game.JobId or "studio-session"
			if decoded.by_server_id == myServerId then
				return
			end

			local kind = decoded.kind
			local handler = kind and handlers[kind]
			if handler then
				local handlerOk, handlerErr = pcall(handler, decoded.payload or {})
				if not handlerOk then
					state.logger.warn(string.format(
						"BroadcastBus handler for '%s' threw: %s",
						tostring(kind), tostring(handlerErr)))
				end
			else
				state.logger.debug("BroadcastBus: no handler for kind '" .. tostring(kind) .. "'")
			end
		end)
	end)

	if ok then
		subscribed = true
		state.logger.debug("BroadcastBus: subscribed to " .. TOPIC)
	else
		state.logger.warn("BroadcastBus: subscribe failed (will retry on next start): "
			.. tostring(err))
	end
end

--[=[
	Publish a message to every server in this universe. Returns true on
	success, false on failure (caller decides whether to retry).

	Encodes the payload as JSON. If the encoded length exceeds the
	MessagingService cap, returns false with a clear error rather than
	silently truncating.
]=]
function BroadcastBus.publish(state, kind: string, payload: { [string]: any }): (boolean, string?)
	local body = {
		kind = kind,
		by_server_id = game.JobId ~= "" and game.JobId or "studio-session",
		payload = payload,
	}

	local encoded
	local encOk, encErr = pcall(function()
		encoded = HttpService:JSONEncode(body)
	end)
	if not encOk then
		return false, "encode_failed: " .. tostring(encErr)
	end
	if #encoded > PAYLOAD_MAX_CHARS then
		return false, string.format(
			"payload_too_large: %d chars (max %d)", #encoded, PAYLOAD_MAX_CHARS)
	end

	-- Studio can't publish to MessagingService either — return success-ish
	-- so the command result doesn't show a confusing failure during local
	-- testing.
	if RunService:IsStudio() then
		state.logger.debug("BroadcastBus: skipping publish (Studio session)")
		return true, "studio_skipped"
	end

	local pubOk, pubErr = pcall(function()
		MessagingService:PublishAsync(TOPIC, encoded)
	end)
	if not pubOk then
		return false, "publish_failed: " .. tostring(pubErr)
	end
	return true, nil
end

return BroadcastBus
