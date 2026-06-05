--!strict
--[=[
	Announce — print a system message in this server's chat.

	Single-server scope. For universe-wide announcements, see Broadcast.lua
	which fans out via MessagingService.

	Payload:
	  {
	    message:         string,
	    title:           string?,   -- optional prefix shown bold (Discord-style)
	    color:           string?,   -- optional hex color, e.g. "#FF0066" (legacy chat only)
	    display_seconds: number?,   -- how long the on-screen banner stays before
	                                --   auto-dismiss (client clamps 3–120; default 8)
	  }

	Chat-version branch:
	  TextChatService — TextChannel:DisplaySystemMessage(text) on every channel
	  Legacy Chat     — StarterGui:SetCore("ChatMakeSystemMessage", {...}) per player

	Returns:
	  { ok=true, mode="TextChatService" | "Legacy", players_notified=N }
]=]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

-- Shared moderator-text filter. Announce, the shutdown banner, and any future
-- broadcast surface all route raw moderator text to players — one filter, one
-- place to keep it correct. See Core/TextFilter.lua.
local TextFilter = require(script.Parent.Parent.Core.TextFilter)

local function announceViaTextChatService(text: string): number
	-- 2026-05-20 — channels are sometimes direct children of TextChatService,
	-- sometimes under a `TextChannels` folder depending on Roblox version /
	-- whether CreateDefaultTextChannels has materialised the container.
	-- Use GetDescendants() so we find them regardless of nesting.
	local count = 0
	for _, d in ipairs(TextChatService:GetDescendants()) do
		if d:IsA("TextChannel") then
			local ok = pcall(function()
				d:DisplaySystemMessage(text)
			end)
			if ok then count += 1 end
		end
	end
	return count
end

local function announceViaLegacy(text: string, color: string?, displaySeconds: number?): number
	-- Legacy chat doesn't have a server-side "system message to all" API
	-- that goes through the unified chat UI without ChatService module
	-- modification. Fallback: fire StarterGui:SetCore on each client via
	-- a per-player loop. Requires the WarnToast companion client script to
	-- be in PlayerGui (loaded via Warn command's binding) — for V1 of
	-- Announce we ship a server-only path that just kicks the message into
	-- each player's PlayerScripts using the same RemoteEvent the Warn
	-- companion listens on, with a "kind=announce" flag the client renders
	-- differently.
	--
	-- That said, the simpler legacy path is `Chat:Chat()` which prints
	-- in-world dialog above a character — wrong UX. So we accept that
	-- legacy chat is best-effort here and document the recommendation to
	-- migrate to TextChatService.
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		-- Best-effort via the same RemoteEvent the Warn handler uses.
		-- We tag the payload with kind="announce" so the client renders a
		-- top-of-screen banner instead of a side toast.
		local ev = require(script.Parent.Parent.Core.WarnChannel) :: any
		ev.fireClient(player, { kind = "announce", message = text, color = color, display_seconds = displaySeconds })
		count += 1
	end
	return count
end

return function(state, payload: { message: string?, title: string?, color: string?, display_seconds: number? }): { [string]: any }
	if type(payload.message) ~= "string" or payload.message == "" then
		return { ok = false, error_code = "invalid_payload", error_message = "announce requires message" }
	end

	-- Filter the message and (optional) title SEPARATELY, then compose the chat
	-- line from the already-filtered parts. Two surfaces consume this text and
	-- want it shaped differently: the chat channels want a single "title:
	-- message" line, but the WarnToast banner renders the title as its eyebrow
	-- and the message as its body. Passing a pre-composed "title: message" to
	-- the banner would duplicate the title AND — because the eyebrow used the
	-- raw title — leak an unfiltered one. Filtering each part once fixes both.
	-- The dashboard doesn't send a title today, but the cross-server path and
	-- any future caller might, so we handle it. Drop the whole announce on ANY
	-- filter failure rather than risk showing raw text.
	local function dropped(): { [string]: any }
		state.logger.warn(string.format(
			"Announce DROPPED — text filter unavailable (chatVersion=%s, players=%d)",
			tostring(state.chatVersion), #Players:GetPlayers()))
		return {
			ok = false,
			error_code = "filter_failed",
			error_message = "Announcement blocked: the text filter couldn't run. Try again in a moment.",
		}
	end

	local message: string = payload.message
	local msgOk, filteredMessage = TextFilter.filterForBroadcast(message)
	if not msgOk or filteredMessage == nil then
		return dropped()
	end

	local filteredTitle: string? = nil
	if type(payload.title) == "string" and payload.title ~= "" then
		local titleOk, ft = TextFilter.filterForBroadcast(payload.title)
		if not titleOk or ft == nil then
			return dropped()
		end
		filteredTitle = ft
	end

	local text = filteredTitle and (filteredTitle .. ": " .. filteredMessage) or filteredMessage

	local notified = 0

	if state.chatVersion == "TextChatService" then
		notified = announceViaTextChatService(text)
	else
		notified = announceViaLegacy(text, payload.color, payload.display_seconds)
	end

	-- 2026-05-20 — ALSO fire the WarnToast banner regardless of chat version.
	-- Even when chat-channel delivery works, customers were complaining
	-- "nothing appears in-game" because the system message lands quietly in
	-- the chat box and is easy to miss. The banner is the unmissable signal.
	-- Customers can opt out by overriding the banner script if they don't
	-- want it.
	pcall(function()
		local ev = require(script.Parent.Parent.Core.WarnChannel) :: any
		for _, player in ipairs(Players:GetPlayers()) do
			ev.fireClient(player, {
				kind = "announce",
				message = filteredMessage, -- body (already filtered)
				color = payload.color,
				title = filteredTitle, -- eyebrow (already filtered; nil → "Server Announcement")
				display_seconds = payload.display_seconds,
			})
		end
	end)

	state.logger.info(string.format("Announce sent to %d destinations (mode=%s): %s",
		notified, state.chatVersion or "?", text:sub(1, 60)))

	return {
		ok = true,
		mode = state.chatVersion,
		players_notified = notified,
	}
end
