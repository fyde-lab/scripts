-- Scraper for Sosh (Orange's online brand) customer area (espace-client.orange.fr?sosh=): downloads
-- the mobile and internet bills of every Sosh contract.
--
-- Sosh shares Orange's login and bills logic, so it drives `fyde.browser` too and
-- this is the `orange` scraper with Sosh's home URL. Login on login.orange.fr is a two-step React form: `#login` (then submit), then `#password` (then submit), with possible
-- detours the original implementation handled - "choose other account" (`[data-testid=choose-other-account]`),
-- "stay connected" (`button[data-testid="button-keepconnected"]`), a reload button, a captcha
-- (`div[class*="captcha_responseContainer"]`, not solvable here) or Mobile Connect
-- (`button[data-testid="submit-mc"]`, an approval on the phone). Contracts are listed on
-- `/accueil` (`ecm-section-bill`); each has `/facture-paiement/<cid>` whose
-- "historique des factures" lists the PDFs (`/ecd_wp/facture/v1.0/pdf...`). The original implementation read
-- those lists from intercepted API answers; this port clicks the download links instead.
-- Unverified (see README.md).

local M = {}

local LOGIN_URL = "https://login.orange.fr/"
local HOME_URL = "https://espace-client.orange.fr/accueil?sosh="
local CLIENT = "https://espace-client.orange.fr"
local BRAND = "Sosh"
local BAD_CREDENTIALS = { "non reconnu", "mot de passe incorrect", "identifiant ou mot de passe", "identifiant incorrect", "n'est pas reconnu", "compte est bloqu" }

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
local trim = helpers.trim
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code
local sleep = helpers.sleep
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
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

local LOGGED_IN = { "logged_in", selector = "ecm-section-bill, a[href*='/facture-paiement/']" }

-- `#btnSubmit` is a web component wrapping the real button: clicking it doesn't submit.
local function submit()
  click_first({ "button[data-testid='submit-login']", "button[data-testid='submit-password']", "button[type='submit']", "#btnSubmit" })
end

-- A refused identifier/password only shows in the page title (e.g. "Identifiant non reconnu -
-- Identification Orange"), which `wait_state`'s text check (the body) doesn't see.
local function wait_step(states, timeout_ms)
  local waited = 0
  repeat
    local state = wait_state(states, 1000)
    if state then
      return state
    end
    local title = fyde.html.select(page_html(), "title")[1]
    if title and contains_any(title.text, BAD_CREDENTIALS) then
      return "bad"
    end
    waited = waited + 1000
  until waited >= timeout_ms
  return nil
end

-- login.orange.fr answers a fresh session with its visual anti-robot check ("Contrôle
-- anti-robots visuel": pick the images of a category) before the login form. The script never
-- touches it: it gives a human `CAPTCHA_TIMEOUT_MS` to solve it in a `--visible` window, then
-- carries on with the login form, or fails with an explicit captcha error.
local CAPTCHA = { "captcha", selector = "div[class*='captcha_responseContainer']" }
local CAPTCHA_TIMEOUT_MS = 120000

local function wait_past_captcha(states, timeout_ms)
  local all = { CAPTCHA }
  for _, state in ipairs(states) do
    all[#all + 1] = state
  end
  local state = wait_state(all, timeout_ms)
  if state ~= "captcha" then
    return state
  end
  fyde.progress.step("Waiting for the " .. BRAND .. " anti-robot check to be solved in the browser window")
  fyde.log.warn(BRAND .. " shows a visual captcha; it must be solved by hand in the browser window (--visible)")
  state = wait_state(states, CAPTCHA_TIMEOUT_MS)
  if not state then
    error(BRAND .. " asks for a captcha - run with --visible and solve it in the browser window")
  end
  return state
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.browser:open(LOGIN_URL)
  sleep(1500)
  local state = wait_past_captcha({
    { "other", selector = "[data-testid='choose-other-account']" },
    { "login", selector = "#login" },
    { "password", selector = "#password" },
  }, 30000)
  if state == "other" then
    fyde.browser:click("[data-testid='choose-other-account']")
    state = wait_state({ { "login", selector = "#login" } }, 20000)
  end
  if not state then
    error(BRAND .. " login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present("#didomi-notice-disagree-button") then
    fyde.browser:click("#didomi-notice-disagree-button")
  end
  if state == "login" then
    fyde.browser:fill("#login", params.username)
    submit()
    state = wait_step({
      { "password", selector = "#password" },
      { "mobile_connect", selector = "button[data-testid='submit-mc']" },
      { "bad", text = BAD_CREDENTIALS },
      { "captcha", selector = "div[class*='captcha_responseContainer']" },
    }, 30000)
  end
  if state == "bad" then
    fail(INVALID_CREDENTIALS, "login refused")
  elseif state == "captcha" then
    error(BRAND .. " asks for a captcha")
  elseif state == "mobile_connect" then
    fyde.browser:click("button[data-testid='submit-mc']")
    ask_code("Validez la connexion Mobile Connect sur votre téléphone, puis répondez OK")
  elseif state == "password" then
    fyde.browser:fill("#password", params.password)
    if present("#remember") then
      fyde.browser:click("#remember")
    end
    submit()
  else
    error(BRAND .. " login did not show the password step")
  end
  state = wait_step({
    { "keep", selector = "button[data-testid='button-keepconnected']" },
    { "bad", text = BAD_CREDENTIALS },
    { "captcha", selector = "div[class*='captcha_responseContainer']" },
    { "done", text = { "Espace client", "Mon compte" } },
  }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS, "password refused")
  elseif state == "captcha" then
    error(BRAND .. " asks for a captcha")
  elseif state == "keep" then
    fyde.browser:click("button[data-testid='button-keepconnected']")
  end
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "#login, #password" } }, 45000) ~= "logged_in" then
    if state == "mobile_connect" then
      fail(MFA_FAILED, "Mobile Connect was not approved")
    end
    if present("#password") then
      fail(INVALID_CREDENTIALS, "still on the password step")
    end
    error(BRAND .. " login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "#login, #password, [data-testid='choose-other-account']" } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  sleep(3000)
  local contracts, seen = {}, {}
  for _, link in ipairs(fyde.html.select(page_html(), "a[href*='/facture-paiement/']")) do
    local cid = (link.attrs.href or ""):match("/facture%-paiement/([%w%-]+)")
    if cid and not seen[cid] then
      seen[cid] = true
      contracts[#contracts + 1] = cid
    end
  end
  for _, cid in ipairs(contracts) do
    open_and_wait(CLIENT .. "/facture-paiement/" .. cid .. "/historique-des-factures", { { "bills", selector = "a[href*='pdf'], button[data-e2e*='download']" } }, 30000)
    for _ = 1, 10 do
      if not present("button[data-e2e='bh-more-bills'], #plus-de-factures") then
        break
      end
      click_first({ "button[data-e2e='bh-more-bills']", "#plus-de-factures" })
      sleep(2000)
    end
    for i, link in ipairs(fyde.html.select(page_html(), "a[href*='pdf']")) do
      local label = trim(link.text) ~= "" and trim(link.text) or tostring(i)
      browser_save("a[href='" .. link.attrs.href .. "']", cid .. "_" .. sanitize(label) .. "_" .. BRAND:lower() .. ".pdf", {
        name = "Facture " .. BRAND .. " " .. label,
        type = "invoice",
        category = "telecom",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
