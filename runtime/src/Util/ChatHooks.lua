--!strict
--[=[
	ChatHooks — server-side chat capture + filter pipeline.

	Why this exists (2026-05-20, second rewrite):
	  Roblox tightened TextChatService recently. Both `MessageReceived`
	  AND `OnIncomingMessage` are CLIENT-only — setting them server-side
	  errors with "can only be implemented on the client." The ONLY hook
	  that runs on the server for incoming chat is
	  `TextChannel.ShouldDeliverCallback`.

	Pattern:
	  We install `ShouldDeliverCallback` on every `TextChannel` we find
	  under TextChatService (RBXGeneral, RBXSystem, plus any custom
	  channels). The callback dispatches to all registered subscribers.

	  A subscriber is `fn(message, recipientTextSource) -> boolean?` —
	  return false to suppress delivery to that recipient, true (or nil)
	  to allow it.

	Per-recipient dedup:
	  `ShouldDeliverCallback` fires ONCE PER RECIPIENT, not once per
	  message. For chat capture we only want to log once per message —
	  we dedup using `message.MessageId` plus a TTL cache. Filter-type
	  subscribers (mute) don't dedup, they get called for every
	  recipient.

	Subscriber API:
	  ChatHooks.subscribeCapture(fn)  — fn(message): nil
	    Called exactly once per message (deduped). Used for logging.

	  ChatHooks.subscribeDeliverFilter(fn) — fn(message, recipient): bool?
	    Called per-recipient. Return false to drop for that recipient.

	Channel discovery:
	  Channels are direct children OR descendants of TextChatService
	  depending on Roblox version. We scan all descendants on install,
	  and listen to DescendantAdded so runtime-created channels (e.g.
	  team channels) also get hooked.

	Idempotency:
	  Multiple installOnce() calls are no-ops after the first. Each
	  channel's ShouldDeliverCallback is set exactly once via a tracked
	  Set; subsequent attempts on the same channel are skipped.

	Failure mode:
	  Each subscriber is pcall-wrapped — a broken consumer never breaks
	  the chain. Delivery defaults to true if every subscriber errors
	  (fail-open for chat — better to deliver than drop on a bug).
]=]

local TextChatService = game:GetService("TextChatService")

local ChatHooks = {}

type CaptureFn = (message: TextChatMessage) -> ()
type FilterFn = (message: TextChatMessage, recipient: TextSource) -> boolean?

local captureSubs: { CaptureFn } = {}
local filterSubs: { FilterFn } = {}

local installed = false
local sharedLogger: any = nil
local lastError: string? = nil

-- Channels we've already bound (avoid double-setting ShouldDeliverCallback).
local boundChannels: { [Instance]: true } = {}

-- Recently-seen MessageIds for capture dedup. Bounded set with FIFO eviction.
local SEEN_CAP = 256
local seenList: { string } = {}
local seenSet: { [string]: true } = {}

local function markSeen(id: string): boolean
	-- Returns true if NEW (first time we've seen it), false if duplicate.
	if seenSet[id] then return false end
	seenSet[id] = true
	table.insert(seenList, id)
	while #seenList > SEEN_CAP do
		local old = table.remove(seenList, 1)
		if old then seenSet[old] = nil end
	end
	return true
end

function ChatHooks.subscribeCapture(fn: CaptureFn): ()
	table.insert(captureSubs, fn)
end

function ChatHooks.subscribeDeliverFilter(fn: FilterFn): ()
	table.insert(filterSubs, fn)
end

local function bindChannel(channel: Instance): ()
	if boundChannels[channel] then return end
	if not channel:IsA("TextChannel") then return end

	local ok, err = pcall(function()
		channel.ShouldDeliverCallback = function(message: TextChatMessage, recipient: TextSource)
		-- 1) Capture path — once per message, dedup by MessageId.
		--    MessageId may be nil during the brief window between message
		--    creation and Roblox assigning one; fall back to a synthetic
		--    key so we don't double-log.
		local key = (message :: any).MessageId
		if not key or key == "" then
			-- Fallback: sender + text + os.clock-bucket — good enough since
			-- the same recipient pass happens within microseconds.
			local sender = message.TextSource and message.TextSource.UserId or 0
			key = string.format("%d|%s|%d", sender, message.Text or "", math.floor(os.clock() * 100))
		end
		if markSeen(key) then
			for _, fn in ipairs(captureSubs) do
				local ok, err = pcall(fn, message)
				if not ok and sharedLogger then
					sharedLogger.warn("ChatHooks capture subscriber errored: " .. tostring(err))
				end
			end
		end

		-- 2) Filter path — per-recipient. ALL filters must return truthy
		--    for the message to be delivered to this recipient.
		for _, fn in ipairs(filterSubs) do
			local ok, result = pcall(fn, message, recipient)
			if not ok then
				if sharedLogger then
					sharedLogger.warn("ChatHooks filter subscriber errored: " .. tostring(result))
				end
				-- Fail open — broken filter doesn't drop messages.
			elseif result == false then
				return false
			end
		end
			return true
		end
	end)

	if ok then
		boundChannels[channel] = true
		if sharedLogger then
			sharedLogger.debug("ChatHooks: bound ShouldDeliverCallback on TextChannel " .. channel.Name)
		end
	else
		lastError = "ShouldDeliverCallback assignment failed on '" .. channel.Name .. "': " .. tostring(err)
		if sharedLogger then
			sharedLogger.warn("ChatHooks: " .. lastError)
		end
	end
end

--[=[
	Health snapshot for the heartbeat. Shape:
	  { ok = bool, channels_bound = int, last_error = string? }

	Heartbeat.lua reads this every tick and ships it to the dashboard so
	moderators can see when chat capture is broken (e.g. Roblox tweaks the
	chat API again and our SDK can't bind).
]=]
function ChatHooks.healthSnapshot(): { ok: boolean, channels_bound: number, last_error: string? }
	local n = 0
	for _ in pairs(boundChannels) do n += 1 end
	return {
		ok = n > 0 and lastError == nil,
		channels_bound = n,
		last_error = lastError,
	}
end

function ChatHooks.installOnce(state): ()
	if installed then return end
	installed = true
	sharedLogger = state.logger

	-- Scan existing descendants for TextChannels (could be direct children
	-- OR nested in a `TextChannels` sub-folder depending on Roblox version).
	for _, d in ipairs(TextChatService:GetDescendants()) do
		bindChannel(d)
	end

	-- And watch for new ones (team channels created at runtime).
	TextChatService.DescendantAdded:Connect(bindChannel)

	if sharedLogger then
		sharedLogger.debug(string.format(
			"ChatHooks: installed; %d channel(s) bound on boot",
			(function()
				local n = 0
				for _ in pairs(boundChannels) do n += 1 end
				return n
			end)()
		))
	end
end

return ChatHooks
