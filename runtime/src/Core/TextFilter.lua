--!strict
--[=[
	TextFilter — run MODERATOR-authored text through Roblox's text filter
	before it is shown to players.

	Any surface that renders text a moderator typed (announcements, the
	shutdown heads-up banner, future broadcast surfaces) must pass it through
	here first. These surfaces bypass Roblox's normal chat pipeline — they call
	DisplaySystemMessage / StarterGui:SetCore / a custom banner that all render
	raw strings — so without an explicit filter a moderator could broadcast
	unfiltered profanity to every player. Centralising it here means there is
	ONE place to get filtering right, and one place to reuse from every new
	moderator-text surface (this is the fix for the "announcements still allow
	cuss words" complaint — the filter lived nowhere in those paths before).

	filterForBroadcast(text) -> (ok: boolean, filtered: string?)
	  ok=true  → `filtered` is the fully-tagged broadcast-safe string from
	             GetNonChatStringForBroadcastAsync — safe to show to EVERY
	             player regardless of their account's filter age.
	  ok=false → filtering could not run (service unavailable / throttled / no
	             valid author id). The caller MUST NOT show the raw text: drop
	             the message, or fall back to system-authored copy.

	fromUserId: FilterStringAsync needs the text's "author" id. Server-authored
	moderator text has no in-server author, so we filter relative to a player
	present in this server, falling back to the place owner when the game is
	owned by a user (not a group). The filter is content-based — the author id
	only tunes age-appropriateness — so any valid user id catches profanity.
]=]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local TextFilter = {}

function TextFilter.filterForBroadcast(text: string): (boolean, string?)
	local authorId: number? = nil
	local present = Players:GetPlayers()
	if #present > 0 then
		authorId = present[1].UserId
	elseif game.CreatorType == Enum.CreatorType.User then
		authorId = game.CreatorId
	end
	if authorId == nil then
		-- Empty group-game server: CreatorId is the GROUP id, not a user, and
		-- nobody's present to borrow an id from. Can't filter → caller drops.
		return false, nil
	end
	local uid: number = authorId

	local ok, resultObject = pcall(function()
		return TextService:FilterStringAsync(text, uid)
	end)
	if not ok or resultObject == nil then
		return false, nil
	end

	local ok2, filtered = pcall(function()
		return resultObject:GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 or type(filtered) ~= "string" then
		return false, nil
	end
	return true, filtered
end

return TextFilter
