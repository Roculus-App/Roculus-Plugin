--!strict
--[=[
	Detect which Roblox chat system the game uses. Roblox is mid-migration
	from the legacy `Chat`-service flow to the new `TextChatService` flow,
	and games are running on either depending on when they were created /
	whether the dev opted in.

	Bridge needs to know which one to bind to for:

	  - Chat tail (heartbeat needs last ~50 messages → which event fires?)
	  - Mute (legacy = chat-handler filter; new = `Player.UserId` blocklist
	    on each `TextChannel`)
	  - Announce (legacy = `ChatService:SendSystemMessage`;
	    new = `TextChannel:SendAsync` or `SendNotificationAsync`)

	Detection: read `TextChatService.ChatVersion`. Returns "TextChatService"
	or "Legacy". Falls back to "Legacy" on any read error since games
	predating ChatVersion are by definition on the legacy path.
]=]

local TextChatService = game:GetService("TextChatService")

local ChatVersion = {}

export type Version = "TextChatService" | "Legacy"

function ChatVersion.detect(): Version
	local ok, version = pcall(function()
		return TextChatService.ChatVersion
	end)
	if not ok then
		return "Legacy"
	end
	-- ChatVersion is an Enum.ChatVersion. Compare against the Enum table.
	if version == Enum.ChatVersion.TextChatService then
		return "TextChatService"
	end
	return "Legacy"
end

return ChatVersion
