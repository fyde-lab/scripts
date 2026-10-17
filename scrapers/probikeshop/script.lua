-- Scraper for Probikeshop (probikeshop.fr), the cycling retailer: downloads order invoices.
--
-- The original `/mon-compte/` login form is
-- gone: probikeshop.fr is now a Shopify store using Shopify's customer accounts
-- (account.probikeshop.fr, through shop.app's OAuth bounce), a JS-only, passwordless login. So it
-- is driven through `fyde.browser`: `probikeshop.fr/account` renders an email form
-- (`#customer-authentication-web-email` + a submit button - confirmed), then a single text
-- input for the 6-digit code Shopify emails (confirmed). Shopify never says whether an email has
-- an account, so a wrong login surfaces as MFA_FAILED, never INVALID_CREDENTIALS; the password
-- parameter is unused. Not verified (no account): the logged-in pages - the session is taken as
-- valid when the account page renders no email form, and invoices are looked for as PDF/
-- "facture" links on account.probikeshop.fr/orders, downloaded through the webview (see
-- README.md).

local M = {}

local ACCOUNT_URL = "https://probikeshop.fr/account"
local ORDERS_URL = "https://account.probikeshop.fr/orders"
local EMAIL_FIELD = "#customer-authentication-web-email"
local CODE_FIELD = "form input[type='text'], input[autocomplete='one-time-code']"
local SUBMIT = "form button[type='submit']"
local LOGGED_IN = "a[href*='/orders'], a[href*='logout']"
local INVOICE_LINKS = "a[href$='.pdf'], a[href*='invoice'], a[href*='facture']"

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
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code

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

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
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

local function sleep(ms)
  pcall(function()
    fyde.browser:wait_for("#__fyde_scraper_sleep__", ms)
  end)
end

local function page_html()
  local ok, html = pcall(function()
    return fyde.browser:html()
  end)
  return ok and html or ""
end

-- Polls the page for up to `timeout_ms` for the first of `states` ({ name, selector }) present.
local function wait_state(states, timeout_ms)
  for _ = 1, math.ceil(timeout_ms / 1000) do
    local html = page_html()
    for _, state in ipairs(states) do
      if has(html, state[2]) then
        return state[1], html
      end
    end
    sleep(1000)
  end
  return nil, page_html()
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Logging in")
  fyde.browser:fill(EMAIL_FIELD, params.username)
  fyde.browser:click(SUBMIT)
  sleep(1500)
  if wait_state({ { "code", CODE_FIELD } }, 30000) ~= "code" then
    error("Probikeshop did not ask for the emailed code after the email")
  end
  fyde.browser:fill(CODE_FIELD, ask_code("Code reçu par e-mail de Probikeshop"))
  fyde.browser:click(SUBMIT)
  sleep(2000)
  local state = wait_state({ { "logged_in", LOGGED_IN }, { "code", CODE_FIELD } }, 30000)
  if state ~= "logged_in" then
    fail(MFA_FAILED, "no account page after the code")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(ACCOUNT_URL)
  sleep(1500)
  local state = wait_state({ { "login", EMAIL_FIELD }, { "logged_in", LOGGED_IN } }, 45000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif state == "login" then
    login(params)
  else
    error("Probikeshop login page not found on " .. ACCOUNT_URL)
  end

  fyde.progress.step("Downloading invoices")
  fyde.browser:open(ORDERS_URL)
  sleep(1500)
  local _, html = wait_state({ { "invoices", INVOICE_LINKS } }, 20000)
  local links = fyde.html.select(html, INVOICE_LINKS)
  if #links == 0 then
    fyde.log.warn("no invoice link found on " .. ORDERS_URL)
  end
  for i, link in ipairs(links) do
    local label = trim(link.text or "")
    local ok, bytes = pcall(function()
      return fyde.browser:download("a[href='" .. link.attrs.href .. "']", 60000)
    end)
    if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
      fyde.save_document(sanitize("probikeshop_" .. i .. "_" .. (label ~= "" and label or "facture") .. ".pdf"), bytes, {
        name = "Facture Probikeshop " .. (label ~= "" and label or tostring(i)),
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    else
      fyde.log.warn("could not download " .. link.attrs.href .. ": " .. tostring(ok and "not a PDF" or bytes))
    end
  end
  fyde.progress.step("Done")
end

return M
