-- Scraper for Eovi MCD Mutuelle's members, now Aésio mutuelle's member area
-- (adherent.aesio.fr): meant to download the health reimbursement statements.
--
-- The original site
-- (www.espace-particuliers.eovi-mcd-mutuelle.fr) no longer resolves: Eovi MCD merged into
-- Aésio, and eovi-mcd.fr now redirects to aesio.fr, whose "Je me connecte" leads to
-- adherent.aesio.fr/login. That is a client-rendered Angular app (an empty "Navigateur non
-- supporté" shell to plain HTTP), so the login is driven through `fyde.browser`:
-- `form.loginForm` with an `input[type=email]`, an `input[type=password]` (random ids) and a
-- submit button; a wrong login shows "Nous n'avons pas réussi à vous identifier" (checked live,
-- with made-up credentials). The app's menu (including "Déconnexion") is in the page even when
-- logged out, so it can't tell a session apart. Nothing past the login is known yet (no account
-- to look at the app with), so a successful login stops with an explicit error rather than
-- guessing at the documents pages.

local M = {}

local LOGIN_URL = "https://adherent.aesio.fr/login"
local LOGIN_FORM = "form.loginForm"
local BAD_CREDENTIALS = { "Nous n'avons pas réussi à vous identifier", "Nous n’avons pas réussi à vous identifier" }

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
local fail = helpers.fail
local contains_any = helpers.contains_any
local sanitize = helpers.sanitize
local sleep = helpers.sleep
local present = helpers.present
local page_text = helpers.page_text
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first

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
  if open_and_wait(LOGIN_URL, { { "login", selector = LOGIN_FORM .. " input[type='password']" } }, 30000) ~= "login" then
    error("Aésio login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ LOGIN_FORM .. " input[type='email']" }, params.username)
  fill_first({ LOGIN_FORM .. " input[type='password']" }, params.password)
  click_first({ LOGIN_FORM .. " button[type='submit']" })
  -- A successful login leaves /login: its form goes away.
  local waited = 0
  repeat
    sleep(1000)
    waited = waited + 1000
    if contains_any(page_text(), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
  until not present(LOGIN_FORM) or waited >= 30000
  if present(LOGIN_FORM) then
    error("Aésio login did not complete - still on the login form")
  end
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  login(params)
  error("credentials accepted, but the Aésio member area's documents pages aren't ported yet - see "
    .. "this script's header comment", 0)
end

return M
