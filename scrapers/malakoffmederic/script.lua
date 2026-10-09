-- Scraper for Malakoff Humanis' (ex Malakoff Médéric) customer extranet
-- (extranet.malakoffhumanis.com): downloads the health reimbursement statements.
--
-- Ported from github.com/konnectors/cozy-konnector-malakoffmederic (src/index.js,
-- src/parsers.js): the login is a DWR (Direct Web Remoting) call made by the page's own JS -
-- `__System.generateId.dwr` for a script session id (set as the `DWRSESSIONID` cookie), then
-- `InternauteValidator.checkConnexion.dwr` with login/password, whose callback answers "OK" on
-- success, "ERREUR_TECHNIQUE" when the vendor is down, anything else for bad credentials.
-- DWR wants a raw text/plain body, which fyde.http can't send (form or JSON only), so the
-- login goes through `fyde.browser` on `/espaceClient/LogonAccess.do` and lets the page make
-- those calls; bad credentials are detected from the page staying on the form with an error.
-- Reimbursements: `/espaceClient/sante/tbs/redirectionAction.do` (a secret question there means
-- a user action is needed), one `#tableauxRemboursements > .body > .toggle` per statement with
-- `#idDecompte`, `#datePaiement` (ms timestamp) and the `#tbsRembExportPdf` link. Unverified
-- (see README.md).

local M = {}

local BASE = "https://extranet.malakoffhumanis.com"
local LOGIN_PAGE = BASE .. "/espaceClient/LogonAccess.do"
local REFUNDS_URL = BASE .. "/espaceClient/sante/tbs/redirectionAction.do"
local PASSWORD = "input[type='password']"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "incorrect", "invalide", "erron" }

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

local LOGGED_IN = { "logged_in", selector = "#tableauxRemboursements, a[href*='Deconnexion'], a[href*='logout']" }

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_PAGE, { { "login", selector = PASSWORD } }, 30000) ~= "login" then
    error("Malakoff Humanis login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[name='login']", "input[name='identifiant']", "input[type='text']" }, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  click_first({ "button[type='submit']", "input[type='submit']", "a.btn-connexion", "#btnConnexion" })
  local state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS } }, 30000)
  if state == "logged_in" then
    return
  end
  if state == "bad" or present(PASSWORD) then
    fail(INVALID_CREDENTIALS, page_text():sub(1, 200))
  end
  if contains(page_html(), "ERREUR_TECHNIQUE") then
    error("Malakoff Humanis reported a technical error (vendor down)")
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(REFUNDS_URL, { LOGGED_IN, { "login", selector = PASSWORD } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    open_and_wait(REFUNDS_URL, { LOGGED_IN, { "question", selector = "input[name='questionSecrete']" } }, 30000)
  end
  if present("input[name='questionSecrete']") then
    error("Malakoff Humanis asks for a secret question: log in once on the website (user action needed)")
  end

  fyde.progress.step("Downloading reimbursement statements")
  for _, group in ipairs(fyde.html.select(page_html(), "#tableauxRemboursements > .body > .toggle")) do
    local id = fyde.html.select(group.html, "#idDecompte")[1]
    local link = fyde.html.select(group.html, "#tbsRembExportPdf")[1]
    if id and link and link.attrs.href then
      id = id.attrs.value or "decompte"
      browser_save("a[href='" .. link.attrs.href .. "']", id .. "_malakoff_mederic.pdf", {
        name = "Décompte Malakoff Humanis " .. id,
        type = "health_invoice",
        source_category = "insurance",
        source_sub_category = "health",
        purpose = "report",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
