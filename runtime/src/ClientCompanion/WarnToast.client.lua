--!strict
--[=[
	Client-side companion for WarnChannel.

	2026-05-27 redesign — drops AI tells: emoji icons, "colored border
	on a dark card" chrome. Replaced with a flat panel + 4px accent
	strip on the LEFT edge (BedWars / TDS / Phantom Forces convention).
	Single shared `buildPanel` builds the chrome; per-kind functions
	fill the body.

	Listens on `RoculusBridge_WarnChannel` and renders one of four kinds:

	  { kind = "warn",     message: string, title: string?, require_ack: bool? }
	  { kind = "announce", message: string, title: string?, color: string? }
	  { kind = "mute",     duration_label: string, message: string? }
	  { kind = "suspend",  duration_label: string, reason: string?, countdown: number?,
	                       lifts_at: string?, appeal_url: string? }

	Anchor points per kind:
	  - warn      center modal, full-screen dim, blue (Acknowledge)
	  - announce  top, full-width band
	  - mute      top-right, 280px ephemeral
	  - suspend   center, full-screen dim + countdown
]=]

-- Plugin-context guard — see comment in repo history; if our parent is
-- not a real ScreenGui (e.g. we're the template copy inside the
-- plugin's EmbeddedRuntime tree), bail.
if not script.Parent or not script.Parent:IsA("ScreenGui") then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local REMOTE_NAME = "RoculusBridge_WarnChannel"
local AUTO_DISMISS_WARN_S = 8
-- Mute is persistent by design — the player needs to keep seeing it so
-- they don't think mute is broken when their own chat echoes back
-- locally (Roblox quirk). If payload.duration_seconds is set we honour
-- it (capped at 30 min so a 7-day mute doesn't sit on screen forever).
-- If absent (permanent mute), we use the 30-min cap as the dismiss.
local MUTE_FALLBACK_TTL_S = 30 * 60
local MUTE_MAX_VISIBLE_S = 30 * 60
-- 2026-06-01 — announce auto-dismiss is now driven by the dashboard's
-- `display_seconds` payload field. AUTO_DISMISS_ANNOUNCE_S is the fallback
-- when it's missing or not a positive number; MIN/MAX clamp a bad value so
-- it can't pin the banner off-screen forever (or flash by too fast to read).
local AUTO_DISMISS_ANNOUNCE_S = 8
local ANNOUNCE_MIN_VISIBLE_S = 3
local ANNOUNCE_MAX_VISIBLE_S = 120
local DEFAULT_SUSPEND_COUNTDOWN_S = 8

local screenGui = script.Parent :: ScreenGui

-- ────────────────────────────────────────────────────────────────────
-- Theme — mirrors /dev/ingame-overlay-design mockup tokens
-- ────────────────────────────────────────────────────────────────────
-- 2026-05-27 (v3) — accent palette swung from amber → blue per user
-- feedback "bro our site has blue and black coloring". Dashboard uses
-- sky-500 (#0EA5E9) for accent surfaces; keeping the same hex in-game
-- makes the warn/mute toasts visually match the moderation panel
-- chrome. `amber` retained only as a deprecated reference; new builders
-- use `blue`. Red stays semantic for Suspend (danger/disconnect).
local THEME = {
	panelBg = Color3.fromRGB(15, 17, 21),       -- near-black, NOT pure
	panelStroke = Color3.fromRGB(255, 255, 255), -- with low alpha applied via UIStroke.Transparency
	blue = Color3.fromHex("0EA5E9"),             -- dashboard accent (sky-500)
	amber = Color3.fromHex("F5A524"),            -- DEPRECATED — kept for fallback callers
	red = Color3.fromHex("DC2626"),
	navy = Color3.fromHex("506EC8"),
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(255, 255, 255),     -- with TextTransparency 0.22
	textMuted = Color3.fromRGB(255, 255, 255),   -- with TextTransparency 0.45
}

-- ────────────────────────────────────────────────────────────────────
-- buildPanel — the shared chrome (panel + 4px left accent strip +
-- hairline stroke + UICorner with sharp-left). All four kinds compose
-- this and only differ in body content + anchor point.
-- ────────────────────────────────────────────────────────────────────
-- 2026-05-27 — DROPPED AutomaticSize.Y on the panel. The accent strip
-- child uses Scale.Y = 1 (100% of parent height); combined with the
-- parent's AutomaticSize.Y this created a layout feedback loop that
-- blew the panel up to the full ScreenGui height (visible bug: warn
-- toast rendered as a full-height vertical strip).
--
-- 2026-05-27 (v2) — Structural fix. The accent strip was still a
-- direct child of the panel alongside the text labels, and the
-- UIListLayout on the panel was including the strip as its first
-- element. With Size.Y.Scale=1, the strip consumed the full vertical
-- space inside the layout → all text + buttons got pushed BELOW the
-- panel's bottom edge (visible bug: text/button rendered outside the
-- dark card, often off-screen).
--
-- New structure:
--   Panel (sized + background + UICorner + UIStroke)
--   ├── AccentStrip       (manual position, NOT in any layout)
--   └── Content           (UIListLayout + UIPadding live HERE)
--        ├── Eyebrow
--        ├── Title
--        ├── Body
--        └── AckButton
--
-- buildPanel now returns BOTH the outer panel (for parenting +
-- positioning + tweens) and the inner content frame (where labels are
-- added). Callers MUST add labels to content, not panel.
local function buildPanel(opts: { accent: Color3, width: number, height: number, anchor: Vector2, position: UDim2, fullBleed: boolean? }): (Frame, Frame)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = THEME.panelBg
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.AnchorPoint = opts.anchor
	frame.Position = opts.position
	frame.Size = UDim2.new(0, opts.width, 0, opts.height)
	frame.ClipsDescendants = false -- explicit: content overflow remains visible

	if not opts.fullBleed then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = THEME.panelStroke
	stroke.Transparency = 0.92 -- ~8% alpha — hairline
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Miter
	stroke.Parent = frame

	-- AccentStrip — DIRECT child of panel, positioned manually. Lives
	-- OUTSIDE the content frame so it's not part of the UIListLayout.
	local strip = Instance.new("Frame")
	strip.Name = "AccentStrip"
	strip.BackgroundColor3 = opts.accent
	strip.BorderSizePixel = 0
	strip.AnchorPoint = Vector2.new(0, 0)
	strip.Position = UDim2.new(0, 0, 0, 0)
	strip.Size = UDim2.new(0, 4, 1, 0)
	strip.ZIndex = 2
	strip.Parent = frame

	-- Top-edge highlight — 1px of light catching the panel's top edge (the
	-- CANON card treatment); reads as a crafted surface over the bright game.
	local topHighlight = Instance.new("Frame")
	topHighlight.Name = "TopHighlight"
	topHighlight.BackgroundColor3 = THEME.panelStroke
	topHighlight.BackgroundTransparency = 0.93
	topHighlight.BorderSizePixel = 0
	topHighlight.Position = UDim2.new(0, 0, 0, 0)
	topHighlight.Size = UDim2.new(1, 0, 0, 1)
	topHighlight.ZIndex = 3
	topHighlight.Parent = frame

	-- Content holder — where the UIListLayout + UIPadding live. Sized
	-- to fill the panel minus the 4px strip on the left.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.AnchorPoint = Vector2.new(0, 0)
	content.Position = UDim2.new(0, 4, 0, 0)
	content.Size = UDim2.new(1, -4, 1, 0)
	content.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, opts.fullBleed and 10 or 14)
	pad.PaddingBottom = UDim.new(0, opts.fullBleed and 10 or 14)
	pad.PaddingLeft = UDim.new(0, opts.fullBleed and 14 or 14) -- 14 inside content (after 4px strip → 18 from panel edge)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = opts.fullBleed and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, opts.fullBleed and 12 or 4)
	if opts.fullBleed then
		-- 2026-05-27 (v3) — center horizontally too. Announce was left-
		-- justified which placed the eyebrow + divider + message hugging
		-- the left edge of the screen-wide banner; centering reads as
		-- the spec intent (sticky banner across the top).
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	layout.Parent = content

	return frame, content
end

local function makeEyebrow(text: string, accent: Color3, layoutOrder: number): TextLabel
	local label = Instance.new("TextLabel")
	label.LayoutOrder = layoutOrder
	label.BackgroundTransparency = 1
	label.Text = string.upper(text)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextColor3 = accent
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Size = UDim2.new(1, 0, 0, 14)
	label.AutomaticSize = Enum.AutomaticSize.Y
	return label
end

local function makeTitle(text: string, size: number, layoutOrder: number): TextLabel
	local label = Instance.new("TextLabel")
	label.LayoutOrder = layoutOrder
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Enum.Font.GothamBold
	label.TextSize = size
	label.TextColor3 = THEME.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Size = UDim2.new(1, 0, 0, size + 4)
	label.AutomaticSize = Enum.AutomaticSize.Y
	return label
end

local function makeBody(text: string, layoutOrder: number, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.LayoutOrder = layoutOrder
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextColor3 = color or THEME.textDim
	label.TextTransparency = 0.18
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Size = UDim2.new(1, 0, 0, 18)
	label.AutomaticSize = Enum.AutomaticSize.Y
	return label
end

local function makeAckButton(label: string, accent: Color3): TextButton
	local button = Instance.new("TextButton")
	button.LayoutOrder = 99
	button.BackgroundColor3 = accent
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = string.upper(label)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	-- 2026-05-31 — dark text on the blue fill (the dashboard PrimaryButton
	-- recipe). On sky-500 #0EA5E9, dark lands ~6.8:1 vs white-on-blue ~2.8:1,
	-- so dark actually WINS contrast (white fails AA here). Warn acks are blue.
	button.TextColor3 = Color3.fromHex("04141D")
	button.Size = UDim2.new(0, 150, 0, 30)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = button
	return button
end

-- ────────────────────────────────────────────────────────────────────
-- WARN — big BLUE centered modal (full-screen dim) + Acknowledge button
-- 2026-06-01 — was a bottom-center toast; user wants the suspension
-- modal's layout in blue, centered: "use the suspension component ...
-- blue version big in the middle of the screen." Mirrors buildSuspend's
-- dim container + centered panel, but a blue accent + an Acknowledge
-- button instead of a kick countdown (a warning isn't terminal).
-- ────────────────────────────────────────────────────────────────────
local function buildWarn(payload: { [string]: any }): Frame
	-- 2026-06-03 redesign — the moderator's MESSAGE is the headline (no separate
	-- generic "Moderator warning" title that only duplicated the eyebrow), and
	-- the panel is CONTENT-SIZED so there's no dead box under the button (user:
	-- "stretched big and there is an under space with a lot of blank space").
	--
	-- Can't reuse buildPanel here: its 4px accent strip is Size.Y.Scale = 1, so
	-- AutomaticSize.Y on the panel feedback-loops to full-screen height (see the
	-- buildPanel header note). Instead the rail is two nested frames — outer =
	-- the accent colour, inner = panelBg inset 4px on the left — so the 4px of
	-- outer showing IS the rail and nothing has a scale height to loop on. Both
	-- frames AutomaticSize.Y, driven by the inner UIListLayout's content.
	local message = (type(payload.message) == "string" and #payload.message > 0) and payload.message
		or (type(payload.title) == "string" and #payload.title > 0) and payload.title
		or "A moderator has issued you a warning."

	-- Full-screen dim so the warning is centered + unmissable. Lighter than
	-- the suspend dim — the game stays faintly visible behind it.
	local container = Instance.new("Frame")
	container.BackgroundColor3 = Color3.new(0, 0, 0)
	container.BackgroundTransparency = 0.42
	container.BorderSizePixel = 0
	container.Size = UDim2.fromScale(1, 1)
	container.Position = UDim2.fromScale(0, 0)
	container.ZIndex = 10

	-- Outer = the accent (its left 4px shows as the rail); content-sized.
	local panel = Instance.new("Frame")
	panel.BackgroundColor3 = THEME.blue
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0, 420, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.ZIndex = 11
	panel.Parent = container

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 4)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = THEME.panelStroke
	panelStroke.Transparency = 0.92
	panelStroke.Thickness = 1
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel

	-- Inner surface — inset 4px on the left so the outer accent shows as the rail.
	local inner = Instance.new("Frame")
	inner.BackgroundColor3 = THEME.panelBg
	inner.BorderSizePixel = 0
	inner.AnchorPoint = Vector2.new(1, 0)
	inner.Position = UDim2.new(1, 0, 0, 0)
	inner.Size = UDim2.new(1, -4, 0, 0)
	inner.AutomaticSize = Enum.AutomaticSize.Y
	inner.ZIndex = 11
	inner.Parent = panel

	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(0, 4)
	innerCorner.Parent = inner

	-- Top-edge highlight (the CANON card treatment).
	local topHighlight = Instance.new("Frame")
	topHighlight.BackgroundColor3 = THEME.panelStroke
	topHighlight.BackgroundTransparency = 0.93
	topHighlight.BorderSizePixel = 0
	topHighlight.Position = UDim2.new(0, 0, 0, 0)
	topHighlight.Size = UDim2.new(1, 0, 0, 1)
	topHighlight.ZIndex = 12
	topHighlight.Parent = inner

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 20)
	pad.PaddingBottom = UDim.new(0, 18)
	pad.PaddingLeft = UDim.new(0, 22)
	pad.PaddingRight = UDim.new(0, 22)
	pad.Parent = inner

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = inner

	makeEyebrow("Moderator Warning", THEME.blue, 1).Parent = inner

	-- The MESSAGE is the headline (what the moderator actually wrote).
	makeTitle(message, 18, 2).Parent = inner

	-- Full-width Acknowledge.
	local ack = makeAckButton("Acknowledge", THEME.blue)
	ack.LayoutOrder = 3
	ack.Size = UDim2.new(1, 0, 0, 36)
	ack.Parent = inner
	ack.MouseButton1Click:Connect(function()
		container:Destroy()
	end)

	return container
end

-- ────────────────────────────────────────────────────────────────────
-- ANNOUNCE — top, full-width band, blue accent (or payload.color)
-- ────────────────────────────────────────────────────────────────────
local function buildAnnounce(payload: { [string]: any }): Frame
	local accent = THEME.blue
	if payload.color and type(payload.color) == "string" then
		local s = string.gsub(payload.color, "#", "")
		if #s == 6 then
			local r = tonumber(s:sub(1, 2), 16)
			local g = tonumber(s:sub(3, 4), 16)
			local b = tonumber(s:sub(5, 6), 16)
			if r and g and b then accent = Color3.fromRGB(r, g, b) end
		end
	end

	-- 2026-05-27 — position dropped to Y=36 (was Y=0). At Y=0 the band
	-- rendered behind Roblox's own topbar / verify-email warning bar,
	-- which sits above any in-game ScreenGui regardless of IgnoreGuiInset.
	-- 36px clears the standard Roblox topbar height.
	local panel, content = buildPanel({
		accent = accent,
		width = 0, -- ignored; we'll set scale 1 below
		height = 54,
		anchor = Vector2.new(0, 0),
		position = UDim2.new(0, 0, 0, 36),
		fullBleed = true,
	})
	-- Full-bleed: stretch to viewport width
	panel.Size = UDim2.new(1, 0, 0, 54)

	-- 2026-05-27 (v3) — eyebrow font size bumped from 11 → 13 per user
	-- "title itself should be thicker". 13px is the largest size where
	-- the all-caps GothamBold eyebrow stays readable as a label rather
	-- than competing with the message text for visual weight.
	local eyebrow = makeEyebrow(payload.title or "Server Announcement", accent, 1)
	eyebrow.TextSize = 15
	-- AutomaticSize.X comes from makeEyebrow default (Y only) — but the
	-- horizontal full-bleed layout needs the eyebrow to size to its own
	-- text width, otherwise it'd consume 1 scale of the band's horizontal
	-- track. Override Size + AutomaticSize for the announce case.
	eyebrow.Size = UDim2.new(0, 0, 1, 0)
	eyebrow.AutomaticSize = Enum.AutomaticSize.X
	eyebrow.Parent = content

	-- Thin hairline divider between eyebrow + message
	local divider = Instance.new("Frame")
	divider.LayoutOrder = 2
	divider.BackgroundColor3 = THEME.panelStroke
	divider.BackgroundTransparency = 0.85
	divider.BorderSizePixel = 0
	divider.Size = UDim2.new(0, 1, 0, 22)
	divider.Parent = content

	local msg = Instance.new("TextLabel")
	msg.LayoutOrder = 3
	msg.BackgroundTransparency = 1
	msg.Text = payload.message or ""
	msg.Font = Enum.Font.GothamBold
	msg.TextSize = 17
	msg.TextColor3 = THEME.text
	msg.TextXAlignment = Enum.TextXAlignment.Left
	msg.AutomaticSize = Enum.AutomaticSize.X
	msg.Size = UDim2.new(0, 0, 1, 0)
	msg.Parent = content

	return panel
end

-- ────────────────────────────────────────────────────────────────────
-- MUTE — top-right 280px ephemeral, amber accent, "MUTED 1h" headline
-- ────────────────────────────────────────────────────────────────────
-- Format seconds into a compact countdown label:
--   <60s     → "Ns"
--   <1h      → "M:SS"   (e.g. "9:42")
--   ≥1h      → "Hh Mm"  (e.g. "1h 23m")
local function formatRemaining(s: number): string
	if s <= 0 then return "0s" end
	if s < 60 then return string.format("%ds", s) end
	local m = math.floor(s / 60)
	local rem = s - m * 60
	if m < 60 then
		return string.format("%d:%02d", m, rem)
	end
	local h = math.floor(m / 60)
	return string.format("%dh %dm", h, m - h * 60)
end

local function buildMute(payload: { [string]: any }): Frame
	-- 2026-05-27 (v3) — position dropped from Y=50 to Y=240. At Y=50 the
	-- toast sat behind Roblox's leaderboard (CoreGui has higher
	-- DisplayOrder than any in-game ScreenGui — we cannot overlay it).
	-- 240 clears even a fully populated 10-player leaderboard. Accent
	-- swapped from amber to blue to match the dashboard's palette.
	local panel, content = buildPanel({
		accent = THEME.blue,
		width = 280,
		height = 64,
		anchor = Vector2.new(1, 0),
		position = UDim2.new(1, -10, 0, 240),
	})

	-- Two-element header row: "MUTED" + live countdown in mono blue
	local header = Instance.new("Frame")
	header.LayoutOrder = 1
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 18)
	local headerLayout = Instance.new("UIListLayout")
	headerLayout.FillDirection = Enum.FillDirection.Horizontal
	headerLayout.Padding = UDim.new(0, 10)
	headerLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	headerLayout.Parent = header

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.BackgroundTransparency = 1
	title.Text = "MUTED"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextColor3 = THEME.text
	title.AutomaticSize = Enum.AutomaticSize.X
	title.Size = UDim2.new(0, 0, 1, 0)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header

	-- 2026-05-27 (v3) — live ticker. If payload.duration_seconds is set,
	-- spawn a task that updates the label every second until it hits 0.
	-- Falls back to payload.duration_label for permanent mutes (no
	-- duration_seconds) where there's nothing to count down.
	local duration = Instance.new("TextLabel")
	duration.LayoutOrder = 2
	duration.BackgroundTransparency = 1
	duration.Font = Enum.Font.Code
	duration.TextSize = 12
	duration.TextColor3 = THEME.blue
	duration.AutomaticSize = Enum.AutomaticSize.X
	duration.Size = UDim2.new(0, 0, 1, 0)
	duration.TextXAlignment = Enum.TextXAlignment.Left

	local durationSec = tonumber(payload.duration_seconds)
	if durationSec and durationSec > 0 then
		duration.Text = formatRemaining(durationSec)
		task.spawn(function()
			local remaining = durationSec
			while remaining > 0 and duration.Parent do
				task.wait(1)
				remaining -= 1
				if duration and duration.Parent then
					duration.Text = formatRemaining(math.max(0, remaining))
				end
			end
		end)
	else
		duration.Text = payload.duration_label or "permanent"
	end
	duration.Parent = header

	header.Parent = content

	makeBody(payload.message or "You can still play — just not chat.", 2).Parent = content
	return panel
end

-- ────────────────────────────────────────────────────────────────────
-- SUSPEND — center modal, full-screen dim, red accent, countdown
-- ────────────────────────────────────────────────────────────────────
local function buildSuspend(payload: { [string]: any }): Frame
	-- Full-screen dim parent
	local container = Instance.new("Frame")
	container.BackgroundColor3 = Color3.new(0, 0, 0)
	container.BackgroundTransparency = 0.28
	container.BorderSizePixel = 0
	container.Size = UDim2.fromScale(1, 1)
	container.Position = UDim2.fromScale(0, 0)
	container.ZIndex = 10

	local panel, content = buildPanel({
		accent = THEME.red,
		width = 460,
		height = 292,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
	})
	panel.ZIndex = 11
	panel.Parent = container

	-- Override pad — suspend modal needs more breathing room. The
	-- UIPadding lives on the Content frame now (not the panel), so we
	-- find + replace it there.
	local existingPad = content:FindFirstChildOfClass("UIPadding")
	if existingPad then existingPad:Destroy() end
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 22)
	pad.PaddingBottom = UDim.new(0, 18)
	pad.PaddingLeft = UDim.new(0, 26) -- inside content (after 4px strip → 30 from panel edge)
	pad.PaddingRight = UDim.new(0, 26)
	pad.Parent = content

	makeEyebrow("Suspended", THEME.red, 1).Parent = content

	-- 2026-05-27 (v3) — duration headline bumped 32 → 36 to match the
	-- spec mockup. Roblox renders 36 cleanly enough on GothamBold for
	-- the dramatic "this is how long" moment.
	makeTitle(payload.duration_label or "—", 36, 2).Parent = content

	if payload.reason and #payload.reason > 0 then
		local body = makeBody(payload.reason, 3)
		body.Parent = content
	end

	-- Hairline divider before detail strip
	local divider1 = Instance.new("Frame")
	divider1.LayoutOrder = 10
	divider1.BackgroundColor3 = THEME.panelStroke
	divider1.BackgroundTransparency = 0.85
	divider1.BorderSizePixel = 0
	divider1.Size = UDim2.new(1, 0, 0, 1)
	divider1.Parent = content

	-- Shared row factory for the detail strip (Lifts + Appeals).
	-- 2026-05-27 (v3) — added Appeals row per spec mockup, which always
	-- includes a label + appeal URL even when lifts_at is absent
	-- (permanent suspensions still get an appeal route).
	local function makeDetailRow(label: string, value: string, order: number, mono: boolean): Frame
		local row = Instance.new("Frame")
		row.LayoutOrder = order
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 22)

		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Parent = row

		local lblNode = Instance.new("TextLabel")
		lblNode.LayoutOrder = 1
		lblNode.BackgroundTransparency = 1
		lblNode.Text = label
		lblNode.Font = Enum.Font.Gotham
		lblNode.TextSize = 12
		lblNode.TextColor3 = THEME.textMuted
		lblNode.TextTransparency = 0.45
		lblNode.Size = UDim2.new(0.5, 0, 1, 0)
		lblNode.TextXAlignment = Enum.TextXAlignment.Left
		lblNode.Parent = row

		local valNode = Instance.new("TextLabel")
		valNode.LayoutOrder = 2
		valNode.BackgroundTransparency = 1
		valNode.Text = value
		valNode.Font = mono and Enum.Font.Code or Enum.Font.Gotham
		valNode.TextSize = 12
		valNode.TextColor3 = THEME.text
		valNode.Size = UDim2.new(0.5, 0, 1, 0)
		valNode.TextXAlignment = Enum.TextXAlignment.Right
		valNode.Parent = row

		return row
	end

	if payload.lifts_at then
		makeDetailRow("Lifts", payload.lifts_at, 11, true).Parent = content
	end

	-- Appeals row — present even when lifts_at is absent. Uses the
	-- customer's configured appeal_url, falling back to the Roculus
	-- default. The label is non-mono because URLs read better in the
	-- proportional Gotham face.
	local appealUrl = payload.appeal_url or "roculus.app/appeal"
	makeDetailRow("Appeals", appealUrl, 12, false).Parent = content

	-- Hairline + countdown row
	local divider2 = Instance.new("Frame")
	divider2.LayoutOrder = 20
	divider2.BackgroundColor3 = THEME.panelStroke
	divider2.BackgroundTransparency = 0.85
	divider2.BorderSizePixel = 0
	divider2.Size = UDim2.new(1, 0, 0, 1)
	divider2.Parent = content

	local cdRow = Instance.new("Frame")
	cdRow.LayoutOrder = 21
	cdRow.BackgroundTransparency = 1
	cdRow.Size = UDim2.new(1, 0, 0, 26)
	local cdLayout = Instance.new("UIListLayout")
	cdLayout.FillDirection = Enum.FillDirection.Horizontal
	cdLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	cdLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cdLayout.Parent = cdRow

	local cdLabel = Instance.new("TextLabel")
	cdLabel.BackgroundTransparency = 1
	cdLabel.Text = "DISCONNECTING IN"
	cdLabel.Font = Enum.Font.GothamBold
	cdLabel.TextSize = 11
	cdLabel.TextColor3 = THEME.textMuted
	cdLabel.TextTransparency = 0.45
	cdLabel.Size = UDim2.new(1, -60, 1, 0)
	cdLabel.TextXAlignment = Enum.TextXAlignment.Left
	cdLabel.Parent = cdRow

	local cdValue = Instance.new("TextLabel")
	cdValue.Name = "Countdown"
	cdValue.BackgroundTransparency = 1
	cdValue.Text = tostring(payload.countdown or DEFAULT_SUSPEND_COUNTDOWN_S) .. "s"
	cdValue.Font = Enum.Font.Code
	cdValue.TextSize = 18
	cdValue.TextColor3 = THEME.red
	cdValue.Size = UDim2.new(0, 60, 1, 0)
	cdValue.TextXAlignment = Enum.TextXAlignment.Right
	cdValue.Parent = cdRow

	cdRow.Parent = content

	-- Tick the countdown down each second. Server-side does the actual
	-- player:Kick() after the countdown elapses; we just decorate.
	local remaining = tonumber(payload.countdown) or DEFAULT_SUSPEND_COUNTDOWN_S
	task.spawn(function()
		while remaining > 0 and container.Parent do
			task.wait(1)
			remaining -= 1
			if cdValue and cdValue.Parent then
				cdValue.Text = tostring(math.max(0, remaining)) .. "s"
			end
		end
	end)

	return container
end

-- ────────────────────────────────────────────────────────────────────
-- Render dispatcher
-- ────────────────────────────────────────────────────────────────────
local function show(payload: { [string]: any })
	local kind = payload.kind or "warn"
	local rootFrame: Frame

	if kind == "announce" then
		rootFrame = buildAnnounce(payload)
	elseif kind == "mute" then
		rootFrame = buildMute(payload)
	elseif kind == "suspend" then
		rootFrame = buildSuspend(payload)
	else
		rootFrame = buildWarn(payload)
	end

	rootFrame.Parent = screenGui

	-- Subtle fade-in (Quad Out, 0.18s) — matches the previous WarnToast
	-- animation curve, plays for all kinds for a consistent entrance.
	local target = rootFrame.BackgroundTransparency
	rootFrame.BackgroundTransparency = 1
	TweenService:Create(
		rootFrame,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = target }
	):Play()

	-- Auto-dismiss for ephemeral kinds. Suspend never dismisses — server
	-- kicks the player after its own countdown. Warn with require_ack
	-- waits for the click.
	local autoDismissS = nil
	if kind == "warn" and not payload.require_ack then
		autoDismissS = AUTO_DISMISS_WARN_S
	elseif kind == "mute" then
		-- Keep the mute toast visible for the full mute duration (capped
		-- at MUTE_MAX_VISIBLE_S to avoid hour+-long screen real estate
		-- hogging). Without this the player auto-dismisses at 4s and
		-- then forgets they're muted — they type, see their own chat
		-- echo locally (Roblox quirk), and assume mute is broken.
		local dur = tonumber(payload.duration_seconds)
		if dur and dur > 0 then
			autoDismissS = math.min(dur, MUTE_MAX_VISIBLE_S)
		else
			autoDismissS = MUTE_FALLBACK_TTL_S
		end
	elseif kind == "announce" then
		-- Honour the dashboard's display_seconds. Clamp to [MIN, MAX] so a
		-- bad value can't pin the banner forever or flash it by; fall back to
		-- the 8s default when it's absent or not a positive number.
		local dur = tonumber(payload.display_seconds)
		if dur and dur > 0 then
			autoDismissS = math.clamp(dur, ANNOUNCE_MIN_VISIBLE_S, ANNOUNCE_MAX_VISIBLE_S)
		else
			autoDismissS = AUTO_DISMISS_ANNOUNCE_S
		end
	end

	if autoDismissS then
		task.delay(autoDismissS, function()
			if rootFrame and rootFrame.Parent then
				local fade = TweenService:Create(
					rootFrame,
					TweenInfo.new(0.18, Enum.EasingStyle.Quad),
					{ BackgroundTransparency = 1 }
				)
				fade:Play()
				fade.Completed:Wait()
				rootFrame:Destroy()
			end
		end)
	end
end

-- ────────────────────────────────────────────────────────────────────
-- Wire to the RemoteEvent
-- ────────────────────────────────────────────────────────────────────
local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME, 10)
if not remote or not remote:IsA("RemoteEvent") then
	warn("[RoculusBridge] WarnToast: RemoteEvent not found within 10s — script will not function")
	return
end

remote.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	pcall(show, payload)
end)
