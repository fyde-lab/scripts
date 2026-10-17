-- Scraper for Prixtel (prixtel.com), the mobile operator: downloads the bills and contract
-- documents.
--
-- The original implementation solved the login's
-- reCAPTCHA (key 6LdS0MkjAAAAADsjdsGhlqMCLCLtI7qVOa6O5fo8) through a paid service and posted
-- {captchaKey, captchaToken, email, password, group: "ec"} to `espaceclient.prixtel.com/api/
-- login` - HTTP 403 = bad credentials, 200 = a bearer `token`. Without a captcha solver, the
-- login goes through `fyde.browser` on the customer area (the widget may or may not pass in
-- the webview - unconfirmed). Bills (`/api/bills`) and contract documents
-- (`/api/gsm/customer/msisdn/list`, `/api/gsm/line/<number>`) were fetched with that bearer
-- token and downloaded by POSTing JSON to `external-pxl-aws-s3.prixtel.com/api/file/download`;
-- neither the token (kept by the web app in its own storage) nor a binary POST answer is
-- reachable from this sandbox, so this port clicks the download controls of the customer
-- area's bills page instead. Unverified (see README.md).

local M = {}

local BASE = "https://espaceclient.prixtel.com"
local BAD_CREDENTIALS = { "identifiants incorrects", "mot de passe incorrect", "identifiant ou mot de passe", "incorrect" }

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
local contains = helpers.contains
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

local LOGGED_IN = { "logged_in", text = { "D\195\169connexion", "Mes factures" } }

local function login(params)
  fyde.progress.step("Logging in")
  if not present("input[type='password']") then
    error("Prixtel login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[type='email']", "input[name='email']", "input[type='text']" }, params.username)
  fyde.browser:fill("input[type='password']", params.password)
  click_first({ "button[type='submit']", "input[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS } }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  elseif state ~= "logged_in" then
    if present("input[type='password']") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Prixtel login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(BASE, { LOGGED_IN, { "login", selector = "input[type='password']" } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  open_and_wait(BASE .. "/factures", { { "bills", text = { "T\195\169l\195\169charger" } } }, 30000)
  local count = 0
  for _, control in ipairs(fyde.html.select(page_html(), "a[href], button[id]")) do
    if contains(control.text, "T\195\169l\195\169charger") then
      count = count + 1
      local selector = control.attrs.href and ("a[href='" .. control.attrs.href .. "']") or ("#" .. control.attrs.id)
      browser_save(selector, "PRIXTEL_facture_" .. count .. ".pdf", {
        name = "Facture Prixtel",
        type = "invoice",
        category = "telecom",
        subcategory = "mobile",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
