-- Scraper for Silae, the payroll software's employee space: meant to download the payslips.
--
-- The original implementation spoke SOAP to the SWS web service on
-- silaexpert01.fr - a host that no longer answers. Silae's web access is now mySilae
-- (my.silae.fr), taken here to be that space's successor (unconfirmed - no account to check it
-- with). It is a client-rendered Vue app (an empty shell to plain HTTP), so the login is driven
-- through `fyde.browser`: `form#login-form` holds an email `input[type=text]` and an
-- `input[type=password]`, submitted by a `button[form='login-form']` rendered outside the form;
-- a wrong login shows "Adresse email ou mot de passe incorrect" (checked live, with made-up
-- credentials). Nothing past the login is known yet, so a successful login stops with an
-- explicit error rather than guessing at the payslip pages.

local M = {}

local LOGIN_URL = "https://my.silae.fr/"
local LOGIN_FORM = "form#login-form"
local BAD_CREDENTIALS = { "mot de passe incorrect" }

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
  if open_and_wait(LOGIN_URL, { { "login", selector = LOGIN_FORM .. " input[type='password']" } }, 30000) ~= "login" then
    error("mySilae login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ LOGIN_FORM .. " input[type='text']", LOGIN_FORM .. " input[type='email']" }, params.username)
  fill_first({ LOGIN_FORM .. " input[type='password']" }, params.password)
  click_first({ "button[type='submit'][form='login-form']", "button[type='submit']" })
  -- A successful login leaves the login page: its form goes away.
  local waited = 0
  repeat
    sleep(1000)
    waited = waited + 1000
    if contains_any(page_text(), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
  until not present(LOGIN_FORM) or waited >= 30000
  if present(LOGIN_FORM) then
    error("mySilae login did not complete - still on the login form")
  end
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  login(params)
  error("credentials accepted, but mySilae's payslip pages aren't ported yet - see this script's "
    .. "header comment", 0)
end

return M
