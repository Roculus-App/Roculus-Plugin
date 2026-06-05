--!strict
--[=[
	WarnChannel — manages the RemoteEvent used to push moderator notices to
	specific player clients.

	Two-sided contract:
	  Server (this module + Warn.lua):
	    - Creates a RemoteEvent under ReplicatedStorage at first use.
	    - On PlayerAdded, clones the companion LocalScript into PlayerGui
	      so the client side has a listener bound.
	    - `fireClient(player, payload)` sends a structured warn notice.
	  Client (ClientCompanion/WarnToast.client.lua):
	    - Listens on the RemoteEvent.
	    - Renders a toast (Warn) or banner (Announce) UI per payload.

	Why route Announce-on-legacy-chat through here too: legacy Chat has no
	clean server-side "system message to all" API. Falling back to a
	client-side renderer over the same RemoteEvent gives us a consistent
	UX regardless of chat system. The downside is the customer needs the
	companion client script installed — which the Bridge handles
	automatically by cloning it to PlayerGui at PlayerAdded.

	Companion script location: `ClientCompanion/WarnToast.client.lua` —
	the `.client.lua` suffix tells Rojo to build it as a LocalScript.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WarnChannel = {}

local REMOTE_NAME = "RoculusBridge_WarnChannel"
local GUI_NAME = "RoculusBridge_WarnToast"
local started = false
local remote: RemoteEvent? = nil

local function ensureRemote(): RemoteEvent
	if remote then return remote end
	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		remote = existing
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = REMOTE_NAME
	r.Parent = ReplicatedStorage
	remote = r
	return r
end

local function findCompanionScript(): LocalScript?
	-- The companion LocalScript is synced via Rojo to a child of the runtime
	-- ModuleScript. From the perspective of THIS file (Core/WarnChannel.lua),
	-- it's at `script.Parent.Parent.ClientCompanion.WarnToast`. We resolve
	-- it relative to the module to keep the path stable across install
	-- methods (Studio plugin install, Rojo sync, .rbxm drag).
	local scriptInst = script
	local runtime = scriptInst.Parent.Parent -- ServerScriptService.RoculusBridge
	local companions = runtime:FindFirstChild("ClientCompanion")
	if not companions then return nil end
	local toast = companions:FindFirstChild("WarnToast")
	if toast and toast:IsA("LocalScript") then
		return toast
	end
	return nil
end

local function installCompanionForPlayer(player: Player, template: LocalScript)
	-- Avoid duplicate install if the player reconnected mid-session.
	local existing = player:FindFirstChild("PlayerGui") and
		player.PlayerGui:FindFirstChild(GUI_NAME)
	if existing then return end

	-- We host the LocalScript inside a ScreenGui so it has a sensible parent
	-- chain and gets the lifecycle (ResetOnSpawn=false) we want.
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local cloned = template:Clone()
	cloned.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
end

function WarnChannel.start(state): ()
	if started then return end
	started = true

	ensureRemote()

	local template = findCompanionScript()
	if not template then
		state.logger.warn(
			"WarnChannel: ClientCompanion/WarnToast.client.lua not found in the "
			.. "SDK install. Warn + legacy-Announce client toasts will be no-ops."
		)
		return
	end

	-- Install for current + future players.
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(installCompanionForPlayer, p, template)
	end
	Players.PlayerAdded:Connect(function(p)
		installCompanionForPlayer(p, template)
	end)

	state.logger.debug("WarnChannel: companion script ready, RemoteEvent armed")
end

--[=[
	Fire a notice to a specific player. Payload schema (kept loose so the
	companion script can render multiple kinds):
	  { kind = "warn" | "announce", message: string, title: string?, ... }
]=]
function WarnChannel.fireClient(player: Player, payload: { [string]: any }): ()
	local r = ensureRemote()
	r:FireClient(player, payload)
end

return WarnChannel
