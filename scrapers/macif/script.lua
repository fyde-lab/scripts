-- Scraper for MACIF's customer area (macif.fr), the mutual insurer: downloads the payment
-- notices ("avis d'échéance") and certificates ("attestations").
--
-- Drives `fyde.browser`: the login is two-step - `#login` then
-- `button[name="submitButton"]`, then `#password` and `button[onclick="postOk();"]` - possibly
-- followed by a strong-authentication step (`.auth-factor` choice, then a `#passcode` code; a
-- refused code is MFA_FAILED) and a "Continuer vers mon espace" link. Logged in shows
-- `#profil-avatar`/`.mcf-navbar__nav`. The original implementation read the documents from
-- `ssm.macif.fr/internet-espaceclient-rest/personnes/<id>/document/...` with intercepted
-- credentials; this port clicks the download links of the documents page (`#avisecheances`,
-- `#attestations`). Unverified (see README.md).

local M = {}

local CHECK_URL = "https://www.macif.fr/assurance/particuliers/acceder-vos-espaces"
local LOGIN_URL = "https://www.macif.fr/assurance/particuliers/acceder-vos-espaces"
local DOCS_URL = "https://www.macif.fr/assurance/particuliers/vos-espaces-macif/espace-assurance/documents"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe est incorrect", "incorrect", "invalide" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = ".auth-factor, #passcode"

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
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code

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

local LOGGED_IN = { "logged_in", selector = "#profil-avatar, .mcf-navbar__nav, button[data-logout]" }
local LOGIN_FORM = "#login"

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("MACIF login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#login" }, params.username)
  local state
  if not present("#password") then
    click_first({ "button[name='submitButton']" })
    state = wait_state({ { "password", selector = "#password" }, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 30000)
    if state == "bad" then
      fail(INVALID_CREDENTIALS, "unknown login")
    end
  end
  fill_first({ "#password" }, params.password)
  click_first({ "button[onclick='postOk();']", "button[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if ".auth-factor" ~= "" and present(".auth-factor") then
      fyde.browser:click(".auth-factor")
      wait_state({ { "code", selector = "#passcode" } }, 20000)
    end
    fill_first({ "#passcode" }, ask_code("Code de vérification MACIF"))
    click_first({ "button[type='submit']", "button" })
    state = wait_state({ LOGGED_IN, { "bad_code", text = BAD_CODE } }, 45000)
    if state ~= "logged_in" then
      fail(MFA_FAILED, page_text():sub(1, 200))
    end
    return
  end
  if state ~= "logged_in" then
    if present("#password") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("MACIF login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(CHECK_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading documents")
  open_and_wait(DOCS_URL, { { "docs", selector = "#avisecheances a[href], #attestations a[href], a[href*='.pdf']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "#avisecheances a[href], #attestations a[href], a[href*='.pdf']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "macif_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Document MACIF" .. " " .. label,
        type = "contract",
        category = "housing",
        subcategory = "home_insurance",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
