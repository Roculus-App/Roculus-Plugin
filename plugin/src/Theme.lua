--!strict
--[=[
	Theme tokens — mirrors the JSX mockup at /dev/bridge-plugin-design.

	Values are hardcoded to Studio's dark theme. The mockup file's `STUDIO`
	table is the source of truth — when those tokens shift, these shift.

	TODO (future): read from `settings():GetService("Studio").Theme:GetColor`
	so the plugin follows the user's Studio theme. Hardcoded for v1 to land
	the visual port exactly; theme reactivity is a separate change.
]=]

local Theme = {}

-- Surfaces
Theme.mainBg       = Color3.fromHex("2b2b2b")
Theme.titlebar     = Color3.fromHex("222222")
Theme.border       = Color3.fromHex("3c3c3c")
Theme.separator    = Color3.fromHex("3c3c3c")

-- Controls
Theme.inputBg      = Color3.fromHex("3a3a3a")
Theme.inputBorder  = Color3.fromHex("525252")
Theme.button       = Color3.fromHex("3c3c3c")
Theme.buttonHover  = Color3.fromHex("484848")
-- Studio's "primary" blue — used only for the dominant CTA per state.
Theme.mainButton   = Color3.fromHex("338bf3")

-- Text
Theme.text         = Color3.fromHex("dddddd")
Theme.textDim      = Color3.fromHex("aaaaaa")
Theme.textMuted    = Color3.fromHex("a0a0a0") -- was 7f7f7f (~3.5:1, sub-WCAG); a0a0a0 ≈ 5:1

-- Semantic
Theme.ok           = Color3.fromHex("1abc6e")
Theme.warn         = Color3.fromHex("e0a82e")
Theme.error        = Color3.fromHex("e74c3c")
Theme.link         = Color3.fromHex("5fa3ff")

-- Brand cyan — the Roculus accent. Used sparingly: update dot in titlebar,
-- auto-prompt banner left-edge, debug switcher highlight.
Theme.brandCyan    = Color3.fromHex("0ee1fb")

-- Primary-CTA accent (matches the mock's STUDIO.brand) + the near-black ink
-- that sits ON it. Cyan fill + dark text reads on-brand and passes contrast,
-- replacing the generic Studio-blue mainButton + white text (3.4:1, failed AA).
Theme.brand        = Color3.fromHex("0ea5e9")
Theme.brandInk     = Color3.fromHex("06283a")

-- Banner backgrounds (low-alpha fills matching the mockup)
Theme.errorBannerBg     = Color3.fromRGB(231, 76, 60)    -- @ 12% alpha applied in BackgroundTransparency
Theme.warnBannerBg      = Color3.fromRGB(224, 168, 46)   -- @ 10% alpha
Theme.brandBannerBg     = Color3.fromRGB(14, 225, 251)   -- @ 6% alpha

-- Font — Studio plugins should use SourceSans which matches StudioStyleGuide.
Theme.font = Enum.Font.SourceSans
Theme.fontBold = Enum.Font.SourceSansBold
Theme.fontMono = Enum.Font.RobotoMono

-- Spacing — 4px grid like the mockup
-- (2026-06-01: scaled up ~20% per user — the pane read cramped in the dock.
-- Whole grid bumped one step so padding/gaps between every element breathe.
-- Old → new: xs 4→6, sm 6→8, md 8→10, lg 10→12, xl 12→16, xxl 14→18.)
Theme.pad = {
	xs = 6,
	sm = 8,
	md = 10,
	lg = 12,
	xl = 16,
	xxl = 18,
}

-- Sizes (2026-05-30: nudged up a touch — controls were reading small in
-- the dock. Titlebar 28→30, buttons 28→32, input 26→30.)
-- (2026-05-31: titlebar 30→44 to host the larger brand glyph — the mock's
-- PanelTitlebar is 44px so the 47×26 logo actually reads. Body-frame height
-- subtracts Theme.titlebarHeight so it auto-adjusts.)
-- (2026-06-01: "make components bigger on all pages" — scaled controls ~20%.
-- Titlebar 44→52 (logo grows to 60×34), icon-button 24→30, primary button
-- 32→40, input 30→38. Body-frame height subtracts titlebarHeight so it
-- still auto-fits. MUST verify in Studio — can't run Roblox here.)
-- 2026-06-02: scaled back DOWN (user: "components should be smaller again").
-- The 2026-06-01 +20% bump read too chunky in the dock. Titlebar 52→44,
-- icon-button 30→26, primary button 40→32, input 38→32 — matches the revamped
-- mock (32px controls, 44px titlebar).
-- 2026-06-03: titlebar 44→48 to give the brand logo more height (user: "logo
-- too small"). Logo grows 40×23 → 56×32 in PluginPane; the 48px bar hosts it.
Theme.titlebarHeight = 48
Theme.iconButtonSize = 26
Theme.primaryButtonHeight = 32
Theme.inputHeight = 32

return Theme
