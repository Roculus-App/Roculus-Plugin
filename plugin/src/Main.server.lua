--!strict
--[=[
	Plugin entry point — Roact rewrite, 2026-05-27.

	Mounts the PluginPane (Roact tree mirroring /dev/bridge-plugin-design)
	inside a DockWidgetPluginGui. State flows via plugin/src/State.lua;
	auth flows via plugin/src/PluginAuth.lua (which wraps the runtime
	SDK's Auth module).

	Wipes the old paste-token-and-write-snippet flow (InstallPanel +
	BridgeInstaller + BootstrapWriter + TokenValidator + Inspector). The
	new pane handles connection state directly.
]=]

local pluginRoot = script.Parent

local Config = require(pluginRoot:WaitForChild("Config"))
local State = require(pluginRoot:WaitForChild("State"))
local PluginAuth = require(pluginRoot:WaitForChild("PluginAuth"))
local Roact = require(pluginRoot:WaitForChild("Roact"))
local PluginPane = require(pluginRoot:WaitForChild("Ui"):WaitForChild("PluginPane"))

-- Bind the plugin global + the bundled runtime to PluginAuth. The
-- runtime tree is what Installer clones into ServerScriptService on
-- successful connect.
local embeddedRuntime = pluginRoot:WaitForChild("EmbeddedRuntime")
PluginAuth.bind(plugin, embeddedRuntime)

-- 1. Toolbar + button ──────────────────────────────────────────────────
local toolbar = (plugin :: any):CreateToolbar("Roculus")
local button = toolbar:CreateButton(
	"Bridge",
	"Open the Roculus Bridge panel",
	-- 2026-06-02 — toolbar icon = the IMAGE id 90918277397692, NOT the Creator
	-- Store / Decal id 76878502028382 (a CreateButton icon can't load a Decal id →
	-- "Unable to load plugin icon"). Resolved by LoadAsset-ing the decal in Studio
	-- and reading its Texture; ContentProvider:PreloadAsync confirms 90918277397692
	-- = Success, 76878502028382 = Failure.
	"rbxassetid://90918277397692"
)
button.ClickableWhenViewportHidden = true

-- 2. Dock widget ───────────────────────────────────────────────────────
-- 2026-05-30: bumped 360→420 wide (+ min 300→360) per user — the panel read
-- too small/cramped. Taller min too so controls never crush when docked.
-- 2026-06-01: bigger controls → bigger pane. 2026-06-02: scaled back DOWN with
-- the controls (user: "components smaller") — Default 480×620 → 440×560, min
-- 400×440 → 360×400 to match the 32px controls + 44px titlebar in the revamp.
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,  -- initially enabled
	false,  -- override previous state
	440,
	560,
	360,
	400
)

local widget = (plugin :: any):CreateDockWidgetPluginGui("RoculusBridge_Panel", widgetInfo)
widget.Title = "Roculus Bridge"
widget.Name = "RoculusBridge_Panel"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- 3. Open-dashboard handler (used by NotConnected / Error states) ──────
local function onOpenDashboard()
	local url = Config.dashboardTokenUrl(game.PlaceId)
	-- A plugin CAN'T open a browser: GuiService:OpenBrowserWindow needs the
	-- RobloxScript capability (core-scripts only) and throws for plugins —
	-- "lacking capability RobloxScript" (tested live 2026-05-31). And Studio's
	-- Output doesn't make printed URLs clickable. So the realistic best is to
	-- copy the URL to the clipboard + print one clean line; the toast tells
	-- the user to paste it. `setclipboard` is a plugin global but isn't on
	-- every Studio build, so it's pcall-guarded.
	local copiedToClipboard = type(setclipboard) == "function" and (pcall(setclipboard, url) and true or false)
	print("[Roculus] Dashboard URL: " .. url)
	if copiedToClipboard then
		State.fireToast("Dashboard URL copied — paste it in your browser")
	else
		State.fireToast("Dashboard URL printed in Output ↓ — copy it to your browser")
	end
end

-- 4. Mount Roact tree ──────────────────────────────────────────────────
local handle: any = nil
local function ensureMounted()
	if handle then return end
	handle = Roact.mount(
		Roact.createElement(PluginPane, { onOpenDashboard = onOpenDashboard }),
		widget,
		"RoculusBridgePane"
	)
end

local function teardown()
	if handle then
		Roact.unmount(handle)
		handle = nil
	end
end

-- 5. Restore previously-paired state on plugin boot ────────────────────
-- If a refresh token was saved in plugin:SetSetting from a prior session,
-- show the auto_prompt banner instead of the empty NotConnected state.
-- The user can Reconnect with one click, or dismiss.
local storedRefresh = PluginAuth.getStoredRefreshToken()
if storedRefresh then
	State.set({ status = State.STATES.AUTO_PROMPT })
end

-- 5b. Update-available poll. Check the backend's latest version on boot and
-- every 30 min while the plugin is loaded, so the titlebar dot reflects a new
-- release even if you publish one mid-session (the old code only checked once,
-- at token paste). Best-effort; silent if HttpService is off.
task.spawn(function()
	while true do
		pcall(PluginAuth.checkLatestVersion)
		task.wait(30 * 60)
	end
end)

-- 6. Wire button → toggle widget ───────────────────────────────────────
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	if widget.Enabled then
		ensureMounted()
		-- 2026-06-01 — re-poll the backend's latest version every time the panel
		-- opens (not just on boot + the 30-min loop), so the version state is
		-- fresh the moment you look (user: "doesn't recheck enough"). Best-effort;
		-- silent if HttpService is off.
		task.spawn(function() pcall(PluginAuth.checkLatestVersion) end)
	end
end)

-- If the widget was open from the previous Studio session, mount immediately.
if widget.Enabled then
	ensureMounted()
end

-- 7. Cleanup on plugin unload (re-install / disable / Studio close) ────
(plugin :: any).Unloading:Connect(teardown)

-- The build tag lets a restart be VERIFIED from the Output console: Studio does
-- NOT hot-reload a local plugin when its .rbxmx changes — you must fully QUIT the
-- Studio process (not just close the place) and reopen. If this tag prints, the
-- new build loaded; if the old line (no build tag) prints, Studio kept the stale one.
print(string.format(
	"[Roculus] Plugin loaded — v%s, SDK v%s · build 2026-06-04-latest-version-fix (Settings Latest-version row now reads shared state). Click the Bridge toolbar button.",
	Config.pluginVersion,
	Config.runtimeVersion
))
