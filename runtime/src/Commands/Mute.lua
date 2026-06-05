--!strict
--[=[
	Mute — suppress chat messages from a player.

	Behaviour differs by chat system. Both paths converge on the same
	module-level `mutedUserIds` set; chat-version branch decides HOW to
	enforce it. The set is in-memory only — durable mute should be the
	customer's responsibility (their own DataStore + their own
	`reportAction` to log via the dashboard).

	Payload:
	  {
	    user_id: number,
	    reason: string?,
	    duration_seconds: number?,   -- optional; if absent, mute is permanent
	                                    (for this server's lifetime)
	  }

	Returns:
	  { ok=true, muted_user_id=N, mode="TextChatService" | "Legacy" }
	  { ok=false, error_code, error_message }

	Cross-server propagation: this command only mutes on THIS server.
	A cross-server mute (fan-out via MessagingService / BroadcastBus, like the
	announce kind) is NOT wired yet — the bus only handles "announce" today, so
	mute is single-server scope until that handler is added.
]=]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ChatHooks = require(script.Parent.Parent.Util.ChatHooks)

local mutedUserIds: { [number]: { reason: string?, until_unix: number? } } = {}
local bound = false

-- 2026-05-21 — true server-side mute via TextSource.CanSend.
--
-- ShouldDeliverCallback only blocks delivery to OTHER recipients; Roblox
-- always echoes the sender's own message back to them, so in single-player
-- testing the mute looked like a no-op. The canonical fix per Roblox docs
-- + DevForum is to set TextSource.CanSend = false on the player's
-- TextSource in each TextChannel. That actually blocks SendAsync at the
-- channel level.
--
-- Iteration uses GetDescendants because TextChannels can be either direct
-- children of TextChatService or nested in a `TextChannels` folder
-- depending on Roblox version.
-- 2026-05-27 — added structured logging because debugging "did mute actually
-- work?" was hard from the customer's side. Returns the count of channels
-- successfully mutated AND a list of channel names so the Output panel
-- shows specifics, not just "channels=2".
--
-- KNOWN ROBLOX QUIRK (worth documenting here because every customer hits it):
--   Setting CanSend = false on a TextSource blocks the SERVER from
--   accepting the SendAsync, but the muted player's OWN client will still
--   render their typed message locally for a fraction of a second before
--   the server's rejection arrives. Other players see NOTHING — the
--   message is genuinely blocked from broadcast. Test by having two
--   accounts in the same server: type as the muted account, verify the
--   OTHER account sees no message in chat.
local function setCanSendForUser(userId: number, canSend: boolean, logger): number
	local n = 0
	local channelNames: { string } = {}
	for _, d in ipairs(TextChatService:GetDescendants()) do
		if d:IsA("TextChannel") then
			local ok, textSource = pcall(function()
				return d:AddUserAsync(userId)
			end)
			if ok and textSource then
				local setOk = pcall(function()
					textSource.CanSend = canSend
				end)
				if setOk then
					n += 1
					table.insert(channelNames, d.Name)
				elseif logger then
					logger.warn(string.format(
						"Mute: AddUserAsync returned a TextSource for user %d in channel %s but CanSend assignment failed",
						userId, d.Name
					))
				end
			elseif logger and not ok then
				logger.warn(string.format(
					"Mute: AddUserAsync failed for user %d in channel %s: %s",
					userId, d.Name, tostring(textSource)
				))
			end
		end
	end
	if logger then
		if n == 0 then
			logger.warn(string.format(
				"Mute: setCanSendForUser(%d, %s) — no TextChannels mutated. "
				.. "Either the game has no TextChannels under TextChatService, or "
				.. "AddUserAsync failed for all of them. Mute will be a no-op.",
				userId, tostring(canSend)
			))
		else
			logger.debug(string.format(
				"Mute: setCanSendForUser(%d, %s) — %d channel(s) updated: %s",
				userId, tostring(canSend), n, table.concat(channelNames, ", ")
			))
		end
	end
	return n
end

--[=[
	Bind the chat filter once per server boot. Both chat-version paths
	end up checking the `mutedUserIds` set, but the wiring differs.

	2026-05-20 — switched the TextChatService path from setting
	`OnIncomingMessage` directly (which Heartbeat.lua also needs) to
	subscribing via `ChatHooks`. A property-setter has no native chain,
	so whichever module bound second silently broke the other.
]=]
local function bindOnce(state)
	if bound then return end
	bound = true

	if state.chatVersion == "TextChatService" then
		ChatHooks.installOnce(state)
		-- 2026-05-20 — switched from OnIncomingMessage (now client-only and
		-- errors server-side) to ShouldDeliverCallback via ChatHooks. Per-
		-- recipient filter; returning false drops the message entirely
		-- instead of leaving an empty bubble.
		ChatHooks.subscribeDeliverFilter(function(message, _recipient)
			local source = message.TextSource
			if source and mutedUserIds[source.UserId] then
				local mute = mutedUserIds[source.UserId]
				if mute.until_unix and os.time() >= mute.until_unix then
					mutedUserIds[source.UserId] = nil
					return nil -- allow
				end
				return false -- drop
			end
			return nil -- allow
		end)
		state.logger.debug("Mute: ChatHooks deliver-filter subscriber registered")

		-- 2026-05-31 — rejoin re-apply. On rejoin (or a channel created later)
		-- Roblox makes a FRESH TextSource with CanSend reset to true, silently
		-- un-muting the player. Re-apply the block to any new TextSource whose
		-- user is still in the muted (non-expired) map.
		TextChatService.DescendantAdded:Connect(function(d)
			if not d:IsA("TextSource") then return end
			local mute = mutedUserIds[(d :: any).UserId]
			if not mute then return end
			if mute.until_unix and os.time() >= mute.until_unix then return end
			pcall(function()
				(d :: any).CanSend = false
			end)
		end)
		state.logger.debug("Mute: TextSource DescendantAdded re-apply registered (rejoin-safe)")
	else
		-- Legacy Chat path. Player:Chatted fires per-player, but suppressing
		-- after the fact still shows the message in other players' chat.
		-- The supported hook is ChatService:RegisterFilterMessageFunction,
		-- accessible via the ChatModules ModuleScript. Falling back to a
		-- per-player Chatted listener that re-emits empty would still leak
		-- the original message — there is no clean server-only suppression
		-- on legacy chat without a chat-handler edit. For V1 we log a
		-- warning when used on legacy and rely on the customer migrating
		-- to TextChatService (Roblox's recommended path since 2023).
		state.logger.warn(
			"Mute: legacy Chat detected — server-only mute isn't reliable on "
			.. "this chat system. Recommend customer enables TextChatService "
			.. "(Game Settings → Engine → Chat Version)."
		)
	end
end

return function(state, payload: { user_id: number?, reason: string?, duration_seconds: number? })
	bindOnce(state)

	local userId = payload.user_id
	if type(userId) ~= "number" then
		return { ok = false, error_code = "invalid_payload", error_message = "mute requires user_id" }
	end

	local until_unix: number? = nil
	if type(payload.duration_seconds) == "number" and payload.duration_seconds > 0 then
		-- 2026-05-31 — os.time() (wall-clock unix seconds), NOT os.clock()
		-- (CPU time used since the VM started). The deliver-filter self-expiry
		-- gate compares against this; os.clock drifts from real seconds, so the
		-- gate could lift/keep the mute off-schedule.
		until_unix = os.time() + payload.duration_seconds
	end

	mutedUserIds[userId] = {
		reason = payload.reason,
		until_unix = until_unix,
	}

	-- 2026-05-21 — apply true mute via TextSource.CanSend=false. This is the
	-- actual block; ShouldDeliverCallback (in bindOnce) is now defence-in-
	-- depth for the brief window before CanSend propagates, AND covers the
	-- legacy chat path which has no equivalent.
	local channelsMuted = 0
	if state.chatVersion == "TextChatService" then
		channelsMuted = setCanSendForUser(userId, false, state.logger)
	end

	-- If a duration was specified, schedule the unmute. Spawned task so it
	-- doesn't block the command response. os.time-based gate inside checks
	-- mutedUserIds[userId] is still our entry — re-mutes (same userId muted
	-- twice) supersede the previous timer cleanly.
	if until_unix then
		local entry = mutedUserIds[userId]
		task.delay(payload.duration_seconds, function()
			-- Make sure the mute we're expiring is still the one we set.
			if mutedUserIds[userId] == entry then
				mutedUserIds[userId] = nil
				if state.chatVersion == "TextChatService" then
					setCanSendForUser(userId, true, state.logger)
				end
				state.logger.info(string.format("Mute expired for user_id=%d (was %ds)",
					userId, payload.duration_seconds))
			end
		end)
	end

	-- Friendly logging — show the player's name if they're currently here.
	local player = Players:GetPlayerByUserId(userId)
	if player then
		state.logger.info(string.format(
			"Muted %s (%d) — reason=%s, duration=%s, channels=%d",
			player.Name, userId,
			tostring(payload.reason),
			until_unix and tostring(payload.duration_seconds) .. "s" or "permanent",
			channelsMuted))

		-- 2026-05-21 — notify the muted player via WarnToast banner.
		--
		-- Without this, mute is invisible from the muted player's POV:
		-- Roblox always echoes a sender's own messages back to them
		-- regardless of ShouldDeliverCallback, so the muted player types,
		-- sees their own text in chat, and assumes mute is broken.
		-- The toast tells them what's happening + how long.
		local durationLabel
		if payload.duration_seconds and payload.duration_seconds > 0 then
			local m = math.floor(payload.duration_seconds / 60)
			if m >= 60 then
				durationLabel = string.format("%d hour%s", math.floor(m / 60), m >= 120 and "s" or "")
			elseif m >= 1 then
				durationLabel = string.format("%d minute%s", m, m == 1 and "" or "s")
			else
				durationLabel = string.format("%d seconds", payload.duration_seconds)
			end
		else
			durationLabel = "the rest of this session"
		end
		local message = string.format("You've been muted for %s.", durationLabel)
		if payload.reason and payload.reason ~= "" then
			message = message .. " Reason: " .. payload.reason
		end
		pcall(function()
			local WarnChannel = require(script.Parent.Parent.Core.WarnChannel) :: any
			WarnChannel.fireClient(player, {
				-- 2026-05-27 — kind="mute" so the redesigned client renders
				-- the dedicated top-right toast (amber, MUTED <dur> headline)
				-- instead of the bottom-center warn box. Pass duration_seconds
				-- through so the client keeps the toast visible for the
				-- whole mute (capped client-side) — without that the player
				-- forgets they're muted after the 4s auto-dismiss.
				kind = "mute",
				duration_label = durationLabel,
				duration_seconds = payload.duration_seconds,
				message = payload.reason and ("Reason: " .. payload.reason) or "You can still play — just not chat.",
			})
		end)
	else
		state.logger.info(string.format("Muted user_id=%d (not currently in server)", userId))
	end

	return {
		ok = true,
		muted_user_id = userId,
		mode = state.chatVersion,
		duration_seconds = payload.duration_seconds,
	}
end
