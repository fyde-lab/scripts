-- Scraper for Productboard (productboard.com), the product-management SaaS: downloads the
-- workspace's subscription invoices.
--
-- The workspace is a required parameter (`workspace`, the `<workspace>.productboard.com`
-- subdomain). The original implementation's form post (`/users/sign_in` with the workspace home's
-- `csrf-token`) is gone: workspaces now sign in on app.productboard.com, a client-rendered form
-- (`[data-testid=LoginForm-EmailField]`/`-PasswordField`/`-Login-Button`) driven through
-- `fyde.browser`; a wrong login shows "Whoops, invalid email and/or password" (checked live,
-- with made-up credentials). `<workspace>/api/all.json` then lists `subscription_invoices`
-- (created_at, total, invoice_url) - read through the webview here, since `fyde.http` only gets
-- the webview's cookies from the next run on (unconfirmed since the move). Unverified (see
-- README.md).

local M = {}

local LOGIN_URL = "https://app.productboard.com/"
local EMAIL = "[data-testid='LoginForm-EmailField']"
local PASSWORD = "[data-testid='LoginForm-PasswordField']"
local BAD_CREDENTIALS = { "invalid email and/or password" }

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
local trim = helpers.trim
local sanitize = helpers.sanitize
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf
local sleep = helpers.sleep
local present = helpers.present
local page_text = helpers.page_text
local open_and_wait = helpers.open_and_wait

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

-- Reads `<base>/api/all.json` through the webview (rendered as text) and returns its invoices.
local function invoices(base)
  fyde.browser:open(base .. "/api/all.json")
  sleep(2000)
  local data = json_or_nil(trim(page_text()))
  return type(data) == "table" and data.subscription_invoices or nil
end

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { { "login", selector = PASSWORD } }, 30000) ~= "login" then
    error("Productboard login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(EMAIL, params.username)
  fyde.browser:fill(PASSWORD, params.password)
  fyde.browser:click("[data-testid='LoginForm-Login-Button']")
  -- A successful login leaves the login form.
  local waited = 0
  repeat
    sleep(1000)
    waited = waited + 1000
    if contains_any(page_text(), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
  until not present(PASSWORD) or waited >= 30000
  if present(PASSWORD) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
end

function M.run(params)
  if not params.workspace or params.workspace == "" then
    error("Productboard needs the `workspace` parameter (the <workspace>.productboard.com subdomain)")
  end
  local base = "https://" .. params.workspace .. ".productboard.com"
  fyde.progress.step("Checking for an existing session")
  local list = invoices(base)
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = invoices(base)
    if not list then
      error("Productboard login accepted, but " .. base .. "/api/all.json didn't list any invoices")
    end
  end

  fyde.progress.step("Downloading invoices")
  for _, invoice in ipairs(list) do
    if invoice.invoice_url then
      local date = tostring(invoice.created_at):sub(1, 10)
      save_pdf(invoice.invoice_url, date .. "_" .. tostring(invoice.total) .. "EUR_" .. tostring(invoice.id) .. ".pdf", {
        name = "Facture Productboard " .. date,
        type = "invoice",
        category = "subscriptions",
        subcategory = "cloud_software",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
