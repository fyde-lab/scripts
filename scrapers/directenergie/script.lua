-- Scraper for TotalEnergies' customer area (totalenergies.fr, ex Direct Énergie): downloads the
-- electricity/gas bills and the contract.
--
-- Drives `fyde.browser`: `/clients/accueil` shows either a
-- logged-in page (logout link `a[href*="/clients/connexion?logintype=logout"]` or
-- `a[href="/clients/mon-compte/gerer-mes-comptes"]`) or the login form
-- (`#formz-authentification-form-login`, `#formz-authentification-form-password`,
-- `#js--btn-validation`); a maintenance page (maintenance.direct-energie.com) means the vendor
-- is down. Bills: `/clients/mes-factures/mon-historique-de-factures`, one `div.detail-facture`
-- per bill in `#js--historique-container-elec` / `#js--historique-container-gaz`, and the
-- contract's `a[href*="/telechargement-des-contrats"]`; all downloaded through the browser.
-- Accounts with several contracts only get the selected one (the original implementation looped over
-- `[id*="js--listjs-comptes-"]`). Unverified (see README.md).

local M = {}

local BASE = "https://www.totalenergies.fr"
local HOME_URL = BASE .. "/clients/accueil"
local BILLS_URL = BASE .. "/clients/mes-factures/mon-historique-de-factures"
local LOGIN = "#formz-authentification-form-login"
local PASSWORD = "#formz-authentification-form-password"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "identifiants sont incorrects", "incorrect" }

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

local LOGGED_IN = { "logged_in", selector = "a[href*='/clients/connexion?logintype=logout'], a[href='/clients/mon-compte/gerer-mes-comptes']" }

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN) then
    error("TotalEnergies login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(LOGIN, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  fyde.browser:click("#js--btn-validation")
  local state = wait_state({ LOGGED_IN, { "bad", selector = ".formz-error, .alert-danger, .message-erreur" } }, 45000)
  if state == "logged_in" then
    return
  end
  if contains_any(page_text(), BAD_CREDENTIALS) or present(PASSWORD) then
    fail(INVALID_CREDENTIALS)
  end
  error("TotalEnergies login did not complete - page says: " .. page_text():sub(1, 300))
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local state = open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = LOGIN }, { "maintenance", text = { "maintenance" } } }, 45000)
  if state == "maintenance" then
    error("TotalEnergies' customer area is under maintenance (vendor down)")
  elseif state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  open_and_wait(BILLS_URL, { { "bills", selector = "div.detail-facture, a[href*='/telechargement-des-contrats']" } }, 30000)
  local html = page_html()
  local count = 0
  for _, bill in ipairs(fyde.html.select(html, "div.detail-facture")) do
    local link = fyde.html.select(bill.html, "a[href]")[1]
    if link then
      count = count + 1
      local date = bill.text:match("(%d%d/%d%d/%d%d%d%d)") or tostring(count)
      browser_save("a[href='" .. link.attrs.href .. "']", sanitize(date) .. "_TotalEnergies_facture.pdf", {
        name = "Facture TotalEnergies " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  local contract = fyde.html.select(html, "a[href*='/telechargement-des-contrats']")[1]
  if contract then
    browser_save("a[href='" .. contract.attrs.href .. "']", "TotalEnergies_Contrat.pdf", {
      name = "Contrat TotalEnergies",
      type = "contract",
      category = "housing",
      subcategory = "energy",
    })
  end
  fyde.progress.step("Done")
end

return M
