-- Scraper for Cdiscount (cdiscount.com), the online retailer: downloads order invoices (or
-- proofs of purchase when an order has no invoice).
--
-- Drives `fyde.browser`: the light login page
-- (now `order.cdiscount.com/Account/LoginLight.html`, reached from the home page's account
-- link), formerly one form (`#CustomerLogin_CustomerLoginFormData_Email`/`..._Password`), now
-- an e-mail step (`#EmailForm`, checked live) then a password step (unconfirmed); logged
-- in when `.leftmenu__logout` is shown; a rejected login re-renders the form with `.c-alert`
-- messages. Orders: `clients.cdiscount.com/order/orderstracking.html` shows one order at a
-- time, chosen with the `#OrderTrackingFormData_SaleFolderId` select; each `#servGuaranteeDiv`
-- block has an `a[title="Imprimer la facture"]` (or "...la preuve d'achat") link.
-- Unverified (see README.md).

local M = {}

-- Opened directly, order.cdiscount.com's login hangs on Cloudflare's interstitial; reached from
-- the home page's account link (once www.cdiscount.com has cleared the check) it loads.
local HOME_URL = "https://www.cdiscount.com/"
local ACCOUNT_LINK = "a[data-e2e='myAccount-icon']"
-- The login is now two-step: `#EmailForm` takes the e-mail alone (an unknown one gets "Aucun
-- compte n'est rattaché à cet email"), then a password field shows up. The same page also
-- holds an account creation form (`#loginCreationForm`) with its own password field.
local EMAIL_STEP = "#EmailForm input[type='email']"
local PASSWORD_STEP = "form:not(#loginCreationForm) input[type='password']"
local UNKNOWN_EMAIL = { "Aucun compte n'est rattaché", "Aucun compte n’est rattaché" }
local ORDERS_URL = "https://clients.cdiscount.com/order/orderstracking.html"
local EMAIL = "#CustomerLogin_CustomerLoginFormData_Email"
local PASSWORD = "#CustomerLogin_CustomerLoginFormData_Password"
local LOGGED_IN = ".leftmenu__logout"
local ORDER_SELECT = "#OrderTrackingFormData_SaleFolderId"
local BAD_CREDENTIALS = { "identifiants", "mot de passe", "incorrect", "invalide" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local function login(params)
  fyde.progress.step("logging_in")
  if not present(EMAIL_STEP) and not present(EMAIL) then
    error("Cdiscount login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present(EMAIL_STEP) then
    fyde.browser:fill(EMAIL_STEP, params.username)
    fyde.browser:click("#EmailForm input[type='submit']")
    local step = wait_state({ { "password", selector = PASSWORD_STEP }, { "unknown", text = UNKNOWN_EMAIL } }, 30000)
    if step == "unknown" then
      fail(INVALID_CREDENTIALS, "no account for this e-mail")
    elseif step ~= "password" then
      error("Cdiscount did not show the password step - page says: " .. page_text():sub(1, 300))
    end
    fyde.browser:fill(PASSWORD_STEP, params.password)
    click_first({ "#LoginForm input[type='submit']", "form:not(#loginCreationForm):not(#EmailForm) input[type='submit']" })
  else
    fyde.browser:fill(EMAIL, params.username)
    fyde.browser:fill(PASSWORD, params.password)
    fyde.browser:click("#LoginForm input[type='submit'], input[type='submit']")
  end
  local state = wait_state({
    { "logged_in", selector = LOGGED_IN },
    { "error", selector = ".c-alert" },
  }, 30000)
  if state == "logged_in" then
    return
  end
  local alerts = fyde.html.select(page_html(), ".c-alert")
  local message = alerts[1] and alerts[1].text or ""
  if state == "error" and (contains_any(message, BAD_CREDENTIALS) or #alerts > 1) then
    fail(INVALID_CREDENTIALS, trim(message))
  end
  if present(EMAIL) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  error("Cdiscount login did not complete - page says: " .. page_text():sub(1, 300))
end

local function save_order_documents()
  for _, block in ipairs(fyde.html.select(page_html(), "#servGuaranteeDiv")) do
    local link = fyde.html.select(block.html, "a[title='Imprimer la facture']")[1]
      or fyde.html.select(block.html, "a[title=\"Imprimer la preuve d'achat\"]")[1]
    if link and link.attrs.href then
      local date = fyde.html.select(block.html, ".czOrderHeaderBlocLeft .date > span")[1]
      local ref = fyde.html.select(block.html, ".czOrderCustomerReference")[1]
      ref = ref and trim((ref.text:match(":(.*)$") or ref.text)) or ""
      browser_save("a[href='" .. link.attrs.href .. "']", (date and sanitize(date.text) or "") .. "_Cdiscount_" .. ref .. ".pdf", {
        name = "Facture Cdiscount " .. ref,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
end

function M.run(params)
  fyde.progress.step("checking_session")
  open_and_wait(HOME_URL, { { "home", selector = ACCOUNT_LINK } }, 30000)
  fyde.browser:click(ACCOUNT_LINK)
  local state = wait_state({ { "logged_in", selector = LOGGED_IN }, { "login", selector = EMAIL_STEP .. ", " .. EMAIL } }, 60000)
  if state == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("downloading_documents")
  open_and_wait(ORDERS_URL, { { "orders", selector = "#orderdetails, " .. ORDER_SELECT } }, 30000)
  local options = fyde.html.select(page_html(), ORDER_SELECT .. " option")
  for i, option in ipairs(options) do
    fyde.progress.update(i, #options)
    if i > 1 then
      -- The page submits its own form when the select changes (the original implementation called
      -- form.submit() itself; `fill` dispatches the same change event).
      fyde.browser:fill(ORDER_SELECT, option.attrs.value)
      sleep(3000)
      wait_state({ { "order", selector = ".czOrderCustomerReference" } }, 20000)
    end
    save_order_documents()
  end
  fyde.progress.step("done")
end

return M
