-- Scraper for PayFit (app.payfit.com), the payroll software: downloads the employee's payslips.
--
-- Drives `fyde.browser`: the login is two-step - the e-mail (formerly `#username`, now
-- an id-less `input[type=email]`) then the form's submit button ("Continuer"), then `#password`
-- and the same button (a wrong login shows "E-mail ou mot de passe incorrect" - checked live) -
-- possibly followed by a `#code` verification step (a refused code is MFA_FAILED); logged in shows the
-- `button[data-testid="accountButton"]`. The original implementation listed payslips from the intercepted
-- `api.payfit.com/files` answer and downloaded each through
-- `files/file/<id>/presigned-url` with the intercepted bearer token; neither is reachable here,
-- so this port clicks the download controls of the payslips page (`/payslips`, URL
-- unconfirmed). Unverified (see README.md).

local M = {}

local CHECK_URL = "https://app.payfit.com/"
local LOGIN_URL = "https://app.payfit.com/login"
local DOCS_URL = "https://app.payfit.com/payslips"
local BAD_CREDENTIALS = { "Wrong email or password", "mot de passe incorrect", "E-mail ou mot de passe incorrect" }
local BAD_CODE = { "code incorrect", "code invalide", "code erron", "expir" }
local MFA = "#code"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", selector = "button[data-testid='accountButton']" }
-- The e-mail field lost its `#username` id: it's now the form's only `input[type=email]`.
local LOGIN_FORM = "#username, form input[type='email']"

local function login(params)
  fyde.progress.step("Logging in")
  if not present(LOGIN_FORM) then
    open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = LOGIN_FORM } }, 30000)
  end
  if not present(LOGIN_FORM) then
    error("PayFit login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "#username", "form input[type='email']" }, params.username)
  local state
  if not present("#password") then
    click_first({ "._button-login-id", "form button[type='submit']", "button[type='submit']" })
    state = wait_state({ { "password", selector = "#password" }, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 30000)
    if state == "bad" then
      fail(INVALID_CREDENTIALS, "unknown login")
    end
  end
  fill_first({ "#password" }, params.password)
  click_first({ "._button-login-password", "form button[type='submit']", "button[type='submit']" })
  state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS }, { "mfa", selector = MFA } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if state == "mfa" then
    if "" ~= "" and present("") then
      fyde.browser:click("")
      wait_state({ { "code", selector = "#code" } }, 20000)
    end
    fill_first({ "#code" }, ask_code("Code de vérification PayFit"))
    click_first({ "button[type='submit']" })
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
    error("PayFit login did not complete - page says: " .. page_text():sub(1, 300))
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
  open_and_wait(DOCS_URL, { { "docs", selector = "a[href*='.pdf'], a[download], a[href*='presigned'], button[data-testid*='download']" } }, 45000)
  local count = 0
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='.pdf'], a[download], a[href*='presigned'], button[data-testid*='download']")) do
    local selector = link.attrs.href and ("a[href='" .. link.attrs.href .. "']") or (link.attrs.id and ("#" .. link.attrs.id))
    if selector then
      count = count + 1
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(count)
      browser_save(selector, "payfit_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Bulletin de paie PayFit" .. " " .. label,
        type = "payslip",
        category = "work",
        subcategory = "payslips",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
