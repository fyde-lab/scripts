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

local M = {}

local ACCOUNT_URL = "https://www.sncf-connect.com/app/account"
local TRIPS_URL = "https://www.sncf-connect.com/app/trips"
local LOGGED_IN = { "logged_in", selector = "button[data-test='account-disconnect-button']" }
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "incorrect", "invalide" }

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

local function login(params)
  fyde.progress.step("Logging in")
  for _, button in ipairs(fyde.html.select(page_html(), ".MuiCardContent-root > div > button")) do
    if contains(button.text, "Se connecter") then
      fyde.browser:click(".MuiCardContent-root > div > button")
    end
  end
  if wait_state({ { "form", selector = "#login" } }, 30000) ~= "form" then
    error("SNCF Connect login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("#login", params.username)
  fyde.browser:fill("#pass1", params.password)
  fyde.browser:click("#validate")
  local state = wait_state({ LOGGED_IN, { "otp", selector = "#otpCode" }, { "error", selector = ".error" } }, 45000)
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
  local state = open_and_wait(ACCOUNT_URL, { LOGGED_IN, { "login", selector = ".MuiCardContent-root > div > button, #login" } }, 45000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading trip proofs")
  open_and_wait(TRIPS_URL, { { "trips", selector = "#nav-tab-1" } }, 30000)
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
        type = "transport_invoice",
        source_category = "transport",
        purpose = "invoice",
      })
    end
  end
  if count == 0 then
    fyde.log.warn("no trip proof URL found in the trips page")
  end
  fyde.progress.step("Done")
end

return M
