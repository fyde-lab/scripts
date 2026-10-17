-- Scraper for Productboard (productboard.com), the product-management SaaS: downloads the
-- workspace's subscription invoices.
--
-- The workspace is a required parameter (`workspace`, the `<workspace>.productboard.com`
-- subdomain). The original implementation's form post (`/users/sign_in` with the workspace home's
-- `csrf-token`) is gone: workspaces now sign in on app.productboard.com, a client-rendered form
-- (`[data-testid=LoginForm-EmailField]`/`-PasswordField`/`-Login-Button`) driven through
-- `fyde.browser`; a wrong login shows "Whoops, invalid email and/or password" (checked live,
-- with made-up credentials). `<workspace>/api/all.json` then lists `subscription_invoices`
-- (created_at, total, invoice_url) - read through the webview here, since `fyde.http` only gets
-- the webview's cookies from the next run on (unconfirmed since the move). Unverified (see
-- README.md).

local M = {}

local LOGIN_URL = "https://app.productboard.com/"
local EMAIL = "[data-testid='LoginForm-EmailField']"
local PASSWORD = "[data-testid='LoginForm-PasswordField']"
local BAD_CREDENTIALS = { "invalid email and/or password" }

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
local contains_any = helpers.contains_any
local trim = helpers.trim

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

-- `wait_for` only waits for a selector to appear, so sleeping means waiting on one that never
-- exists.
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

local function present(selector)
  return #fyde.html.select(page_html(), selector) > 0
end

local function page_text()
  local body = fyde.html.select(page_html(), "body")[1]
  return body and body.text or ""
end

-- Polls the current page until one of `states` matches and returns its name (or nil after
-- `timeout_ms`). Each state is `{ name, selector = css }` or `{ name, text = { needles } }`.
-- Polling in short chunks also survives `fyde.browser:open` not waiting for navigation (a
-- `wait_for` issued against the previous page just times out and gets retried).
local function wait_state(states, timeout_ms)
  local waited = 0
  repeat
    local html = page_html()
    local text
    for _, state in ipairs(states) do
      if state.selector and #fyde.html.select(html, state.selector) > 0 then
        return state[1]
      end
      if state.text then
        if not text then
          local body = fyde.html.select(html, "body")[1]
          text = body and body.text or ""
        end
        if contains_any(text, state.text) then
          return state[1]
        end
      end
    end
    sleep(1000)
    waited = waited + 1000
  until waited >= (timeout_ms or 30000)
  return nil
end

local function open_and_wait(url, states, timeout_ms)
  fyde.browser:open(url)
  sleep(1500)
  return wait_state(states, timeout_ms)
end

-- Fills the first present selector of each candidate list.
local function fill_first(selectors, value)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:fill(selector, value)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

local function click_first(selectors)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:click(selector)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

-- Clicks `selector` (a download link/button) and saves what the browser downloads.
local function browser_save(selector, filename, fields)
  local ok, bytes = pcall(function()
    return fyde.browser:download(selector, 60000)
  end)
  if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
    fyde.save_document(sanitize(filename), bytes, fields)
    return true
  end
  fyde.log.warn("could not download " .. filename .. ": " .. tostring(ok and "not a PDF" or bytes))
  return false
end
-- luacheck: pop

-- Reads `<base>/api/all.json` through the webview (rendered as text) and returns its invoices.
local function invoices(base)
  fyde.browser:open(base .. "/api/all.json")
  sleep(2000)
  local data = json_or_nil(trim(page_text()))
  return type(data) == "table" and data.subscription_invoices or nil
end

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { { "login", selector = PASSWORD } }, 30000) ~= "login" then
    error("Productboard login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(EMAIL, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  fyde.browser:click("[data-testid='LoginForm-Login-Button']")
  -- A successful login leaves the login form.
  local waited = 0
  repeat
    sleep(1000)
    waited = waited + 1000
    if contains_any(page_text(), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
  until not present(PASSWORD) or waited >= 30000
  if present(PASSWORD) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
end

function M.run(params)
  if not params.workspace or params.workspace == "" then
    error("Productboard needs the `workspace` parameter (the <workspace>.productboard.com subdomain)")
  end
  local base = "https://" .. params.workspace .. ".productboard.com"
  fyde.progress.step("Checking for an existing session")
  local list = invoices(base)
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = invoices(base)
    if not list then
      error("Productboard login accepted, but " .. base .. "/api/all.json didn't list any invoices")
    end
  end

  fyde.progress.step("Downloading invoices")
  for _, invoice in ipairs(list) do
    if invoice.invoice_url then
      local date = tostring(invoice.created_at):sub(1, 10)
      save_pdf(invoice.invoice_url, date .. "_" .. tostring(invoice.total) .. "EUR_" .. tostring(invoice.id) .. ".pdf", {
        name = "Facture Productboard " .. date,
        type = "invoice",
        category = "subscriptions",
        subcategory = "cloud_software",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
