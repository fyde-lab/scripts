-- Scraper for Uber's rider account (riders.uber.com): downloads the trip receipts.
--
-- Originally a 2017-era implementation posting
-- e-mail/password/_csrf_token to login.uber.com/login, which now just redirects to
-- auth.uber.com. The current login is auth.uber.com/v2/, a client-rendered (Fusion/React) flow
-- protected by Arkose Labs (served first-party from a *.uber.com host) and reCAPTCHA, so it is
-- driven through `fyde.browser`: riders.uber.com/trips redirects to it without a session; the
-- first step asks for the phone number or e-mail (`#PHONE_NUMBER_or_EMAIL_ADDRESS`, then
-- `#forward-button`), the next one for a password (`#PASSWORD`) or a one-time code sent by
-- e-mail/SMS (`EMAIL_OTP_CODE-*`/`PHONE_SMS_OTP-*` digit boxes), asked via `fyde.input.ask`.
-- Trips are then looked for as `/trips/<uuid>` links on riders.uber.com/trips and each trip's
-- receipt PDF is clicked for in the trip page (unconfirmed without an account).

local M = {}

local TRIPS_URL = "https://riders.uber.com/trips"

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

local LOGIN_FORM = "#PHONE_NUMBER_or_EMAIL_ADDRESS"
local LOGGED_IN = { "logged_in", selector = "a[href*='/trips/'], a[href*='/logout'], [data-testid='trip-card']" }
local PASSWORD = "#PASSWORD, input[name='password'], input[type='password']"
local OTP = "input[id^='EMAIL_OTP_CODE'], input[id^='PHONE_SMS_OTP'], input[id^='PHONE_OTP'], input[autocomplete='one-time-code']"
local FORWARD = { "#forward-button", "button[type='submit']" }

local function recon(label)
  fyde.log.info("RECON " .. label .. ": " .. trim(page_text():gsub("%s+", " ")):sub(1, 800))
end

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    error("Uber login form not found - page says: " .. page_text():sub(1, 300))
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ LOGIN_FORM }, params.username)
  local ready = wait_state({ { "button", selector = "#forward-button:not([disabled])" }, { "password", selector = PASSWORD }, { "otp", selector = OTP } }, 15000)
  recon("after fill (" .. tostring(ready) .. ")")
  if ready == "button" then
    fyde.browser:click("#forward-button")
  end
  local state = wait_state({ { "password", selector = PASSWORD }, { "otp", selector = OTP }, LOGGED_IN }, 45000)
  recon("after identifier step (" .. tostring(state) .. ")")
  local html = page_html()
  for _, b in ipairs(fyde.html.select(html, "#forward-button")) do
    fyde.log.info("RECON button: " .. b.html:sub(1, 300))
  end
  for _, f in ipairs(fyde.html.select(html, "iframe")) do
    fyde.log.info("RECON iframe: " .. tostring(f.attrs.src) .. " id=" .. tostring(f.attrs.id))
  end
  for _, f in ipairs(fyde.html.select(html, "#field-error, [role='alert']")) do
    fyde.log.info("RECON alert: " .. f.text)
  end
  error("recon stop")
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(TRIPS_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end
  fyde.progress.step("Done")
end

return M
