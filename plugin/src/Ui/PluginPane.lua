--!nocheck
--[=[
	PluginPane — Roact port of the /dev/bridge-plugin-design mockup.

	All UI lives in this single file because the mockup is one cohesive
	pane with 13 mutually exclusive body states. Splitting across folders
	would scatter the visual reference; keeping it monolithic mirrors the
	JSX mockup's structure and makes side-by-side comparison easy.

	Architecture:
	  - Roact functional components (h = Roact.createElement shorthand)
	  - Theme tokens from script.Parent.Parent.Theme
	  - State subscription via componentDidMount / componentWillUnmount
	  - One root <PluginPane> dispatches to the matching body per status

	Variant mapping (mockup → here):
	  not_connected               → NotConnectedBody({variant="default"})
	  not_connected_paste_error   → NotConnectedBody({variant="paste_error"})
	  auto_prompt                 → AutoPromptBody
	  connecting                  → ConnectingBody
	  confirming                  → ConfirmingBody
	  connected                   → ConnectedBody({variant="steady"})
	  connected_backlog           → ConnectedBody({variant="backlog"})
	  connected_update            → ConnectedBody({variant="update"})
	                                 + titlebar dot
	  connected_mismatch          → ConnectedBody({variant="mismatch"})
	  error                       → ErrorBody({variant="auth"})
	  error_http                  → ErrorBody({variant="http_disabled"})
	  settings                    → SettingsBody
]=]

local Roact = require(script.Parent.Parent.Roact)
local Theme = require(script.Parent.Parent.Theme)
local State = require(script.Parent.Parent.State)
local PluginAuth = require(script.Parent.Parent.PluginAuth)
local Config = require(script.Parent.Parent.Config)

local HttpService = game:GetService("HttpService")

local h = Roact.createElement

-- ─────────────────────────────────────────────────────────────────────
-- Setup-step detection — the NotConnected setup flow is a 3-screen wizard
-- (Publish → enable HTTP → Connect). The step is DERIVED from live Studio
-- state at render time, never stored, so re-checking is just a re-render:
--   game.PlaceId == 0            → "publish" (place was never published)
--   HttpService.HttpEnabled==false → "http"  (HTTP is off for this place)
--   else                          → "connect"
-- Mirrors NotConnectedBody({step}) in the /dev/bridge-plugin-design mock.
-- ─────────────────────────────────────────────────────────────────────
local function detectSetupStep(): string
	if game.PlaceId == 0 then
		return "publish"
	end
	-- HttpEnabled can throw in some contexts; pcall so detection never errors.
	local ok, enabled = pcall(function()
		return HttpService.HttpEnabled
	end)
	if ok and enabled == false then
		return "http"
	end
	return "connect"
end

-- ─────────────────────────────────────────────────────────────────────
-- Style helpers
-- ─────────────────────────────────────────────────────────────────────

local function corner(radius: number)
	return h("UICorner", { CornerRadius = UDim.new(0, radius or 5) })
end

local function stroke(color: Color3, thickness: number?)
	return h("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function pad(all: number, opts: any?)
	opts = opts or {}
	return h("UIPadding", {
		PaddingTop = UDim.new(0, opts.top or all),
		PaddingBottom = UDim.new(0, opts.bottom or all),
		PaddingLeft = UDim.new(0, opts.left or all),
		PaddingRight = UDim.new(0, opts.right or all),
	})
end

local function layout(direction: string, gap: number?, opts: any?)
	opts = opts or {}
	return h("UIListLayout", {
		FillDirection = direction == "horizontal" and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = opts.horizontalAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = opts.verticalAlign or Enum.VerticalAlignment.Top,
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- Primitive widgets
-- ─────────────────────────────────────────────────────────────────────

local function PrimaryButton(props)
	local disabled = props.disabled == true
	return h("TextButton", {
		Size = props.size or UDim2.new(1, 0, 0, Theme.primaryButtonHeight),
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = disabled and Theme.button or Theme.brand,
		BorderSizePixel = 0,
		Font = Theme.fontBold,
		Text = props.text,
		TextColor3 = disabled and Theme.textMuted or Theme.brandInk,
		TextSize = 13,
		AutoButtonColor = not disabled,
		[Roact.Event.Activated] = not disabled and props.onClick or nil,
	}, { corner(6) })
end

local function SecondaryButton(props)
	return h("TextButton", {
		Size = props.size or UDim2.new(1, 0, 0, Theme.primaryButtonHeight),
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = Theme.button,
		BorderSizePixel = 0,
		Font = Theme.font,
		Text = props.text,
		TextColor3 = Theme.text,
		TextSize = 13,
		[Roact.Event.Activated] = props.onClick,
	}, { corner(6), stroke(Theme.border) })
end

local function LinkLabel(props)
	return h("TextButton", {
		Size = props.size or UDim2.new(1, 0, 0, 22),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = props.text,
		TextColor3 = Theme.link,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		[Roact.Event.Activated] = props.onClick,
	})
end

local function H2(props)
	return h("TextLabel", {
		Size = UDim2.new(1, 0, 0, props.height or 22),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		Font = Theme.fontBold,
		Text = props.text,
		TextColor3 = Theme.text,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function HelperText(props)
	return h("TextLabel", {
		Size = UDim2.new(1, 0, 0, props.height or 36),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = props.text,
		TextColor3 = Theme.textDim,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
	})
end

local function MutedFooter(props)
	return h("TextLabel", {
		Size = UDim2.new(1, 0, 0, 17),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = props.text,
		TextColor3 = Theme.textMuted,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

-- Place context — a calm, non-interactive line naming the place you're
-- about to connect (game.Name in Studio). Replaces the old raw place-ID
-- copy chip: that showed a 15-digit number styled like an editable field
-- as the first thing on the pane (awkward) AND was redundant — the
-- "Open dashboard" link already deep-links with ?place_id=, so the user
-- never needs to copy it by hand. Design principle: names, not IDs.
local function PlaceContext(props)
	return h("TextLabel", {
		Size = UDim2.new(1, 0, 0, 17),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = game.Name,
		TextColor3 = Theme.textDim,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
end

local function StatusDot(color: Color3)
	return h("Frame", {
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, { corner(5) })
end

local function ErrorBanner(props)
	-- Matches the mockup's errorBannerStyle: red tint background, red
	-- left border accent, bold title + dim body.
	return h("Frame", {
		Size = UDim2.new(1, 0, 0, props.height or 84),
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = props.tone == "warn" and Theme.warnBannerBg or Theme.errorBannerBg,
		BackgroundTransparency = props.tone == "warn" and 0.90 or 0.88,
		BorderSizePixel = 0,
	}, {
		corner(5),
		stroke(props.tone == "warn" and Theme.warn or Theme.error),
		pad(12),
		layout("vertical", 5),
		h("TextLabel", {
			Size = UDim2.new(1, 0, 0, 19),
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Font = Theme.fontBold,
			Text = props.title,
			TextColor3 = Theme.text,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		h("TextLabel", {
			Size = UDim2.new(1, 0, 1, -26),
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = props.body,
			TextColor3 = Theme.textDim,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- Body shell — every state body lives in a vertically-stacked frame
-- with consistent padding. Use the same shell so visual alignment is
-- pixel-identical to the mockup across states.
-- ─────────────────────────────────────────────────────────────────────

local function BodyShell(children)
	-- 2026-06-01: pane padding 12→16 and inter-element gap 6→8 (~20% up)
	-- so every page's content breathes against the larger controls.
	local kids = { pad(12), layout("vertical", 8) }
	for k, v in pairs(children or {}) do
		kids[k] = v
	end
	return h("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
	}, kids)
end

-- 2026-05-30: was Size (1,0,1,0) — a full-height "flex spacer" ported 1:1
-- from the mockup's CSS flex:1. In a UIListLayout that does NOT pin content
-- to the bottom; a 100%-height child eats the whole body frame and shoves
-- every element after it (the primary action buttons) clean off the bottom
-- edge of the dock widget — Connect / Disconnect / Try-again were invisible
-- in every state, which is why the pane read as empty/tiny. Now a small fixed
-- gap so content + actions top-align as one visible block (mirrors the
-- mockup's top-align treatment).
local function Spacer(order: number)
	return h("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 12),
		BackgroundTransparency = 1,
		[Roact.Children] = nil,
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- NotConnected setup flow — Publish → enable HTTP → Connect
--
-- Port of the mock's NotConnectedBody router + SetupProgress / ScreenHero
-- helpers + PublishStepBody / EnableHttpStepBody / ConnectStepBody. The
-- step is derived (detectSetupStep) at render, never stored; "re-check"
-- buttons just fire State.set({}) so PluginPane re-renders and re-detects.
--
-- Structure note vs. the mock: the React ScreenHero stacks chip → title →
-- why with CSS block flow. Here it's one self-contained Frame with an
-- internal vertical UIListLayout so it drops cleanly into BodyShell's
-- stack at a single LayoutOrder slot.
-- ─────────────────────────────────────────────────────────────────────

local SETUP_ORDER = { "publish", "http", "connect" }

-- 3-segment progress bar + "Step N of 3". Segments before the current step
-- are green (ok), the current is blue (mainButton), later ones grey
-- (inputBorder). Mirrors the mock's SetupProgress.
local function SetupProgress(props)
	local current = props.current
	local idx = 0
	for i, s in ipairs(SETUP_ORDER) do
		if s == current then
			idx = i
			break
		end
	end

	local kids = { layout("horizontal", 8, { verticalAlign = Enum.VerticalAlignment.Center }) }
	for i = 1, #SETUP_ORDER do
		-- Single-hue progress (design-review HIGH #2 — the green+blue mix read as
		-- a "rainbow" trick). Cyan fills up to and including the current step.
		local segColor
		if i <= idx then
			segColor = Theme.brand
		else
			segColor = Theme.inputBorder
		end
		kids["seg_" .. i] = h("Frame", {
			LayoutOrder = i,
			-- Three equal segments share the row minus the "Step N of 3"
			-- label (~86px now) and the 3 inter-gaps (8px each = 24). 1/3 of
			-- the remaining width each via Scale, with the fixed offset removed.
			Size = UDim2.new(1 / 3, -((86 + 24) / 3), 0, 4),
			BackgroundColor3 = segColor,
			BorderSizePixel = 0,
		}, { corner(2) })
	end
	kids.label = h("TextLabel", {
		LayoutOrder = 99,
		Size = UDim2.new(0, 86, 0, 17),
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = "Step " .. tostring(idx) .. " of 3",
		TextColor3 = Theme.textMuted,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	return h("Frame", {
		LayoutOrder = props.layoutOrder,
		Size = UDim2.new(1, 0, 0, 17),
		BackgroundTransparency = 1,
	}, kids)
end

-- Focused-screen hero: accent icon-chip + 15px title + one muted why-line.
-- The chip approximates the mock's rgba(95,163,255,0.12) fill + 0.3 border
-- with Theme.link @ low alpha (same banner-tint approach ErrorBanner uses).
-- `glyph` is a short text/emoji icon (the plugin has no lucide); see the
-- per-step call sites.
local function ScreenHero(props)
	return h("Frame", {
		LayoutOrder = props.layoutOrder,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		layout("vertical", 4),
		-- No 48×48 icon-chip (the AI feature-card tell + a 3rd accent colour).
		-- Title + one muted why-line only; the `glyph` prop is now ignored.
		title = h("TextLabel", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundTransparency = 1,
			Font = Theme.fontBold,
			Text = props.title,
			TextColor3 = Theme.text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		why = h("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 36),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = props.why,
			TextColor3 = Theme.textDim,
			-- 14px (was 13) — user "very small description i hardly notice".
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
	})
end

-- Re-check: empty patch fires subscribers (State.set loops subscribers
-- unconditionally after applying the patch — see State.lua), so PluginPane
-- re-renders and detectSetupStep runs again. No state to store.
local function recheckSetup()
	State.set({})
end

-- Step 1 — Publish. Stateless: nothing here depends on the token field.
local function PublishStepBody(props)
	return BodyShell({
		placeContext = PlaceContext({ layoutOrder = 0 }),
		progress = SetupProgress({ layoutOrder = 1, current = "publish" }),
		hero = ScreenHero({
			layoutOrder = 2,
			glyph = "⬆",
			title = "Publish this place",
			why = "Roculus pairs with a published place — and publishing is what unlocks the HTTP setting in the next step.",
		}),
		howBox = h("Frame", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Theme.titlebar,
			BorderSizePixel = 0,
		}, {
			corner(5),
			stroke(Theme.border),
			pad(10, { top = 0, bottom = 0 }),
			h("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Font = Theme.font,
				-- Just the menu path — Studio has NO default shortcut for Publish to
				-- Roblox, so the old "· Ctrl+Alt+P" hint was misinformation.
				Text = "File → Publish to Roblox…",
				TextColor3 = Theme.textDim,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		}),
		spacer = Spacer(98),
		recheck = PrimaryButton({
			layoutOrder = 99,
			text = "I've published — re-check",
			onClick = recheckSetup,
		}),
	})
end

-- Step 2 — enable HTTP. Stateless. Studio blocks plugins from flipping
-- HttpService.HttpEnabled (the old "Try to turn it on for me" button always
-- failed), so there's no auto-toggle — we show the exact menu path + a blue
-- re-check that re-renders (detectSetupStep re-reads HttpEnabled).
local function EnableHttpStepBody(props)
	return BodyShell({
		placeContext = PlaceContext({ layoutOrder = 0 }),
		progress = SetupProgress({ layoutOrder = 1, current = "http" }),
		hero = ScreenHero({
			layoutOrder = 2,
			glyph = "🌐",
			title = "Turn on HTTP Requests",
			why = "Roculus reaches your dashboard over HTTP — it's switched off for this place right now.",
		}),
		steps = h("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 44),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "1. File → Experience Settings → Security\n2. Turn on Allow HTTP Requests",
			TextColor3 = Theme.textDim,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
		spacer = Spacer(98),
		recheck = PrimaryButton({
			layoutOrder = 99,
			text = "I've done it — re-check",
			onClick = recheckSetup,
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- NotConnectedBody — the router. Kept as a Roact.Component because the
-- Connect step needs self.state.tokenInput (TextBox value, Enter-to-submit,
-- Connect-enable). Publish / HTTP branches are stateless and delegate to
-- the functions above. paste_error forces the Connect step.
-- ─────────────────────────────────────────────────────────────────────

local NotConnectedBody = Roact.Component:extend("NotConnectedBody")

function NotConnectedBody:init()
	self:setState({ tokenInput = "" })
end

-- Step 3 — Connect. A method (not a free function) so it can read/write
-- self.state.tokenInput and keep the existing PluginAuth.connect wiring:
-- Change.Text, Enter-to-submit (FocusLost), Paste button, dashboard CTA,
-- and the Connect button. `isPasteError` mirrors the mock's pasteError prop.
function NotConnectedBody:_renderConnectStep(isPasteError: boolean)
	-- For the live paste-error variant, prefill the field with the same
	-- visible string the mockup shows (a place-id-looking value) so the
	-- visual matches the design page.
	local fieldValue = isPasteError and "1234567890" or self.state.tokenInput

	local children = {}

	children.placeContext = PlaceContext({ layoutOrder = 0 })
	children.progress = SetupProgress({ layoutOrder = 1, current = "connect" })
	children.hero = ScreenHero({
		layoutOrder = 2,
		glyph = "🔑",
		title = "Get your token & connect",
		why = "Generate a token in your dashboard, then paste it here.",
	})

	-- Get the dashboard link. A Studio TextBox can't reliably select-all, so a
	-- "copyable" field is a lie (user: "u won't be able to select all of it").
	-- One honest action instead: onOpenDashboard copies the link to the
	-- clipboard (best effort) AND prints it to the Output window — the path
	-- that ALWAYS works in Studio. The toast it fires says which one landed.
	children.dashboard = h("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		layout("vertical", 8),
		h("TextButton", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.inputHeight),
			BackgroundColor3 = Theme.button,
			BorderSizePixel = 0,
			Font = Theme.font,
			Text = "Copy link & send to Output",
			TextColor3 = Theme.text,
			TextSize = 14,
			[Roact.Event.Activated] = self.props.onOpenDashboard,
		}, { corner(4), stroke(Theme.border) }),
		h("TextLabel", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "Copies the link to your clipboard and the Output window below — use whichever works.",
			TextColor3 = Theme.textMuted,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
	})

	children.fieldLabel = h("TextLabel", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 17),
		BackgroundTransparency = 1,
		Font = Theme.font,
		Text = "Paste it here",
		TextColor3 = Theme.textDim,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	children.inputRow = h("Frame", {
		LayoutOrder = 5,
		Size = UDim2.new(1, 0, 0, Theme.inputHeight),
		BackgroundTransparency = 1,
		-- Clip the row so a pasted token never paints outside its bounds
		-- (user: "after pasting the token it clips out of the text box").
		ClipsDescendants = true,
	}, {
		layout("horizontal", 8),
		h("TextBox", {
			Size = UDim2.new(1, -80, 1, 0),
			LayoutOrder = 1,
			BackgroundColor3 = Theme.inputBg,
			BorderSizePixel = 0,
			Font = Theme.fontMono,
			PlaceholderText = "rcr_••••••••••••",
			Text = fieldValue,
			TextColor3 = Theme.text,
			TextSize = 14,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			PlaceholderColor3 = Theme.textMuted,
			-- Single-line field: long tokens scroll WITHIN the box; ClipsDescendants
			-- keeps the glyphs inside the rounded rect instead of bleeding out.
			MultiLine = false,
			ClipsDescendants = true,
			[Roact.Change.Text] = function(rbx)
				self:setState({ tokenInput = rbx.Text })
			end,
			-- Enter-to-submit. Roblox fires FocusLost with enterPressed=true
			-- when the user hits Return; we trim and submit if it's not the
			-- paste-error variant and looks long enough to be a real token.
			[Roact.Event.FocusLost] = function(rbx, enterPressed)
				if isPasteError or not enterPressed then return end
				local val = rbx.Text
				if #val >= 10 then
					PluginAuth.connect(val)
				end
			end,
		}, { corner(4), stroke(isPasteError and Theme.error or Theme.inputBorder), pad(10, { top = 0, bottom = 0 }) }),
		h("TextButton", {
			Size = UDim2.new(0, 72, 1, 0),
			LayoutOrder = 2,
			BackgroundColor3 = Theme.button,
			BorderSizePixel = 0,
			Font = Theme.font,
			Text = "Paste",
			TextColor3 = Theme.text,
			TextSize = 13,
			[Roact.Event.Activated] = function()
				-- Studio plugins can't read clipboard programmatically — leave
				-- the user to Ctrl+V into the input. Click still gives focus.
				-- Nothing to do.
			end,
		}, { corner(4), stroke(Theme.border) }),
	})

	if isPasteError then
		children.errorHint = h("TextLabel", {
			LayoutOrder = 6,
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "That looks like a place ID, not a token. Roculus tokens start with rcr_ and are ~40 characters.",
			TextColor3 = Theme.error,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		})
	end

	children.spacer = Spacer(98)

	children.connectButton = PrimaryButton({
		layoutOrder = 99,
		text = "Connect",
		disabled = isPasteError or #self.state.tokenInput < 10,
		onClick = function()
			if not isPasteError and #self.state.tokenInput >= 10 then
				PluginAuth.connect(self.state.tokenInput)
			end
		end,
	})

	return BodyShell(children)
end

function NotConnectedBody:render()
	local isPasteError = self.props.variant == "paste_error"
	-- Paste error always lands on Connect (that's the only screen with a
	-- token field); otherwise derive the current blocker live.
	local step = isPasteError and "connect" or detectSetupStep()

	if step == "publish" then
		return PublishStepBody({})
	elseif step == "http" then
		return EnableHttpStepBody({})
	end
	return self:_renderConnectStep(isPasteError)
end

-- ─────────────────────────────────────────────────────────────────────
-- ConnectingBody — spinner placeholder + Cancel
-- ─────────────────────────────────────────────────────────────────────

local function ConnectingBody()
	return BodyShell({
		title = H2({ layoutOrder = 1, text = "Connecting…" }),
		helper = HelperText({ layoutOrder = 2, text = "Verifying your token against Roculus." }),
		-- Top-aligned inline line (was a full-height centered frame, which —
		-- like the old Spacer — pushed Cancel off the bottom edge).
		spinnerLabel = h("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 19),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "This usually takes a second.",
			TextColor3 = Theme.textDim,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		spacer = Spacer(98),
		cancel = SecondaryButton({
			layoutOrder = 99,
			text = "Cancel",
			onClick = function()
				-- Soft-cancel; backend has no in-flight cancel, so we just
				-- flip UI back to NotConnected.
				State.set({ status = State.STATES.NOT_CONNECTED })
			end,
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- ConfirmingBody — single muted line + progress strip
-- ─────────────────────────────────────────────────────────────────────

local function ConfirmingBody()
	return BodyShell({
		title = H2({ layoutOrder = 1, text = "Almost there…" }),
		helper = HelperText({ layoutOrder = 2, text = "Verifying token, place, and plugin version." }),
		spacer = Spacer(98),
		strip = h("Frame", {
			LayoutOrder = 98,
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = Theme.brandCyan,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
		}, { corner(2) }),
		cancel = SecondaryButton({ layoutOrder = 99, text = "Cancel", onClick = function()
			State.set({ status = State.STATES.NOT_CONNECTED })
		end }),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- ConnectedBody — steady + backlog + update + mismatch variants
-- ─────────────────────────────────────────────────────────────────────

local function ConnectedMismatchBody(props)
	return BodyShell({
		banner = ErrorBanner({
			layoutOrder = 1,
			tone = "warn",
			height = 84,
			title = "Different place open",
			body = "This token is paired with another place. Re-pair to bind it to the place you have open now.",
		}),
		spacer = Spacer(98),
		row = h("Frame", {
			LayoutOrder = 99,
			Size = UDim2.new(1, 0, 0, Theme.primaryButtonHeight),
			BackgroundTransparency = 1,
		}, {
			layout("horizontal", 8),
			SecondaryButton({ layoutOrder = 1, size = UDim2.new(0.5, -4, 1, 0), text = "Cancel", onClick = function() end }),
			PrimaryButton({ layoutOrder = 2, size = UDim2.new(0.5, -4, 1, 0), text = "Re-pair to this place", onClick = function() end }),
		}),
	})
end

local function ConnectedBody(props)
	if props.variant == "mismatch" then
		return ConnectedMismatchBody(props)
	end

	local isBacklog = props.variant == "backlog"
	local isUpdate = props.variant == "update"
	local pendingEvents = isBacklog and 47 or (props.pendingEvents or 0)
	local errorsLast24h = isBacklog and 2 or (props.errorsLast24h or 0)
	local updateAvailable = isUpdate or props.updateAvailable == true

	-- Line 1 — live sync status: last-sync + pending events (when any) + errors
	-- (when any). Only fields that exist on the snapshot; pending/errors stay
	-- hidden at zero so the steady line reads calm.
	local syncBits = { "Last sync " .. tostring(props.lastSyncSeconds or 2) .. "s ago" }
	if pendingEvents > 0 then
		table.insert(syncBits, tostring(pendingEvents) .. " pending")
	end
	if errorsLast24h > 0 then
		table.insert(syncBits, "⚠ " .. tostring(errorsLast24h) .. " error" .. (errorsLast24h == 1 and "" or "s") .. " in 24h")
	end
	local syncFooter = table.concat(syncBits, " · ")

	-- Line 2 — runtime version readout. Names the runtime build the plugin
	-- embeds (Config.runtimeVersion), with a small "· update available" hint
	-- when a newer release exists. Gives the user the "what version am I on?"
	-- answer the dashboard banner refers to.
	local versionFooter = "Runtime v" .. Config.runtimeVersion
	if updateAvailable then
		versionFooter = versionFooter .. "  ·  update available"
	end

	return BodyShell({
		headerRow = h("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
		}, {
			layout("horizontal", 10, { verticalAlign = Enum.VerticalAlignment.Center }),
			StatusDot(Theme.ok),
			h("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, -20, 1, 0),
				BackgroundTransparency = 1,
				Font = Theme.fontBold,
				Text = "Connected",
				TextColor3 = Theme.text,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		}),
		placeName = h("TextLabel", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 17),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = props.placeName or "Place",
			TextColor3 = Theme.textDim,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		-- Update banner — the in-body half of the "don't overlook it" fix. The
		-- titlebar red "● Update" pill catches the eye; this warn banner gives
		-- the why + the path (Open dashboard, in the footer row below). warn
		-- (amber), not error (red): an available update is a heads-up, not a
		-- failure. Mirrors the mock's connected_update banner.
		updateBanner = isUpdate and ErrorBanner({
			layoutOrder = 3,
			tone = "warn",
			height = 80,
			title = "Update available — v" .. Config.runtimeVersion,
			body = "Your game is running an older Bridge runtime. Open the dashboard to update — it keeps events flowing without gaps.",
		}) or nil,
		spacer = Spacer(50),
		-- Two muted ambient lines: sync status, then the runtime-version readout
		-- (+ update hint). Surfaces "is it syncing / what version" at a glance.
		syncLine = MutedFooter({ layoutOrder = 95, text = syncFooter }),
		versionLine = MutedFooter({ layoutOrder = 96, text = versionFooter }),
		-- Persistent republish reminder — addresses the recurring "is my game
		-- actually updated?" confusion. In-game runtime only refreshes after a
		-- republish in Studio, so we say so plainly. Muted; one line.
		republishReminder = h("TextLabel", {
			LayoutOrder = 97,
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "Republish your game in Studio to apply the latest runtime updates.",
			TextColor3 = Theme.textMuted,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
		row = h("Frame", {
			LayoutOrder = 99,
			Size = UDim2.new(1, 0, 0, Theme.primaryButtonHeight),
			BackgroundTransparency = 1,
		}, {
			layout("horizontal", 8),
			SecondaryButton({
				layoutOrder = 1,
				size = UDim2.new(0.5, -4, 1, 0),
				text = "Disconnect",
				onClick = function()
					PluginAuth.disconnect()
				end,
			}),
			h("TextButton", {
				LayoutOrder = 2,
				Size = UDim2.new(0.5, -4, 1, 0),
				BackgroundTransparency = 1,
				Font = Theme.font,
				Text = "Open dashboard",
				TextColor3 = Theme.link,
				TextSize = 14,
				[Roact.Event.Activated] = props.onOpenDashboard,
			}, { corner(4), stroke(Theme.border) }),
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- ErrorBody — auth + http_disabled variants
-- ─────────────────────────────────────────────────────────────────────

local function ErrorBody(props)
	if props.variant == "http_disabled" then
		return BodyShell({
			banner = h("Frame", {
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 96),
				BackgroundColor3 = Theme.errorBannerBg,
				BackgroundTransparency = 0.88,
				BorderSizePixel = 0,
			}, {
				corner(5),
				stroke(Theme.error),
				pad(12),
				layout("vertical", 5),
				h("TextLabel", {
					LayoutOrder = 1,
					Size = UDim2.new(1, 0, 0, 19),
					BackgroundTransparency = 1,
					Font = Theme.fontBold,
					Text = "Studio is blocking HTTP requests",
					TextColor3 = Theme.text,
					TextSize = 15,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				h("TextLabel", {
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 1, -26),
					BackgroundTransparency = 1,
					Font = Theme.font,
					Text = "1. Open Experience Settings → Security\n2. Tick Allow HTTP Requests, then come back here",
					TextColor3 = Theme.textDim,
					TextSize = 14,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextWrapped = true,
				}),
			}),
			spacer = Spacer(98),
			retry = PrimaryButton({
				layoutOrder = 99,
				text = "I've fixed it — Retry",
				onClick = function()
					local refresh = PluginAuth.getStoredRefreshToken()
					if refresh then
						PluginAuth.connect(refresh)
					else
						State.set({ status = State.STATES.NOT_CONNECTED })
					end
				end,
			}),
		})
	end

	-- auth variant (default)
	return BodyShell({
		banner = ErrorBanner({
			layoutOrder = 1,
			tone = "error",
			height = 72,
			title = "Connection failed",
			body = "The token was rejected by Roculus. Regenerate it on the dashboard and try again.",
		}),
		spacer = Spacer(96),
		dashboardLink = LinkLabel({
			layoutOrder = 97,
			text = "Open dashboard →",
			onClick = props.onOpenDashboard,
		}),
		retry = PrimaryButton({
			layoutOrder = 99,
			text = "Try again",
			onClick = function()
				State.set({ status = State.STATES.NOT_CONNECTED })
			end,
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- AutoPromptBody — "Reconnect to Roculus?" banner
-- ─────────────────────────────────────────────────────────────────────

local function AutoPromptBody(props)
	return BodyShell({
		banner = h("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 84),
			BackgroundColor3 = Theme.brandBannerBg,
			BackgroundTransparency = 0.92,
			BorderSizePixel = 0,
		}, {
			corner(5),
			stroke(Theme.brandCyan),
			pad(14),
			layout("vertical", 5),
			h("TextLabel", { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 19), BackgroundTransparency = 1, Font = Theme.fontBold, Text = "Reconnect to Roculus?", TextColor3 = Theme.text, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left }),
			h("TextLabel", { LayoutOrder = 2, Size = UDim2.new(1, 0, 1, -26), BackgroundTransparency = 1, Font = Theme.font, Text = "You paired this place last time you opened it.", TextColor3 = Theme.textDim, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true }),
		}),
		spacer = Spacer(50),
		forget = h("TextButton", {
			LayoutOrder = 97,
			Size = UDim2.new(0, 190, 0, 22),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = "Don't ask for this place",
			TextColor3 = Theme.textMuted,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			[Roact.Event.Activated] = function()
				State.set({ status = State.STATES.NOT_CONNECTED })
			end,
		}),
		row = h("Frame", { LayoutOrder = 99, Size = UDim2.new(1, 0, 0, Theme.primaryButtonHeight), BackgroundTransparency = 1 }, {
			layout("horizontal", 8),
			SecondaryButton({ layoutOrder = 1, size = UDim2.new(0.5, -4, 1, 0), text = "Not this time", onClick = function()
				State.set({ status = State.STATES.NOT_CONNECTED })
			end }),
			PrimaryButton({ layoutOrder = 2, size = UDim2.new(0.5, -4, 1, 0), text = "Reconnect", onClick = function()
				local refresh = PluginAuth.getStoredRefreshToken()
				if refresh then PluginAuth.connect(refresh) end
			end }),
		}),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- SettingsBody — General / Diagnostics / About + Debug switcher
-- ─────────────────────────────────────────────────────────────────────

local function settingsRow(label: string, valueText: string, layoutOrder: number)
	return h("Frame", { LayoutOrder = layoutOrder, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, {
		h("TextLabel", { Size = UDim2.new(0.5, 0, 1, 0), BackgroundTransparency = 1, Font = Theme.font, Text = label, TextColor3 = Theme.textDim, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left }),
		h("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.5, 0, 1, 0), BackgroundTransparency = 1, Font = Theme.font, Text = valueText, TextColor3 = Theme.text, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right }),
	})
end

local SettingsBody = Roact.Component:extend("SettingsBody")

function SettingsBody:render()
	local current = self.props.snapshot
	local children = {}

	children.title = H2({ layoutOrder = 1, text = "Settings" })

	children.general = h("Frame", { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 92), BackgroundTransparency = 1 }, {
		layout("vertical", 6),
		H2({ layoutOrder = 1, text = "General" }),
		settingsRow("Log level", "Info", 2),
		-- 2026-06-02 — read the plugin's own version straight from Config (the
		-- same source the load-print uses), NOT the runtime snapshot. The
		-- snapshot's bridgeVersion is nil until a server sync, so this row used
		-- to fall back to a hardcoded "0.1.0" and never matched the real build.
		settingsRow("Plugin version", Config.pluginVersion, 3),
	})

	children.diagnostics = h("Frame", { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 92), BackgroundTransparency = 1 }, {
		layout("vertical", 6),
		H2({ layoutOrder = 1, text = "Diagnostics" }),
		settingsRow("Last sync", tostring(current.lastSyncSeconds or "—") .. "s ago", 2),
		settingsRow("Pending events", tostring(current.pendingEvents or 0), 3),
	})

	children.about = h("Frame", { LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 68), BackgroundTransparency = 1 }, {
		layout("vertical", 6),
		H2({ layoutOrder = 1, text = "About" }),
		settingsRow("Latest version", current.latestPluginVersion or current.bridgeVersion or "—", 2),
	})

	return BodyShell(children)
end

-- ─────────────────────────────────────────────────────────────────────
-- Titlebar
-- ─────────────────────────────────────────────────────────────────────

-- Roculus brand mark — Roblox decal asset 79550164974661 (user-provided
-- 2026-06-01). Mirrors the mock's RoculusGlyph (the ~1.8:1 R-with-eye logo).
-- ScaleType.Fit preserves aspect inside the box so the mark never squashes
-- regardless of the source decal's exact dimensions. If the image ever fails
-- to load in Studio (bad id / not approved yet), the box is transparent — no
-- broken-image chrome.
local ROCULUS_LOGO_ASSET = "rbxassetid://79550164974661"

-- 2026-06-03 — titlebar restructured so the settings gear HUGS the far right
-- edge (user: "settings icon not all the way to the right"). The old layout
-- was one horizontal UIListLayout (logo, wordmark, pill, gear); the gear sat
-- with slack to its right. Now: logo + wordmark live in a left list; the
-- update pill + gear form an absolute-positioned RIGHT CLUSTER anchored to the
-- right edge (gear at x=-12, pill just left of it). The wordmark's width stops
-- short of the cluster so they never overlap.
local function Titlebar(props)
	local hasPill = props.updateAvailable == true
	-- Reserve right-edge room for the gear (icon + 12px inset) plus, when shown,
	-- the pill (~64px) + an 8px gap. The wordmark fills the rest of the row.
	local rightReserve = Theme.iconButtonSize + 12 + (hasPill and (64 + 8) or 0)

	local rightCluster = {
		-- Settings / back gear — pinned to the FAR RIGHT.
		gear = h("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(Theme.iconButtonSize, Theme.iconButtonSize),
			BackgroundTransparency = 1,
			Font = Theme.font,
			Text = props.inSettings and "←" or "⚙",
			TextColor3 = Theme.textDim,
			TextSize = 15,
			[Roact.Event.Activated] = props.onToggleSettings,
		}),
	}
	-- 2026-06-01 — the update indicator was a tiny cyan dot (easy to miss, and
	-- cyan reads as "fine"). Make it a RED "Update" pill so an outdated plugin
	-- is unmissable (user: "should be red and flare or something"). The toast
	-- still fires once on detect; this is the persistent always-visible flag.
	-- Sits just LEFT of the gear (gear width + 12px inset + 8px gap from the edge).
	if hasPill then
		rightCluster.pill = h("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(Theme.iconButtonSize + 12 + 8), 0.5, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			BackgroundColor3 = Theme.error,
			BackgroundTransparency = 0.78,
			Font = Theme.fontBold,
			Text = "● Update",
			TextColor3 = Theme.error,
			TextSize = 12.5,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
		}, {
			corner(6),
			stroke(Theme.error),
			h("UIPadding", {
				PaddingLeft = UDim.new(0, 9),
				PaddingRight = UDim.new(0, 9),
			}),
		})
	end

	return h("Frame", {
		Size = UDim2.new(1, 0, 0, Theme.titlebarHeight),
		BackgroundColor3 = Theme.titlebar,
		BorderSizePixel = 0,
	}, {
		stroke(Theme.border),
		-- Left group: logo + wordmark in a horizontal list, inset 12px from the
		-- left. Width stops short of the right cluster so the wordmark can't run
		-- under the gear/pill.
		leftGroup = h("Frame", {
			Size = UDim2.new(1, -(12 + rightReserve), 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
		}, {
			layout("horizontal", 10, { verticalAlign = Enum.VerticalAlignment.Center }),
			-- Brand logo — real Roculus mark. 2026-06-03: 56×32 (~1.75:1) in the
			-- now-48px titlebar (user: logo too small). ScaleType.Fit keeps aspect.
			logo = h("ImageLabel", {
				LayoutOrder = 1,
				Size = UDim2.fromOffset(56, 32),
				BackgroundTransparency = 1,
				Image = ROCULUS_LOGO_ASSET,
				ScaleType = Enum.ScaleType.Fit,
			}),
			wordmark = h("TextLabel", {
				LayoutOrder = 2,
				Size = UDim2.new(1, -66, 1, 0),
				BackgroundTransparency = 1,
				Font = Theme.fontBold,
				Text = "Roculus Bridge",
				TextColor3 = Theme.text,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
		}),
		-- Right cluster: absolute-positioned so the gear hugs the right edge
		-- regardless of pill presence.
		rightCluster = h("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		}, rightCluster),
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- PluginPane — top-level component
-- ─────────────────────────────────────────────────────────────────────

local PluginPane = Roact.Component:extend("PluginPane")

function PluginPane:init()
	self:setState(State.get())
end

function PluginPane:didMount()
	self.unsubscribe = State.subscribe(function(snapshot)
		self:setState(snapshot)
	end)
end

function PluginPane:willUnmount()
	if self.unsubscribe then self.unsubscribe() end
end

function PluginPane:_renderBody(status)
	if status == "not_connected" then
		return Roact.createElement(NotConnectedBody, { variant = "default", onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "not_connected_paste_error" then
		return Roact.createElement(NotConnectedBody, { variant = "paste_error", onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "auto_prompt" then
		return AutoPromptBody({ onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "connecting" then
		return ConnectingBody()
	elseif status == "confirming" then
		return ConfirmingBody()
	elseif status == "connected" then
		return ConnectedBody({ variant = "steady", placeName = self.state.placeName, lastSyncSeconds = self.state.lastSyncSeconds, pendingEvents = self.state.pendingEvents, errorsLast24h = self.state.errorsLast24h, updateAvailable = self.state.updateAvailable, onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "connected_backlog" then
		return ConnectedBody({ variant = "backlog", placeName = self.state.placeName, onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "connected_update" then
		return ConnectedBody({ variant = "update", placeName = self.state.placeName, lastSyncSeconds = self.state.lastSyncSeconds, pendingEvents = self.state.pendingEvents, errorsLast24h = self.state.errorsLast24h, onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "connected_mismatch" then
		return ConnectedBody({ variant = "mismatch" })
	elseif status == "error" then
		return ErrorBody({ variant = self.state.errorVariant or "auth", onOpenDashboard = self.props.onOpenDashboard })
	elseif status == "error_http" then
		return ErrorBody({ variant = "http_disabled" })
	elseif status == "settings" then
		return Roact.createElement(SettingsBody, { snapshot = self.state })
	end
	return NotConnectedBody({ variant = "default", onOpenDashboard = self.props.onOpenDashboard })
end

function PluginPane:render()
	local status = self.state.status or "not_connected"
	local inSettings = status == "settings"
	local updateAvailable = self.state.updateAvailable or status == "connected_update"

	local children = {
		layout("vertical", 0),
		titlebar = Titlebar({
			updateAvailable = updateAvailable,
			inSettings = inSettings,
			onToggleSettings = function()
				if inSettings then
					-- Restore prior status — for v1 just go to NotConnected
					-- if we don't have a saved prior. Tracking previous state
					-- formally is a v2 polish.
					State.set({ status = self.state.priorStatus or "not_connected" })
				else
					State.set({ priorStatus = status, status = "settings" })
				end
			end,
		}),
	}

	children.bodyFrame = h("Frame", {
		LayoutOrder = 99,
		Size = UDim2.new(1, 0, 1, -Theme.titlebarHeight),
		BackgroundColor3 = Theme.mainBg,
		BorderSizePixel = 0,
	}, { self:_renderBody(status) })

	-- Wrap titlebar + body in a stack frame so the toast can overlay
	-- the whole pane from the BOTTOM. The old code made the toast a sibling of
	-- the root's vertical layout, so its bottom-anchor was ignored and it
	-- landed at the TOP looking broken (user: "that blue box at the top").
	-- Isolating the layout inside `stack` frees the toast to float again.
	local stack = h("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, children)

	local rootChildren = { stack = stack }
	if self.state.toast then
		-- Redesigned toast: solid surface + a 3px cyan LEFT RAIL (the outer frame
		-- is the rail colour; the inner surface is inset 3px) + readable text. No
		-- full cyan outline box. Bottom-anchored overlay, never shoves content.
		-- 2026-06-03 — both frames AutomaticSize.Y + the label TextWrapped, so a
		-- long message ("Dashboard URL printed in Output ↓ …") grows the toast
		-- to fit instead of clipping (it was a fixed 36px single-line box).
		-- Anchor is the BOTTOM edge, so the box grows UPWARD off the bottom.
		rootChildren.toast = h("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -12),
			Size = UDim2.new(1, -24, 0, 36),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.brand,
			BorderSizePixel = 0,
			ZIndex = 50,
		}, {
			corner(6),
			h("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, 0, 0.5, 0),
				Size = UDim2.new(1, -3, 0, 36),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Theme.button,
				BorderSizePixel = 0,
				ZIndex = 50,
			}, {
				corner(6),
				stroke(Theme.border),
				pad(8, { left = 12, right = 12 }),
				h("TextLabel", {
					-- Width fixed (fills the padded inner frame), height auto so the
					-- wrapped text drives the toast's growth.
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					Font = Theme.font,
					Text = self.state.toast.message,
					TextColor3 = Theme.text,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Center,
					TextWrapped = true,
					ZIndex = 51,
				}),
			}),
		})
	end

	return h("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.mainBg,
		BorderSizePixel = 0,
	}, rootChildren)
end

return PluginPane
