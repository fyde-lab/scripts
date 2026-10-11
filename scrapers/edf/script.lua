-- Scraper for EDF's customer area (particulier.edf.fr): downloads the electricity bills.
--
-- Drives `fyde.browser`. The EDF login (`.auth` pages) is two-step: `#email` then
-- `#username-next-button`, then `#password2-password-field` and `#password2-next-button`; a
-- `.field-container--error` after the password means bad credentials, and `.auth #title-hotp3`
-- an e-mail/SMS one-time code (the original implementation stopped with OTP_NEEDED; here the code is asked and
-- typed in, a refused code being MFA_FAILED). Logged in, the customer area links to
-- `factures-et-paiements.html`, whose `#facture`/`#factureSelection` view lists the bills; the
-- original implementation read them from intercepted API answers, this port clicks their download controls.
-- EDF also runs bot protection, which may block the embedded webview (unconfirmed).
-- Unverified (see README.md).

local M = {}

local BASE = "https://particulier.edf.fr"
local HOME_URL = BASE .. "/fr/accueil/espace-client/tableau-de-bord.html"
local BILLS_URL = BASE .. "/fr/accueil/espace-client/factures-et-paiements.html"

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

local LOGGED_IN = { "logged_in", selector = "a.accessPage[href*='factures-et-paiements.html'], a[href*='moduleopenidc.html?logout'], .timeline-header__download" }

local function login(params)
  fyde.progress.step("Logging in")
  if wait_state({ { "email", selector = ".auth #email, #email" } }, 30000) ~= "email" then
    error("EDF login form not found (bot protection?)")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill("#email", params.username)
  click_first({ "#username-next-button > span", "#username-next-button" })
  local state = wait_state({
    { "password", selector = "#password2-password-field" },
    { "otp", selector = ".auth #title-hotp3" },
    { "bad", selector = ".field-container--error" },
  }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS, "unknown e-mail")
  end
  if state == "password" then
    fyde.browser:fill("#password2-password-field", params.password)
    click_first({ "#password2-next-button > span", "#password2-next-button" })
    state = wait_state({ LOGGED_IN, { "otp", selector = ".auth #title-hotp3" }, { "bad", selector = ".field-container--error" } }, 45000)
    if state == "bad" then
      fail(INVALID_CREDENTIALS)
    end
  end
  if state == "otp" then
    fill_first({ "input[autocomplete='one-time-code']", ".auth input[type='text']", ".auth input[type='tel']" }, ask_code("Code de vérification EDF"))
    click_first({ "button[type='submit']", ".auth button" })
    state = wait_state({ LOGGED_IN, { "bad", selector = ".field-container--error" } }, 45000)
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
  elseif state ~= "logged_in" then
    error("EDF login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "#email" } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  open_and_wait(BILLS_URL, { { "bills", selector = "#facture, #factureSelection" } }, 45000)
  if present("#facture") then
    fyde.browser:click("#facture")
    sleep(3000)
  end
  local count = 0
  for _, control in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[download], button[id*='telecharg'], a[id*='telecharg']")) do
    count = count + 1
    local selector = control.attrs.href and ("a[href='" .. control.attrs.href .. "']") or ("#" .. control.attrs.id)
    local label = trim(control.text) ~= "" and trim(control.text) or tostring(count)
    browser_save(selector, "EDF_facture_" .. sanitize(label) .. ".pdf", {
      name = "Facture EDF " .. label,
      type = "energy_invoice",
      source_category = "energy",
      purpose = "invoice",
    })
  end
  fyde.progress.step("Done")
end

return M
