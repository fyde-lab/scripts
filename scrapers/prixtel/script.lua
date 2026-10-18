-- Scraper for Prixtel (prixtel.com), the mobile operator: downloads the bills and contract
-- documents.
--
-- The original implementation solved the login's
-- reCAPTCHA (key 6LdS0MkjAAAAADsjdsGhlqMCLCLtI7qVOa6O5fo8) through a paid service and posted
-- {captchaKey, captchaToken, email, password, group: "ec"} to `espaceclient.prixtel.com/api/
-- login` - HTTP 403 = bad credentials, 200 = a bearer `token`. Without a captcha solver, the
-- login goes through `fyde.browser` on the customer area (the widget may or may not pass in
-- the webview - unconfirmed). Bills (`/api/bills`) and contract documents
-- (`/api/gsm/customer/msisdn/list`, `/api/gsm/line/<number>`) were fetched with that bearer
-- token and downloaded by POSTing JSON to `external-pxl-aws-s3.prixtel.com/api/file/download`;
-- neither the token (kept by the web app in its own storage) nor a binary POST answer is
-- reachable from this sandbox, so this port clicks the download controls of the customer
-- area's bills page instead. Unverified (see README.md).

local M = {}

local BASE = "https://espaceclient.prixtel.com"
local BAD_CREDENTIALS = { "identifiants incorrects", "mot de passe incorrect", "identifiant ou mot de passe", "incorrect" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local LOGGED_IN = { "logged_in", text = { "D\195\169connexion", "Mes factures" } }

local function login(params)
  fyde.progress.step("logging_in")
  if not present("input[type='password']") then
    error("Prixtel login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[type='email']", "input[name='email']", "input[type='text']" }, params.username)
  fyde.browser:fill("input[type='password']", params.password)
  click_first({ "button[type='submit']", "input[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS } }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  elseif state ~= "logged_in" then
    if present("input[type='password']") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Prixtel login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  if open_and_wait(BASE, { LOGGED_IN, { "login", selector = "input[type='password']" } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  open_and_wait(BASE .. "/factures", { { "bills", text = { "T\195\169l\195\169charger" } } }, 30000)
  local count = 0
  for _, control in ipairs(fyde.html.select(page_html(), "a[href], button[id]")) do
    if contains(control.text, "T\195\169l\195\169charger") then
      count = count + 1
      local selector = control.attrs.href and ("a[href='" .. control.attrs.href .. "']") or ("#" .. control.attrs.id)
      browser_save(selector, "PRIXTEL_facture_" .. count .. ".pdf", {
        name = "Facture Prixtel",
        type = "invoice",
        category = "telecom",
        subcategory = "mobile",
      })
    end
  end
  fyde.progress.step("done")
end

return M
