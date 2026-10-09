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
--      hence `challenges.cloudflare.com` in settings.json's `allowed_domains` (and the sdk
--      letting `about:blank`/`about:srcdoc` frames through). `wait_for_turnstile` just waits
--      for its token before submitting.
--   3. Valid credentials lead to a 2FA screen ("Vérifions votre identité") offering an SMS code
--      via `button[data-testid=MiniCTA]`, then 8 one-digit `mfa-code-N` boxes and an "Envoyer"
--      submit button - `submit_otp` asks for the code through `fyde.input.ask`.
--   4. The session lives in an `auth-token` cookie (plus a `device-uuid` one), which the sdk
--      carries across runs for `fyde.browser` as well as `fyde.http` (see ../sdk's
--      `scrapers/browser/mod.rs`) - so `run` first opens the dashboard (`/journal`) and skips
--      the whole login (Turnstile, credentials, SMS) if it renders.
--   5. Every document page (`/document/<source>`) is itself client-rendered, but its download
--      button is a plain `<a download href="/api/proxy/selfcare/...">` to an endpoint that
--      returns the PDF to `fyde.http` directly, authenticated by that same cookie - see
--      `DOCUMENTS`/`refund_url`. Only the claim ids need the browser (the list is rendered
--      client-side too).
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
-- fyde.log, fyde.progress, fyde.html, fyde.input, fyde.browser, fyde.http, fyde.save_document.

local M = {}

local BASE = "https://mercermasante.fr"
local LOGIN_URL = BASE .. "/connexion"
-- The dashboard: redirects to the login page when there's no valid session.
local HOME_URL = BASE .. "/journal"
local REFUNDS_URL = BASE .. "/remboursements"

local USERNAME_FIELD = "#username"
local PASSWORD_FIELD = "#password"
local SUBMIT_CONTROL = "#login-form button[type=submit]"
local LOGIN_FORM = "#login-form"
-- Main-nav link only rendered for an authenticated session (seen on /journal after login).
local LOGGED_IN_MARKER = "a[href='/remboursements']"

-- Turnstile writes its token into this hidden input; a hidden input's `.value` reflects to its
-- `value` attribute, so a non-empty attribute means the challenge is solved.
local TURNSTILE_TOKEN = "input[name='cf-turnstile-response'][value]:not([value=''])"

-- 2FA ("Vérifions votre identité"): shown right after credentials are accepted.
local SMS_CHANNEL_BUTTON = "button[data-testid=MiniCTA]"
local OTP_PAGE_MARKER = "rifions votre identit" -- "Vérifions votre identité", sans accents
local OTP_INPUTS = "main input:not([type=hidden]):not([type=checkbox])"
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

-- The download targets of each `/document/<source>` page's own "Télécharger" link.
local DOCUMENTS = {
  {
    url = BASE .. "/api/proxy/selfcare/documents/certificate/health",
    filename = "mon-attestation-de-couverture.pdf",
    fields = {
      name = "Attestation de couverture Mercer",
      type = "health_insurance_certificate",
      purpose = "attestation",
    },
  },
  {
    url = BASE .. "/api/proxy/selfcare/health/tp-card/file",
    filename = "CarteTiersPayant.pdf",
    fields = {
      name = "Carte de tiers payant Mercer",
      type = "health_insurance_card",
      purpose = "attestation",
    },
  },
}

local function refund_url(id)
  return BASE .. "/api/proxy/selfcare/health/refunds/" .. id .. "/receipt/file"
end

local FORM_LOAD_TIMEOUT_MS = 30000
local TURNSTILE_TIMEOUT_MS = 60000
local POST_SUBMIT_TIMEOUT_MS = 30000
local POLL_MS = 1000

-- `wait_for` only waits for a selector to *appear*; there's no way to wait for one to go away,
-- so this sleeps by waiting on a selector that never exists.
local function sleep(ms)
  pcall(function()
    fyde.browser:wait_for("#__mercermasante_sleep__", ms)
  end)
end

local function page_text()
  local root = fyde.html.select(fyde.browser:html(), "#__next")[1]
  return root and root.text or ""
end

-- `fyde.browser:open` doesn't wait for the navigation, so a `wait_for` issued right after it
-- can land in the *previous* page, get torn down with it, and never reply at all (a "timed out
-- waiting for the browser" error rather than a selector timeout). Polling in short chunks
-- means a chunk lost that way just gets retried against the new page.
local function wait_for_after_open(selector, timeout_ms)
  local waited = 0
  while waited < timeout_ms do
    if pcall(function()
      fyde.browser:wait_for(selector, 2000)
    end) then
      return
    end
    waited = waited + 2000
  end
  error("timed out waiting for " .. selector .. " - page says: " .. page_text())
end

local function on_login_form()
  return #fyde.html.select(fyde.browser:html(), LOGIN_FORM) > 0
end

local function is_logged_in()
  return #fyde.html.select(fyde.browser:html(), LOGGED_IN_MARKER) > 0
end

local function on_otp_page()
  return page_text():find(OTP_PAGE_MARKER, 1, true) ~= nil
end

local function wait_while(predicate, timeout_ms)
  local waited = 0
  while predicate() and waited < timeout_ms do
    sleep(POLL_MS)
    waited = waited + POLL_MS
  end
  return not predicate()
end

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
  fyde.browser:wait_for(SMS_CHANNEL_BUTTON, FORM_LOAD_TIMEOUT_MS)
  fyde.browser:click(SMS_CHANNEL_BUTTON)
  fyde.browser:wait_for(OTP_INPUTS, FORM_LOAD_TIMEOUT_MS)

  local code = fyde.input.ask("Code de vérification reçu par SMS"):gsub("%s", "")

  -- One box per digit (Chakra PinInput), each with its own generated id.
  local inputs = fyde.html.select(fyde.browser:html(), OTP_INPUTS)
  if #inputs > 1 then
    for i = 1, math.min(#inputs, #code) do
      fyde.browser:fill("#" .. inputs[i].attrs.id, code:sub(i, i))
    end
  else
    fyde.browser:fill(OTP_INPUTS, code)
  end
  if #fyde.html.select(fyde.browser:html(), OTP_SUBMIT) > 0 then
    fyde.browser:click(OTP_SUBMIT)
  end

  if not wait_while(on_otp_page, POST_SUBMIT_TIMEOUT_MS) then
    error("SMS code rejected or not submitted - page says: " .. page_text())
  end
  fyde.log.info("SMS verification succeeded")
end

local function login(params)
  if not on_login_form() then
    fyde.browser:open(LOGIN_URL)
    wait_for_after_open(USERNAME_FIELD, FORM_LOAD_TIMEOUT_MS)
  end
  wait_for_turnstile()

  fyde.progress.step("Logging in as " .. params.username)
  fyde.browser:fill(USERNAME_FIELD, params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)

  if not wait_while(on_login_form, POST_SUBMIT_TIMEOUT_MS) then
    error("login failed: still on the login form after submitting - page says: " .. page_text())
  end
  fyde.log.info("credentials accepted")

  sleep(2000)
  if on_otp_page() then
    submit_otp()
  end

  if not wait_while(function()
    return not is_logged_in()
  end, POST_SUBMIT_TIMEOUT_MS) then
    error("login looked successful but the dashboard never rendered - page says: " .. page_text())
  end
  fyde.log.info("login succeeded")
end

--- Every claim on /remboursements, in page order: `{ id, label }`. `label` comes from the
--- claim card's own "<amount> € Remboursé le <date>" text, matched up with the download links
--- by position - if the two counts ever disagree, labels are dropped rather than risk pairing
--- a statement with the wrong claim's amount/date.
local function list_refunds()
  fyde.browser:open(REFUNDS_URL)
  wait_for_after_open(REFUND_LINK, FORM_LOAD_TIMEOUT_MS)
  local html = fyde.browser:html()

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

local function save(url, filename, fields)
  local download = fyde.http.download(url)
  local content_type = download.content_type or ""
  if download.status == 200 and content_type:find("pdf", 1, true) then
    fields.source_category = "insurance"
    fields.source_sub_category = "health"
    fyde.save_document(filename, download.body, fields)
    return true
  end
  fyde.log.warn(string.format(
    "failed to download %s (status %d, content-type %s)",
    filename, download.status, content_type
  ))
  return false
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  fyde.browser:open(HOME_URL)
  -- Whichever renders first: the dashboard's nav, or the login form it redirects to.
  wait_for_after_open(LOGGED_IN_MARKER .. ", " .. USERNAME_FIELD, FORM_LOAD_TIMEOUT_MS)
  if is_logged_in() then
    fyde.log.info("restored session is still valid, skipping login")
  else
    login(params)
  end

  fyde.progress.step("Downloading the attestation and the tiers payant card")
  for _, doc in ipairs(DOCUMENTS) do
    save(doc.url, doc.filename, doc.fields)
  end

  fyde.progress.step("Listing reimbursements")
  local refunds = list_refunds()
  fyde.log.info(#refunds .. " reimbursement statement(s) found")

  fyde.progress.step("Downloading reimbursement statements")
  for i, refund in ipairs(refunds) do
    fyde.progress.update(i, #refunds, refund.label or refund.id)
    save(refund_url(refund.id), "mon-decompte-" .. refund.id .. ".pdf", {
      name = "Décompte Mercer - " .. (refund.label or ("remboursement " .. refund.id)),
      type = "reimbursement_statement",
      purpose = "report",
    })
  end

  fyde.progress.step("Done")
end

return M
