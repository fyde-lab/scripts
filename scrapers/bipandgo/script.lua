-- Scraper for Bip&Go (bipandgo.com), a French motorway toll-badge provider: downloads the
-- invoices listed under "Mon compte > Factures".
--
-- The original implementation logged in by
-- solving the login page's reCAPTCHA v2 (sitekey 6Lc1dyMUAAAAAASglHuUf-6pMMFKMgCt8ASs9ck1)
-- through a paid solving service and posting the token with username/password to
-- `/volatile_cache_context/`. This sandbox has no captcha solver, so the login goes through
-- `fyde.browser` instead: the real page renders its own reCAPTCHA, which may or may not pass
-- invisibly in the embedded webview (unconfirmed). A failed login is detected as in the original implementation:
-- the invoices page still not reachable (it answered 401 / redirected back to the form).
--
-- Invoices: `tbody.badges-block__table-body tr` rows on `/mon_compte/factures`, paginated by
-- 15 with `?invoice_listbox_list_start=N` while an `a[rel="next"]` exists; the PDF link is in
-- the 4th cell. Downloaded through the browser (its cookies only reach `fyde.http` on the next
-- run). Unverified (see README.md).

local M = {}

local BASE = "https://www.bipandgo.com"
local LOGIN_URL = BASE .. "/login_form"
local BILLS_URL = BASE .. "/mon_compte/factures"
local INVOICE_ROWS = "tbody.badges-block__table-body tr"
local BAD_CREDENTIALS = { "identifiant ou mot de passe", "mot de passe incorrect", "login failed", "incorrect" }

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
local fill_first = helpers.fill_first
local click_first = helpers.click_first
local browser_save = helpers.browser_save

local STATES = {
  { "logged_in", selector = INVOICE_ROWS .. ", a[href*='logout']" },
  { "login", selector = "input[name='__ac_password'], input[name='password'], input[type='password']" },
}

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { STATES[2] }, 30000) ~= "login" then
    error("Bip&Go login form not found on " .. LOGIN_URL)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fill_first({ "input[name='__ac_name']", "input[name='username']", "input[type='email']" }, params.username)
  fill_first({ "input[name='__ac_password']", "input[name='password']", "input[type='password']" }, params.password)
  click_first({ "form button[type='submit']", "form input[type='submit']" })
  sleep(5000)
  if open_and_wait(BILLS_URL, STATES, 30000) ~= "logged_in" then
    if contains_any(page_text(), BAD_CREDENTIALS) or present(STATES[2].selector) then
      fail(INVALID_CREDENTIALS, "invoices page still not reachable after login")
    end
    error("login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(BILLS_URL, STATES, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading invoices")
  local start = 0
  repeat
    fyde.browser:open(BILLS_URL .. "/?invoice_listbox_list_start=" .. start)
    wait_state({ STATES[1] }, 20000)
    local html = page_html()
    for _, row in ipairs(fyde.html.select(html, INVOICE_ROWS)) do
      local cells = fyde.html.select(row.html, "td")
      local link = cells[4] and fyde.html.select(cells[4].html, "a")[1]
      if link and link.attrs.href then
        local ref, date = trim(cells[1].text), trim(cells[2].text)
        browser_save("a[href='" .. link.attrs.href .. "']", sanitize(date) .. "_" .. ref .. ".pdf", {
          name = "Facture Bip&Go " .. date,
          type = "invoice",
          category = "transport",
          subcategory = "road",
        })
      end
    end
    start = start + 15
  until #fyde.html.select(html, "a[rel='next']") == 0
  fyde.progress.step("Done")
end

return M
