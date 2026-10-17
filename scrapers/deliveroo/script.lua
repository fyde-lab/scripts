-- Scraper for Deliveroo (deliveroo.fr), the food-delivery platform: downloads the receipts of
-- delivered orders.
--
-- The original `form#login` no longer exists:
-- deliveroo.fr is now a Next.js app (behind PerimeterX, which `wreq`'s Chrome emulation gets
-- through). The flow below was rebuilt from that app's own JS bundle (pages/login + _app):
-- - `GET /fr/api/auth/read` gives a `csrf_token`;
-- - `POST /fr/api/auth/login` (JSON `email`/`password`/`page_in_progress`, `X-CSRF-Token`,
--   `X_ROO_CHALLENGE_SUPPORT: passcode`) answers 401 for bad credentials, 423 `mfa_required`
--   (`mfa_token`) when an SMS code is needed, sent/checked through `/fr/api/auth/
--   initiate_challenge` and `complete_challenge` with the `sms:passcode` challenge;
-- - `GET /fr/api/account/read` is 401 without a session, 200 with one;
-- - `/fr/orders` is server-rendered with the latest orders (one page, 25 at most) in its
--   `__NEXT_DATA__` state, each receipt at `/order/receipt/<order id>`.
-- Bad credentials -> 401 is confirmed against the live site; the successful login, SMS step,
-- order list and receipt format are not verified against a real account (see README.md).

local M = {}

local ORIGIN = "https://deliveroo.fr"
local LOGIN_URL = ORIGIN .. "/fr/api/auth/login"
local AUTH_READ_URL = ORIGIN .. "/fr/api/auth/read"
local ACCOUNT_URL = ORIGIN .. "/fr/api/account/read"
local ORDERS_URL = ORIGIN .. "/fr/orders"

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper - see README.md).
--
-- Login error contract: a rejected username/password always fails the run with exactly
-- `INVALID_CREDENTIALS`, and a rejected, expired or unanswered OTP/MFA step with exactly
-- `MFA_FAILED` (both raised with `error(code, 0)`, so the message carries no position prefix).
-- Any other failure is a free-form error message.
--
-- Log markers (grepped by tests/login_smoke.sh): `LOGIN_PAGE_FOUND` once the login form has
-- been seen, `ALREADY_LOGGED_IN` when a restored session made the login step unnecessary.
-- ---------------------------------------------------------------------------------------------
local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code

local function has(page_or_html, selector)
  local html = type(page_or_html) == "table" and page_or_html.body or page_or_html
  return #fyde.html.select(html or "", selector) > 0
end

local function json_or_nil(body)
  local ok, value = pcall(fyde.json.decode, body or "")
  if ok then
    return value
  end
  return nil
end

-- Downloads `url` and saves it as `filename` when it really is a PDF; returns true on success.
local function save_pdf(url, filename, fields, headers)
  local resp = fyde.http.download(url, headers)
  local content_type = resp.content_type or ""
  local is_pdf = content_type:find("pdf", 1, true) or (resp.body or ""):sub(1, 4) == "%PDF"
  if resp.status == 200 and is_pdf then
    fyde.save_document(sanitize(filename), resp.body, fields)
    return true
  end
  fyde.log.warn(string.format("skipping %s (status %d, content-type %s)", filename, resp.status, content_type))
  return false
end
-- luacheck: pop

-- Common headers of the JSON API calls the web app makes from the login page.
local function api_headers(csrf)
  return {
    accept = "application/json",
    ["x-csrf-token"] = csrf,
    ["x_roo_challenge_support"] = "passcode",
  }
end

-- `/fr/api/account/read` answers 401 without a session, 200 with one.
local function is_logged_in()
  return fyde.http.get(ACCOUNT_URL, { accept = "application/json" }).status == 200
end

-- The SMS one-time code step the login answers with (423 `mfa_required`) when Deliveroo
-- doesn't trust this device yet: `initiate_challenge` sends the code, `complete_challenge`
-- checks it.
local function mfa(csrf, answer)
  local token = answer.mfa_token or ""
  local challenge = "sms:passcode"
  local sent = fyde.http.post_json(ORIGIN .. "/fr/api/auth/initiate_challenge", {
    mfa_token = token,
    challenge = challenge,
    trigger = "send",
    page_in_progress = "login",
  }, api_headers(csrf))
  if sent.status >= 300 then
    fail(MFA_FAILED, "sending the SMS code failed (HTTP " .. sent.status .. ")")
  end
  local code = ask_code("Code reçu par SMS de Deliveroo")
  local done = fyde.http.post_json(ORIGIN .. "/fr/api/auth/complete_challenge", {
    mfa_token = token,
    challenge = challenge,
    data = { passcode = code },
    page_in_progress = "login",
  }, api_headers(csrf))
  if done.status >= 300 then
    fail(MFA_FAILED, "HTTP " .. done.status)
  end
end

local function login(params)
  fyde.progress.step("Logging in")
  local read = json_or_nil(fyde.http.get(AUTH_READ_URL, { accept = "application/json" }).body)
  local csrf = read and read.csrf_token
  if not csrf then
    error("Deliveroo login endpoint not found: no csrf_token from " .. AUTH_READ_URL)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_json(LOGIN_URL, {
    email = params.username,
    password = params.password,
    page_in_progress = "login",
  }, api_headers(csrf))
  local body = json_or_nil(resp.body) or {}
  if resp.status == 401 then
    fail(INVALID_CREDENTIALS, body.msg)
  elseif resp.status == 423 and body.error == "mfa_required" then
    mfa(csrf, body)
  elseif resp.status == 423 then
    -- Deliveroo locks accounts whose password showed up in a breach until it's reset.
    error("Deliveroo requires a password reset for this account: " .. tostring(body.msg_js_link or body.error))
  elseif resp.status >= 300 then
    error("Deliveroo login failed: HTTP " .. resp.status)
  end
  if not is_logged_in() then
    error("Deliveroo login answered HTTP " .. resp.status .. " but no session was opened")
  end
end

-- `/fr/orders` is server-rendered by the Next.js app: the most recent orders (one page of the
-- order history) are in its `__NEXT_DATA__` state, under `order.history.orders`.
local function list_orders()
  local page = fyde.http.get(ORDERS_URL)
  local raw = (page.body or ""):match('<script id="__NEXT_DATA__"[^>]*>(.-)</script>')
  local data = json_or_nil(raw)
  local ok, orders = pcall(function()
    return data.props.initialState.order.history.orders
  end)
  if not ok or type(orders) ~= "table" then
    error("no order history in " .. tostring(page.url))
  end
  return orders
end

local DELIVERED = { DELIVERED = true, PICKED_UP_BY_CUSTOMER = true }

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if is_logged_in() then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading receipts")
  for _, order in ipairs(list_orders()) do
    if DELIVERED[order.status] and order.id then
      local number = tostring(order.id)
      local date = (order.legacySubmittedDate or ""):sub(1, 10)
      local label = trim((order.restaurantName or "") .. " " .. date)
      save_pdf(ORIGIN .. "/order/receipt/" .. number, "deliveroo-" .. number .. ".pdf", {
        name = "Reçu Deliveroo " .. (label ~= "" and label or number),
        type = "invoice",
        category = "shopping",
        subcategory = "food_delivery",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
