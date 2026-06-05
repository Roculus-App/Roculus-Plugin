--!strict
--[=[
	Plugin-side state singleton.

	One source of truth that components subscribe to. State changes flow
	from user actions (button clicks, exchange responses, etc.) into here,
	and the PluginPane re-renders the right body component on each change.

	State shape:
	  status            : string  -- one of STATES below
	  placeName         : string? -- shown in Connected ("Troll Tower Ultimate")
	  placeId           : number? -- numeric place id of the paired place
	  lastSyncSeconds   : number? -- footer line in Connected
	  pendingEvents     : number  -- footer flares when > 0
	  errorsLast24h     : number  -- footer flares when > 0
	  updateAvailable   : boolean -- titlebar cyan dot
	  latestPluginVersion: string? -- "About -> Latest version" row; from /bridge/latest poll
	  errorVariant      : string? -- "auth" | "http_disabled" | nil
	  notConnectedVariant: string? -- "default" | "paste_error" | nil

	Component subscription pattern (Roact + manual subscribe):
	  In componentDidMount, call State.subscribe(setStateFn)
	  In componentWillUnmount, call the returned unsubscribe()
]=]

local State = {}

-- Sentinel marker for "remove this key" in State.set patches. Needed
-- because Lua's `pairs({foo = nil})` doesn't iterate nil values, so
-- the obvious `State.set({ toast = nil })` would be a silent no-op.
-- Call sites: `State.set({ toast = State.REMOVE })`.
State.REMOVE = newproxy(false)

State.STATES = {
	NOT_CONNECTED         = "not_connected",
	NOT_CONNECTED_PASTE_ERROR = "not_connected_paste_error",
	AUTO_PROMPT           = "auto_prompt",
	CONNECTING            = "connecting",
	CONFIRMING            = "confirming",
	CONNECTED             = "connected",
	CONNECTED_BACKLOG     = "connected_backlog",
	CONNECTED_UPDATE      = "connected_update",
	CONNECTED_MISMATCH    = "connected_mismatch",
	ERROR_AUTH            = "error",
	ERROR_HTTP            = "error_http",
	SETTINGS              = "settings",
}

local current: { [string]: any } = {
	status              = State.STATES.NOT_CONNECTED,
	placeName           = nil,
	placeId             = nil,
	lastSyncSeconds     = nil,
	pendingEvents       = 0,
	errorsLast24h       = 0,
	updateAvailable     = false,
	latestPluginVersion = nil,  -- "About → Latest version" row; set by PluginAuth.checkLatestVersion / connect
	errorVariant        = nil,
	notConnectedVariant = nil,
	-- Transient toast: small banner at the bottom of the pane that
	-- surfaces actions whose effect happens off-screen ("URL printed
	-- to Output", "Place ID copied to clipboard", etc.). Cleared
	-- automatically after fireToast's ttl elapses.
	toast               = nil,  -- { id: number, message: string }
	toastIdCounter      = 0,
}

local subscribers: { (table) -> () } = {}

function State.get(): { [string]: any }
	-- Shallow clone so callers can't mutate the internal table directly.
	local copy = {}
	for k, v in pairs(current) do
		copy[k] = v
	end
	return copy
end

function State.set(patch: { [string]: any }): ()
	for k, v in pairs(patch) do
		if v == State.REMOVE then
			current[k] = nil
		else
			current[k] = v
		end
	end
	local snapshot = State.get()
	for _, fn in ipairs(subscribers) do
		-- Wrapped in pcall so a broken subscriber doesn't take the rest down.
		pcall(fn, snapshot)
	end
end

-- Fire a transient toast at the bottom of the pane. Auto-clears after
-- `ttlSeconds` (default 3). Newer toasts pre-empt older ones; the auto-
-- clear timer only acts on the toast it was scheduled for (id guard),
-- so a quick second toast doesn't get wiped by the first's expiry.
function State.fireToast(message: string, ttlSeconds: number?): ()
	local nextId = (current.toastIdCounter or 0) + 1
	State.set({
		toast = { id = nextId, message = message },
		toastIdCounter = nextId,
	})
	task.delay(ttlSeconds or 3, function()
		if current.toast and current.toast.id == nextId then
			State.set({ toast = State.REMOVE })
		end
	end)
end

function State.subscribe(fn: (table) -> ()): () -> ()
	table.insert(subscribers, fn)
	-- Push initial state immediately so the subscriber renders with
	-- the current values, not with whatever defaults their UI was built
	-- with.
	pcall(fn, State.get())
	return function()
		for i, candidate in ipairs(subscribers) do
			if candidate == fn then
				table.remove(subscribers, i)
				return
			end
		end
	end
end

return State
