-- Scraper for Mercer Ma Santé (mercermasante.fr), Mercer's health-insurance member space:
-- downloads the attestation de couverture, the carte de tiers payant, and one décompte
-- (reimbursement statement) per claim listed under "Remboursements".
--
-- **Why this drives `fyde.browser` for login.** `/connexion` is a client-rendered Next.js page:
-- the plain HTML `fyde.http.get` receives is an empty `<div id="__next">` shell, and the login
-- form only exists once its JS runs. The form is also gated by a Cloudflare Turnstile widget
-- (its sitekey is in `__NEXT_DATA__.props.pageProps.TURNSTILE_KEY`).
--
-- **Confirmed via live runs of this script (no HAR was available):**
--   1. Login fields are `#username` / `#password` (react-hook-form, hence the sdk's `fill`
--      going through the native value setter so React sees the values), submitted via
--      `#login-form button[type=submit]`.
--   2. Turnstile passes on its own in the headless webview - provided its iframe can load,
--      hence `challenges.cloudflare.com` in manifest.json's `allowed_domains` (and the sdk
--      letting `about:blank`/`about:srcdoc` frames through). `wait_for_turnstile` just waits
--      for its token before submitting.
--   3. Valid credentials lead to a 2FA screen ("Vérifions votre identité") offering an SMS code
--      via `button[data-testid=MiniCTA]`, then 8 one-digit `pin-input-<id>-N` boxes and an
--      "Envoyer" submit button - `submit_otp` asks for the code through `ask_code`. A rejected
--      username/password shows "Identifiant ou mot de passe incorrect" on the login form (seen
--      via tests/login_smoke.sh), failing the run with `INVALID_CREDENTIALS`; a wrong SMS code
--      leaves the boxes on screen and fails it with `MFA_FAILED`.
--   4. The session lives in an `auth-token` cookie (plus a `device-uuid` one), which the sdk
--      carries across runs for `fyde.browser` as well as `fyde.http` (see ../sdk's
--      `scrapers/browser/mod.rs`) - so `run` first opens the dashboard (`/journal`) and skips
--      the whole login (Turnstile, credentials, SMS) if it renders.
--   5. Every document page (`/document/<source>`) is client-rendered, with a plain
--      `<a download href="/api/proxy/selfcare/...">` "Télécharger" link - see
--      `DOCUMENTS`/`refund_url`. Those endpoints answer 401 to `fyde.http` right after a fresh
--      login: the sdk only copies the webview's cookies into the cookie jar once the run ends,
--      so `fyde.http` doesn't have `auth-token` yet. Hence every PDF is fetched by opening its
--      document page and clicking that link with `fyde.browser:download` instead.
--
-- **Not confirmed:** whether `/remboursements` ever paginates or hides older claims (the test
-- account's 7 claims, Nov 2024 - Oct 2026, all rendered with no "load more" control).
--
-- Deliberately not fetched: the three generic "Mon guide / Fiche" PDFs under
-- `/compte/documents` (`/document/internalDocument?id=...`) - the same 2022 brochures for every
-- member, not personal documents.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.progress, fyde.html, fyde.json, fyde.input, fyde.browser, fyde.http,
-- fyde.save_document.

local M = {}

local BASE = "https://mercermasante.fr"
local LOGIN_URL = BASE .. "/connexion"
-- The dashboard: redirects to the login page when there's no valid session.
local HOME_URL = BASE .. "/journal"
local REFUNDS_URL = BASE .. "/remboursements"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local ask_code = helpers.ask_code
local page_html = helpers.page_html
local present = helpers.present
local page_text = helpers.page_text
local wait_state = helpers.wait_state
local open_and_wait = helpers.open_and_wait
local browser_save = helpers.browser_save

local USERNAME_FIELD = "#username"
local PASSWORD_FIELD = "#password"
local SUBMIT_CONTROL = "#login-form button[type=submit]"

-- Main-nav link only rendered for an authenticated session (seen on /journal after login).
local LOGGED_IN = { "logged_in", selector = "a[href='/remboursements']" }
local LOGIN_FORM = { "login", selector = USERNAME_FIELD }
-- Shown on the login form itself, under its title, after a rejected username/password.
local BAD_CREDENTIALS = { "bad_credentials", text = { "Identifiant ou mot de passe incorrect" } }
-- 2FA ("Vérifions votre identité", matched sans accents): shown right after credentials are
-- accepted.
local OTP_PAGE = { "otp", text = { "rifions votre identit" } }

-- Turnstile writes its token into this hidden input; a hidden input's `.value` reflects to its
-- `value` attribute, so a non-empty attribute means the challenge is solved.
local TURNSTILE_TOKEN = "input[name='cf-turnstile-response'][value]:not([value=''])"

local SMS_CHANNEL_BUTTON = "button[data-testid=MiniCTA]"
-- One box per digit (Chakra PinInput), each with its own generated `pin-input-<id>-N` id.
local OTP_BOXES = "input[id^='pin-input-']"
local OTP_SUBMIT = "main button[type=submit]"

-- One per claim on /remboursements, `href="/document/refunds?id=<claim id>"`.
local REFUND_LINK = "a[data-testid=refund-download-button]"

-- A claim card's "28,28 € Remboursé le 1 oct. 2026". Amounts only allow (narrow) no-break
-- spaces as thousands separators, never a plain space, so the month header right before the
-- first card ("Octobre 2026 28,28 €") can't bleed its year into the amount.
local NBSP = "\194\160"
local NNBSP = "\226\128\175"
local CLAIM_LABEL = "(%d[%d\194\160\226\128\175]*,%d%d)[%s\194\160]*\226\130\172[%s\194\160]*"
  .. "Rembours\195\169[%s\194\160]+le[%s\194\160]+(%d[^\n]-%d%d%d%d)"

-- Each document's page, and the `href` of that page's own "Télécharger" link.
local DOCUMENTS = {
  {
    page = BASE .. "/document/healthCertificate",
    href = "/api/proxy/selfcare/documents/certificate/health",
    filename = "mon-attestation-de-couverture.pdf",
    fields = {
      name = "Attestation de couverture Mercer",
      type = "insurance_certificate",
    },
  },
  {
    page = BASE .. "/document/tpCard",
    href = "/api/proxy/selfcare/health/tp-card/file",
    filename = "CarteTiersPayant.pdf",
    fields = {
      name = "Carte de tiers payant Mercer",
      type = "insurance_card",
    },
  },
}

local function refund_page(id)
  return BASE .. "/document/refunds?id=" .. id
end

local function refund_href(id)
  return "/api/proxy/selfcare/health/refunds/" .. id .. "/receipt/file"
end

local TIMEOUT_MS = 30000
local TURNSTILE_TIMEOUT_MS = 60000

local function wait_for_turnstile()
  fyde.progress.step("Waiting for the Cloudflare check")
  local ok = pcall(function()
    fyde.browser:wait_for(TURNSTILE_TOKEN, TURNSTILE_TIMEOUT_MS)
  end)
  if not ok then
    error("the Cloudflare Turnstile check never issued a token")
  end
end

local function submit_otp()
  fyde.progress.step("Requesting an SMS verification code")
  fyde.browser:click(SMS_CHANNEL_BUTTON)
  if wait_state({ { "boxes", selector = OTP_BOXES } }, TIMEOUT_MS) ~= "boxes" then
    error("the SMS code form never showed up - page says: " .. page_text())
  end

  local code = ask_code("Code de vérification reçu par SMS")
  local boxes = fyde.html.select(page_html(), OTP_BOXES)
  if #code ~= #boxes then
    fail(MFA_FAILED, string.format("expected a %d-digit code, got %d characters", #boxes, #code))
  end
  for i, box in ipairs(boxes) do
    fyde.browser:fill("#" .. box.attrs.id, code:sub(i, i))
  end
  if present(OTP_SUBMIT) then
    fyde.browser:click(OTP_SUBMIT)
  end

  -- A rejected code leaves the boxes on screen under a "code sent" notice - the page's text
  -- changes either way, so only reaching the dashboard means the code was accepted.
  if wait_state({ LOGGED_IN }, TIMEOUT_MS) ~= "logged_in" then
    fail(MFA_FAILED, "code rejected - page says: " .. page_text())
  end
end

local function login(params)
  if not present(USERNAME_FIELD) and open_and_wait(LOGIN_URL, { LOGIN_FORM }, TIMEOUT_MS) ~= "login" then
    error("Mercer login form not found - page says: " .. page_text())
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  wait_for_turnstile()

  fyde.progress.step("Logging in as " .. params.username)
  fyde.browser:fill(USERNAME_FIELD, params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)

  local state = wait_state({ BAD_CREDENTIALS, OTP_PAGE, LOGGED_IN }, TIMEOUT_MS)
  if state == "bad_credentials" then
    fail(INVALID_CREDENTIALS)
  elseif state == "otp" then
    submit_otp()
  elseif state ~= "logged_in" then
    error("Mercer login did not complete - page says: " .. page_text())
  end
  fyde.log.info("login succeeded")
end

--- Every claim on /remboursements, in page order: `{ id, label }`. `label` comes from the
--- claim card's own "<amount> € Remboursé le <date>" text, matched up with the download links
--- by position - if the two counts ever disagree, labels are dropped rather than risk pairing
--- a statement with the wrong claim's amount/date.
local function list_refunds()
  if open_and_wait(REFUNDS_URL, { { "refunds", selector = REFUND_LINK } }, TIMEOUT_MS) ~= "refunds" then
    error("no claim found on " .. REFUNDS_URL .. " - page says: " .. page_text())
  end
  local html = page_html()

  local refunds = {}
  for _, link in ipairs(fyde.html.select(html, REFUND_LINK)) do
    local id = (link.attrs.href or ""):match("id=(%d+)")
    if id then
      table.insert(refunds, { id = id })
    end
  end

  local main = fyde.html.select(html, "main")[1]
  local labels = {}
  for amount, date in (main and main.text or ""):gmatch(CLAIM_LABEL) do
    amount = amount:gsub(NBSP, ""):gsub(NNBSP, "")
    date = date:gsub(NBSP, " ")
    table.insert(labels, amount .. " € remboursé le " .. date)
  end
  if #labels == #refunds then
    for i, refund in ipairs(refunds) do
      refund.label = labels[i]
    end
  else
    fyde.log.warn(string.format("found %d claim(s) but %d label(s), naming by id only", #refunds, #labels))
  end
  return refunds
end

--- Opens `page` and clicks its "Télécharger" link (the one pointing at `href`) in the webview,
--- which holds the session cookie - see the header comment's point 5 for why not `fyde.http`.
local function save(page, href, filename, fields)
  local link = "a[download][href='" .. href .. "']"
  if open_and_wait(page, { { "link", selector = link } }, TIMEOUT_MS) ~= "link" then
    fyde.log.warn("could not download " .. filename .. ": no download link on " .. page)
    return false
  end
  fields.category = "health"
  fields.subcategory = "complementary_health"
  return browser_save(link, filename, fields)
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, LOGIN_FORM }, TIMEOUT_MS) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading the attestation and the tiers payant card")
  for _, doc in ipairs(DOCUMENTS) do
    save(doc.page, doc.href, doc.filename, doc.fields)
  end

  fyde.progress.step("Listing reimbursements")
  local refunds = list_refunds()
  fyde.log.info(#refunds .. " reimbursement statement(s) found")

  fyde.progress.step("Downloading reimbursement statements")
  for i, refund in ipairs(refunds) do
    fyde.progress.update(i, #refunds, refund.label or refund.id)
    save(refund_page(refund.id), refund_href(refund.id), "mon-decompte-" .. refund.id .. ".pdf", {
      name = "Décompte Mercer - " .. (refund.label or ("remboursement " .. refund.id)),
      type = "reimbursement_statement",
    })
  end

  fyde.progress.step("Done")
end

return M
