-- Scraper for Probikeshop (probikeshop.fr), the cycling retailer: downloads order invoices.
--
-- The original `/mon-compte/` login form is
-- gone: probikeshop.fr is now a Shopify store using Shopify's customer accounts
-- (account.probikeshop.fr, through shop.app's OAuth bounce), a JS-only, passwordless login. So it
-- is driven through `fyde.browser`: `probikeshop.fr/account` renders an email form
-- (`#customer-authentication-web-email` + a submit button - confirmed), then a single text
-- input for the 6-digit code Shopify emails (confirmed). Shopify never says whether an email has
-- an account, so a wrong login surfaces as MFA_FAILED, never INVALID_CREDENTIALS; the password
-- parameter is unused. Not verified (no account): the logged-in pages - the session is taken as
-- valid when the account page renders no email form, and invoices are looked for as PDF/
-- "facture" links on account.probikeshop.fr/orders, downloaded through the webview (see
-- README.md).

local M = {}

local ACCOUNT_URL = "https://probikeshop.fr/account"
local ORDERS_URL = "https://account.probikeshop.fr/orders"
local EMAIL_FIELD = "#customer-authentication-web-email"
local CODE_FIELD = "form input[type='text'], input[autocomplete='one-time-code']"
local SUBMIT = "form button[type='submit']"
local LOGGED_IN = "a[href*='/orders'], a[href*='logout']"
local INVOICE_LINKS = "a[href$='.pdf'], a[href*='invoice'], a[href*='facture']"

local helpers = fyde.helpers
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local has = helpers.has
local sleep = helpers.sleep
local page_html = helpers.page_html

-- Polls the page for up to `timeout_ms` for the first of `states` ({ name, selector }) present.
local function wait_state(states, timeout_ms)
  for _ = 1, math.ceil(timeout_ms / 1000) do
    local html = page_html()
    for _, state in ipairs(states) do
      if has(html, state[2]) then
        return state[1], html
      end
    end
    sleep(1000)
  end
  return nil, page_html()
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("logging_in")
  fyde.browser:fill(EMAIL_FIELD, params.username)
  fyde.browser:click(SUBMIT)
  sleep(1500)
  if wait_state({ { "code", CODE_FIELD } }, 30000) ~= "code" then
    error("Probikeshop did not ask for the emailed code after the email")
  end
  fyde.browser:fill(CODE_FIELD, ask_code("Code reçu par e-mail de Probikeshop"))
  fyde.browser:click(SUBMIT)
  sleep(2000)
  local state = wait_state({ { "logged_in", LOGGED_IN }, { "code", CODE_FIELD } }, 30000)
  if state ~= "logged_in" then
    fail(MFA_FAILED, "no account page after the code")
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  fyde.browser:open(ACCOUNT_URL)
  sleep(1500)
  local state = wait_state({ { "login", EMAIL_FIELD }, { "logged_in", LOGGED_IN } }, 45000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif state == "login" then
    login(params)
  else
    error("Probikeshop login page not found on " .. ACCOUNT_URL)
  end

  fyde.progress.step("downloading_documents")
  fyde.browser:open(ORDERS_URL)
  sleep(1500)
  local _, html = wait_state({ { "invoices", INVOICE_LINKS } }, 20000)
  local links = fyde.html.select(html, INVOICE_LINKS)
  if #links == 0 then
    fyde.log.warn("no invoice link found on " .. ORDERS_URL)
  end
  for i, link in ipairs(links) do
    local label = trim(link.text or "")
    local ok, bytes = pcall(function()
      return fyde.browser:download("a[href='" .. link.attrs.href .. "']", 60000)
    end)
    if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
      fyde.save_document(sanitize("probikeshop_" .. i .. "_" .. (label ~= "" and label or "facture") .. ".pdf"), bytes, {
        name = "Facture Probikeshop " .. (label ~= "" and label or tostring(i)),
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    else
      fyde.log.warn("could not download " .. link.attrs.href .. ": " .. tostring(ok and "not a PDF" or bytes))
    end
  end
  fyde.progress.step("done")
end

return M
