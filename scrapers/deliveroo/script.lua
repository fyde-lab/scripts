-- Scraper for Deliveroo (deliveroo.fr), the food-delivery platform: downloads the receipts of
-- delivered orders.
--
-- Ported from github.com/konnectors/deliveroo (src/index.js): `/fr/login` has `form#login`
-- (whose `action` is the JSON login endpoint) and a `meta[name="csrf-token"]`; the login is
-- posted with the names given by the `inputmode` attributes of the `login_email`/
-- `login_password` inputs, with `x-csrf-token` - success is an answer with a `user.id`.
-- Orders: the `ul.results-list li:has(.status-delivered)` entries of `/fr/orders`, each
-- receipt at `/order/receipt/<order number>`. Deliveroo's site is now a JS app, so this
-- flow may be outdated. Unverified (see README.md).

local M = {}

local ORIGIN = "https://deliveroo.fr"
local LOGIN_URL = ORIGIN .. "/fr/login"
local ORDERS_URL = ORIGIN .. "/fr/orders"

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper ported from github.com/konnectors - see README.md).
--
-- Login error contract: a rejected username/password always fails the run with exactly
-- `INVALID_CREDENTIALS`, and a rejected, expired or unanswered OTP/MFA step with exactly
-- `MFA_FAILED` (both raised with `error(code, 0)`, so the message carries no position prefix).
-- Any other failure is a free-form error message.
--
-- Log markers (grepped by tests/login_smoke.sh): `LOGIN_PAGE_FOUND` once the login form has
-- been seen, `ALREADY_LOGGED_IN` when a restored session made the login step unnecessary.
-- ---------------------------------------------------------------------------------------------
local INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
local MFA_FAILED = "MFA_FAILED"

local function fail(code, detail)
  if detail then
    fyde.log.warn(code .. ": " .. detail)
  end
  error(code, 0)
end

local function contains(haystack, needle)
  return (haystack or ""):lower():find(needle:lower(), 1, true) ~= nil
end

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize(name)
  name = trim((name or ""):gsub("%s+", " "))
  name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

-- Asks the user for a one-time code through fyde.input.ask; an unanswered/empty prompt (or no
-- input handler at all, e.g. an unattended run) is an MFA failure.
local function ask_code(question)
  local ok, code = pcall(fyde.input.ask, question)
  if not ok or type(code) ~= "string" or trim(code) == "" then
    fail(MFA_FAILED, "no one-time code was provided")
  end
  return (code:gsub("%s", ""))
end

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Port of cozy-konnector-libs' `signin({ formSelector })`: reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

-- Fills `values` into the form matching `selector` on `page` and posts it.
local function submit_form(page, selector, values, headers)
  local action, fields = read_form(page, selector)
  if not action then
    error("no form matching '" .. selector .. "' on " .. tostring(page.url))
  end
  for name, value in pairs(values) do
    fields[name] = value
  end
  return fyde.http.post_form(action, fields, headers)
end

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  local form = fyde.html.select(page.body, "form#login")[1]
  if not form then
    error("Deliveroo login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local csrf = fyde.html.select(page.body, "meta[name='csrf-token']")[1]
  local email = fyde.html.select(page.body, "form input[name='login_email']")[1]
  local password = fyde.html.select(page.body, "form input[name='login_password']")[1]
  local resp = fyde.http.post_form(absolute(ORIGIN, form.attrs.action), {
    [email and email.attrs.inputmode or "email"] = params.username,
    [password and password.attrs.inputmode or "password"] = params.password,
  }, { ["x-csrf-token"] = csrf and csrf.attrs.content or "" })
  local body = json_or_nil(resp.body)
  if not (body and body.user and body.user.id) then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if has(page, "ul.results-list") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading receipts")
  for _, order in ipairs(fyde.html.select(page.body, "ul.results-list li")) do
    local link = fyde.html.select(order.html, "a")[1]
    if has(order.html, ".status-delivered") and link and link.attrs.href then
      local number = link.attrs.href:match("([^/]+)$")
      save_pdf(ORIGIN .. "/order/receipt/" .. number, "deliveroo-" .. number .. ".pdf", {
        name = "Reçu Deliveroo " .. number,
        type = "invoice",
        source_category = "alimentation",
        purpose = "invoice",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
