--!strict
--[=[
	Player snapshot — returns a curated dict about one player's session.

	Calls the dev-registered snapshot function (Roculus:registerPlayerSnapshot)
	if one exists, then merges in the default fields (identity, position, team,
	leaderstats, attributes). Default fields don't override dev-supplied ones —
	if the dev returns `{ team = "Custom" }`, that wins over Bridge's default
	team lookup.

	Payload:
	  { user_id: number }    -- which player to snapshot

	Returns:
	  { ok=true, snapshot={...} }
	  { ok=false, error_code, error_message }
]=]

local Players = game:GetService("Players")

local function safeCFrameXYZ(player: Player)
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return nil end
	local p = root.Position
	return { x = p.X, y = p.Y, z = p.Z }
end

local function safeAttributes(player: Player): { [string]: any }
	local out: { [string]: any } = {}
	for k, v in pairs(player:GetAttributes()) do
		-- Only ship JSON-serializable values. Skip CFrame/Vector3/etc.
		local t = type(v)
		if t == "string" or t == "number" or t == "boolean" then
			out[k] = v
		end
	end
	return out
end

local function safeLeaderstats(player: Player): { [string]: any }?
	local container = player:FindFirstChild("leaderstats")
	if not container then return nil end
	local out: { [string]: any } = {}
	for _, child in ipairs(container:GetChildren()) do
		-- IntValue / NumberValue / StringValue / BoolValue all have `.Value`.
		if child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue") or child:IsA("BoolValue") then
			out[child.Name] = child.Value
		end
	end
	return out
end

local function defaultSnapshot(player: Player): { [string]: any }
	return {
		user_id = player.UserId,
		username = player.Name,
		display_name = player.DisplayName,
		team = player.Team and player.Team.Name or nil,
		account_age_days = player.AccountAge,
		membership_type = tostring(player.MembershipType),
		position = safeCFrameXYZ(player),
		leaderstats = safeLeaderstats(player),
		attributes = safeAttributes(player),
	}
end

return function(state, payload: { user_id: number? }): { [string]: any }
	local userId = payload.user_id
	if type(userId) ~= "number" then
		return { ok = false, error_code = "invalid_payload", error_message = "snapshot requires user_id" }
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return {
			ok = false,
			error_code = "player_not_in_server",
			error_message = string.format("No player with user_id %d in this server", userId),
		}
	end

	-- Build the snapshot: default fields first, then merge dev-supplied
	-- fields on top so a dev returning `{ team = "Custom" }` wins.
	local snapshot = defaultSnapshot(player)
	if state.snapshotFn then
		local ok, custom = pcall(state.snapshotFn, player)
		if ok and type(custom) == "table" then
			for k, v in pairs(custom) do
				snapshot[k] = v
			end
		elseif not ok then
			state.logger.warn("Player snapshot function threw: " .. tostring(custom))
		end
	end

	return { ok = true, snapshot = snapshot }
end
