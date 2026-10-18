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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local sleep = helpers.sleep
local present = helpers.present
local page_text = helpers.page_text
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first

local function login(params)
  fyde.progress.step("logging_in")
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
