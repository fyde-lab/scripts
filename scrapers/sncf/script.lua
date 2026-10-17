-- Scraper for SNCF Connect (sncf-connect.com): downloads the trip proofs ("justificatifs de
-- voyage") of past trips.
--
-- Drives `fyde.browser`: `/app/account` shows either the
-- `button[data-test="account-disconnect-button"]` (logged in) or a "Se connecter" card button
-- (`.MuiCardContent-root > div > button`) leading to the SNCF account form (`#login`,
-- `#pass1`, `#validate`; errors in `.error`), possibly followed by an `#otpCode` step and an
-- `#accessAccount` "continue" button. Past trips are under `/app/trips` (`#nav-tab-1`,
-- `li[data-test="trip"]`); the original implementation took each trip's proof URL from the intercepted trips
-- API answer (`tripDetails...tripProofOperation.url`) - this port looks for those same JSON
-- fields in the rendered page and downloads them. Unverified (see README.md).
--
-- The site is behind Datadome, which (at least for a fresh webview) answers `/app/account` with
-- an interactive captcha stub (`'rt':'c'`, served from geo.captcha-delivery.com) instead of the
-- app. The script never touches the captcha: `wait_past_datadome` gives a human a few minutes
-- to solve it in a `--visible` window, then carries on (the `datadome` cookie should spare the
-- following runs), or fails with an explicit "blocked by a Datadome captcha" error.

local M = {}

local ACCOUNT_URL = "https://www.sncf-connect.com/app/account"
local TRIPS_URL = "https://www.sncf-connect.com/app/trips"
local LOGGED_IN = { "logged_in", selector = "button[data-test='account-disconnect-button']" }
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "incorrect", "invalide" }
-- Datadome answers some page loads with a stub whose inline script (`var dd={'rt':'c', ...,
-- 'host':'geo.captcha-delivery.com', ...}`) loads an interactive captcha from that host
-- (hence `captcha-delivery.com` in manifest.json's `allowed_domains`) instead of the app.
local DATADOME = { "datadome", text = { "captcha-delivery.com" } }
local DATADOME_TIMEOUT_MS = 180000

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
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local has = helpers.has
local save_pdf = helpers.save_pdf
local sleep = helpers.sleep
local page_html = helpers.page_html

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

-- Summarises the current page (its controls and text) for an error message, so a failure on
-- this client-rendered site says what was rendered instead of the expected element.
local function describe_page()
  local html = page_html()
  local controls = {}
  for _, el in ipairs(fyde.html.select(html, "button, a[href*='login'], a[href*='connect'], input, [data-test]")) do
    local label = trim((el.text or ""):gsub("%s+", " ")):sub(1, 40)
    local attrs = {}
    for _, name in ipairs({ "id", "name", "type", "data-test", "href" }) do
      if el.attrs[name] then
        attrs[#attrs + 1] = name .. "=" .. el.attrs[name]
      end
    end
    controls[#controls + 1] = "[" .. table.concat(attrs, " ") .. (label ~= "" and (" '" .. label .. "'") or "") .. "]"
    if #controls >= 40 then
      break
    end
  end
  return string.format("%d bytes of HTML; controls: %s; page says: %s", #html, table.concat(controls, " "), page_text():sub(1, 400))
end

-- Waits on `states` like `wait_state`, but when Datadome's captcha shows up instead, gives a
-- human (a `--visible` window) `DATADOME_TIMEOUT_MS` to solve it, then keeps waiting on
-- `states` once the real page is back. The script never interacts with the captcha itself.
local function wait_past_datadome(states, timeout_ms)
  local all = { DATADOME }
  for _, state in ipairs(states) do
    all[#all + 1] = state
  end
  local state = wait_state(all, timeout_ms)
  if state ~= "datadome" then
    return state
  end
  fyde.progress.step("Waiting for the SNCF Connect captcha to be solved in the browser window")
  fyde.log.warn("Datadome captcha shown; it must be solved by hand in the browser window (--visible)")
  -- Polls with `wait_for` alone: `html()` can take its full 10s timeout on the captcha page, and
  -- the sandbox has no clock, so each round must have a known upper bound (5s, +1s driver slack)
  -- for DATADOME_TIMEOUT_MS to mean anything.
  local selectors = {}
  for _, s in ipairs(states) do
    selectors[#selectors + 1] = s.selector
  end
  local target = table.concat(selectors, ", ")
  for _ = 1, DATADOME_TIMEOUT_MS / 5000 do
    if pcall(function()
      fyde.browser:wait_for(target, 5000)
    end) then
      return wait_state(states, timeout_ms)
    end
  end
  -- Not re-checked through `page_html()`: once the captcha's iframe has loaded the page stops
  -- answering script evals, so it reads back as "" rather than as the captcha.
  error("SNCF Connect is blocked by a Datadome captcha - run with --visible and solve it in the browser window")
end

local function login(params)
  fyde.progress.step("Logging in")
  for _, button in ipairs(fyde.html.select(page_html(), ".MuiCardContent-root > div > button")) do
    if contains(button.text, "Se connecter") then
      fyde.browser:click(".MuiCardContent-root > div > button")
    end
  end
  if wait_past_datadome({ { "form", selector = "#login" } }, 30000) ~= "form" then
    error("SNCF Connect login form not found - " .. describe_page())
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("#login", params.username)
  fyde.browser:fill("#pass1", params.password)
  fyde.browser:click("#validate")
  local state = wait_past_datadome({ LOGGED_IN, { "otp", selector = "#otpCode" }, { "error", selector = ".error" } }, 45000)
  if state == "error" then
    local err = fyde.html.select(page_html(), ".error")[1]
    if contains_any(err and err.text, BAD_CREDENTIALS) or present("#pass1") then
      fail(INVALID_CREDENTIALS, err and trim(err.text))
    end
    error("SNCF login error: " .. (err and trim(err.text) or ""))
  elseif state == "otp" then
    fyde.browser:fill("#otpCode", ask_code("Code de vérification SNCF Connect"))
    click_first({ "#validate", "button[type='submit']", "input[type='submit']" })
    state = wait_state({ LOGGED_IN, { "continue", selector = "#accessAccount" }, { "otp_error", selector = "#otpCode ~ .error, .error" } }, 45000)
    if state == "continue" then
      fyde.browser:click("#accessAccount")
      state = wait_state({ LOGGED_IN }, 30000)
    end
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
  elseif state ~= "logged_in" then
    if present("#pass1") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("SNCF Connect login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(ACCOUNT_URL)
  local state = wait_past_datadome({ LOGGED_IN, { "login", selector = ".MuiCardContent-root > div > button, #login" } }, 45000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading trip proofs")
  fyde.browser:open(TRIPS_URL)
  wait_past_datadome({ { "trips", selector = "#nav-tab-1" } }, 30000)
  if present("#nav-tab-1") then
    fyde.browser:click("#nav-tab-1")
    wait_state({ { "trip", selector = "li[data-test='trip']" } }, 30000)
  end
  local seen, count = {}, 0
  for url in page_html():gmatch('"tripProofOperation"%s*:%s*{[^}]-"url"%s*:%s*"([^"]+)"') do
    url = url:gsub("\\u002F", "/"):gsub("\\/", "/")
    if not seen[url] then
      seen[url] = true
      count = count + 1
      save_pdf(url, "SNCF_justificatif_" .. count .. ".pdf", {
        name = "Justificatif de voyage SNCF",
        type = "invoice",
        category = "transport",
        subcategory = "train",
      })
    end
  end
  if count == 0 then
    fyde.log.warn("no trip proof URL found in the trips page")
  end
  fyde.progress.step("Done")
end

return M
