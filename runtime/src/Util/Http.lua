--!strict
--[=[
	HTTP wrapper around HttpService:RequestAsync.

	Every Bridge → backend call goes through here. Reasons:

	  1. Token injection — every request carries X-Roculus-Token. Defined once.
	  2. Bridge metadata headers — X-Bridge-Version, X-Bridge-Server-Id.
	     Backend uses these for diagnostics + per-version metrics.
	  3. JSON encode/decode — callers pass tables, get tables back.
	  4. Retry policy — transient failures (5xx, network) get one retry
	     with backoff. 4xx errors don't retry (we sent something bad).
	  5. Error context — failures return structured `{ok=false, status, code, message}`
	     instead of throwing, so loop drivers can decide whether to back off.

	Long-poll requests skip retries entirely — they have their own
	30-60s timeout semantics and shouldn't get amplified by retries on top.
]=]

local HttpService = game:GetService("HttpService")
local Logger = require(script.Parent.Logger)

local Http = {}

local DEFAULT_RETRY_DELAY_S = 2

export type HttpResponse = {
	ok: boolean,
	status: number,
	body: { [string]: any }?, -- decoded JSON body if Content-Type allows
	raw: string?,             -- raw response body (always present on failure)
	code: string?,            -- backend error code (when ok=false and body parsed)
	message: string?,         -- backend error message
}

local function buildHeaders(state, extra: { [string]: string }?): { [string]: string }
	-- Post mig 0048: X-Roculus-Token carries the short-lived ACCESS token
	-- (`rca_…`), minted by /auth/exchange. The token is *conditional*:
	-- the /auth/exchange call itself runs through this helper but has no
	-- access token yet (it's bearing the refresh in the body). Omit the
	-- header in that pre-exchange state and let the backend reject any
	-- non-auth endpoint that happens to be called too early.
	local headers: { [string]: string } = {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
		["X-Bridge-Version"] = state.bridgeVersion,
		["X-Bridge-Server-Id"] = game.JobId ~= "" and game.JobId or "studio-session",
	}
	if state.accessToken then
		headers["X-Roculus-Token"] = state.accessToken
	end
	if extra then
		for k, v in pairs(extra) do
			headers[k] = v
		end
	end
	return headers
end

--[=[
	Internal — issue one HTTP request. No retry logic; callers handle that.

	@param state — the module state table from init.lua
	@param method — "GET" | "POST" | etc.
	@param path — backend path, e.g. "/api/bridge/heartbeat" (joined to state.apiBase)
	@param body — optional table; JSON-encoded into the request body
	@param opts — { timeoutS: number?, extraHeaders: {[string]: string}? }

	@return HttpResponse
]=]
local function requestOnce(
	state,
	method: string,
	path: string,
	body: { [string]: any }?,
	opts: { timeoutS: number?, extraHeaders: { [string]: string }? }?
): HttpResponse
	local url = state.apiBase .. path
	local request = {
		Url = url,
		Method = method,
		Headers = buildHeaders(state, opts and opts.extraHeaders),
	}
	if body ~= nil then
		request.Body = HttpService:JSONEncode(body)
	end

	local ok, result = pcall(HttpService.RequestAsync, HttpService, request)
	if not ok then
		-- Network failure / DNS error / HttpService disabled mid-flight.
		Logger.error(string.format("HTTP %s %s — network: %s", method, path, tostring(result)))
		return {
			ok = false,
			status = 0,
			raw = tostring(result),
			code = "network_error",
			message = tostring(result),
		}
	end

	local response = result :: any
	local rawBody = response.Body
	local decoded: { [string]: any }? = nil
	if rawBody and #rawBody > 0 then
		local jsonOk, jsonResult = pcall(HttpService.JSONDecode, HttpService, rawBody)
		if jsonOk then
			decoded = jsonResult
		end
	end

	local httpOk = response.Success and response.StatusCode < 400
	if not httpOk then
		Logger.debug(string.format("HTTP %s %s -> %d", method, path, response.StatusCode))
	end

	return {
		ok = httpOk,
		status = response.StatusCode,
		body = decoded,
		raw = rawBody,
		code = decoded and decoded.error and decoded.error.code,
		message = decoded and decoded.error and decoded.error.message,
	}
end

--[=[
	Issue a request with one retry on transient failures (network, 5xx).
	4xx errors return immediately — we sent bad data, retry won't help.
]=]
function Http.request(state, method: string, path: string, body: { [string]: any }?, opts: any?): HttpResponse
	local response = requestOnce(state, method, path, body, opts)
	if response.ok then
		return response
	end

	-- Decide whether to retry. Retry on: network errors (status=0), 5xx.
	-- Don't retry on: 4xx (we'd just get the same answer).
	local shouldRetry = response.status == 0 or response.status >= 500
	if not shouldRetry then
		return response
	end

	task.wait(DEFAULT_RETRY_DELAY_S)
	Logger.debug(string.format("Retrying %s %s after transient failure", method, path))
	return requestOnce(state, method, path, body, opts)
end

--[=[
	Long-poll request — no retry. The caller's loop decides what to do on
	failure (usually: wait + try again on next iteration).
]=]
function Http.longPoll(state, method: string, path: string, body: { [string]: any }?, opts: any?): HttpResponse
	return requestOnce(state, method, path, body, opts)
end

return Http
