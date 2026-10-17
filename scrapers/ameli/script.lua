-- Scraper for the "compte ameli" personal space (assure.ameli.fr, Assurance Maladie/CPAM).
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.progress, fyde.input, fyde.browser.
--
-- **Why this drives a real browser instead of `fyde.http`.** An earlier version of this script
-- drove the whole login flow (including the credentials POST) through `fyde.http`'s plain HTTP
-- client, replaying the login form's own fields by hand. That got all the way to submitting
-- correct credentials and was confirmed, byte-for-byte against a real captured HAR, to diverge
-- only starting at that POST's *response*: the real browser gets the next step's form back
-- directly (status 200); this host always got bounced back to the start (status 302), even with
-- headers, cookies and fields matching exactly. Reading the login page's own scripts end to end
-- turned up the likely cause: `/skins/cnamts/js/utils.js` hooks `HTMLFormElement.prototype.submit`,
-- `fetch`, and `Function.prototype.bind`, and the real captured POST carried six extra opaque
-- blob fields (randomized-prefix names, present in no fetched HTML) that this utils.js is the
-- only plausible source of. That's a bot-mitigation/fingerprinting script that has to actually
-- execute against a real DOM to produce whatever proves the submission is "real" - a plain HTTP
-- client structurally cannot satisfy it, no matter how exactly the request is replayed by hand.
--
-- `fyde.browser` (a real embedded webview - see `../sdk/src/domains/scrapers/browser/driver.rs`)
-- exists specifically for this: `utils.js` actually runs, so whatever it computes for a real
-- click is just... computed, the normal way. The one thing this rewrite is careful about is
-- *how* the credentials form gets submitted: `fyde.browser:submit` deliberately bypasses the
-- page's own submit handling (it POSTs the form's fields via an in-page `fetch()` instead of a
-- real click), which would skip `utils.js`'s hook entirely - the same gap this rewrite exists to
-- close. So every submission below is a real `fyde.browser:click` on the actual button/control
-- the user would press, never `fyde.browser:submit`.
--
-- **Login flow - the credentials step below is now confirmed end to end against the live site
-- with a real account** (not just reverse-engineered from a captured HAR, like the previous
-- revision of this file - see git history for that byte-level investigation): a real run
-- submitted real credentials via `fyde.browser` and landed on the real `OTP_NECESSAIRE` step,
-- which is exactly the outcome the old `fyde.http`-based version could never reach.
--   1. `LOGIN_URL` 302-redirects (handled transparently by a real browser, unlike a manual
--      `fyde.http` redirect chain) through ameliconnect.ameli.fr's OAuth2 `/oauth2/authorize`
--      endpoint and lands on a server-rendered login form, `#lformLogin`, with ordinary (not
--      hidden) `user`/`password` inputs.
--   2. Submitting valid credentials (clicking the form's real submit control) can land on one of:
--      a logged-in page directly (`a.deconnexionButton` present - a trusted device, or an
--      account with 2FA disabled); the same `#lformLogin`, now showing a "Cliquer pour recevoir
--      un code de sécurité" control (`#BoutonGenerationOTP`, name `envoiOTP` - the confirmed
--      path for the real test account) that needs clicking to have the code emailed; or, if some
--      accounts skip the request step entirely, the six-digit entry fields
--      (`#numOTP1`..`#numOTP6`) directly. This step was observed taking anywhere from ~20s to
--      noticeably longer, varying between otherwise-identical runs - see
--      `POST_SUBMIT_TIMEOUT_MS` below.
--   3. Clicking `#BoutonGenerationOTP` emails the code and re-renders the same form with
--      `#numOTP1`..`#numOTP6` present. `run` below asks for the code via `fyde.input.ask`
--      (blocks on real stdin - a human reads the email and types it in), fills the six fields,
--      and clicks the submit control again. Confirmed end to end (2026-10-09): a real code lands
--      on the logged-in page, and the next run reuses that session without logging in again.
--   4. Success is confirmed the same way regardless of path: the logged-out login form/portal
--      never renders a "Se déconnecter" link, so `a.deconnexionButton`'s presence is this
--      script's one source of truth that a run didn't silently fail (wrong credentials, a
--      rejected code, or a step this script doesn't yet handle).
--
-- **Credentials fields and submit control**, confirmed against the real `#lformLogin`
-- (via `fyde.browser:html()`, used only while developing this script - see its own doc comment):
-- `#userfield`/`#passwordfield` (ids, `name="user"`/`name="password"`), and the submit control
-- itself, `#id_r_cnx_btn_submit` (`name="submit" type="submit"`, inside `#lformLogin` - not to
-- be confused with `#lformFranceConnect`'s own unrelated `image`-type submit, a sibling form on
-- the same page for the "FranceConnect" login alternative this script doesn't support). That
-- button renders `disabled="disabled"` until `connexion.js`'s own field-validation JS enables
-- it - `fyde.browser:fill` dispatches real `input`/`change` events (see its doc comment), which
-- is what that validation actually listens for, so clicking it after filling both fields works
-- the same way a real keystroke would (confirmed, not just expected).
--
-- **Documents** (confirmed 2026-10-09 against a real account), all downloaded by clicking in
-- the webview with `fyde.browser:download` - `fyde.http` doesn't hold the webview's session
-- cookies until the run ends, and the session rarely outlives a run:
--   - one "attestation de droits" per beneficiary of the account (`ATTESTATION_URL`);
--   - every "relevé mensuel" the site keeps (up to 27 months, `MONTHLY_URL`);
--   - every payment statement ("décompte") of the last 6 months (`PAYMENTS_URL`).
-- See the constants above each `fetch_*` function for how each page is laid out.

local M = {}

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local LOGIN_URL =
"https://assure.ameli.fr/PortailAS/appmanager/PortailAS/assure?_nfpb=true&_pageLabel=as_login_page&connexioncompte_2actionEvt=afficher"

local USER_FIELD = "#userfield"
local PASSWORD_FIELD = "#passwordfield"
local SUBMIT_CONTROL = "#id_r_cnx_btn_submit"
local OTP_REQUEST_BUTTON = "#BoutonGenerationOTP"
local OTP_FIRST_DIGIT = "#numOTP1"
local LOGGED_IN_MARKER = "a.deconnexionButton"

local FORM_LOAD_TIMEOUT_MS = 20000
-- The credentials POST was observed (confirming real, accepted credentials land on the
-- OTP_NECESSAIRE step) taking anywhere from ~20s to noticeably longer, end to end, before the
-- next form actually renders - and varying between otherwise-identical runs, not a fixed delay.
-- Likely extra server-side verification work behind whatever bot-mitigation is in play (see the
-- header comment), possibly itself reacting to repeated attempts. 45s leaves real margin instead
-- of racing that.
local POST_SUBMIT_TIMEOUT_MS = 45000
local PROBE_TIMEOUT_MS = 1000

-- Polls `selector` with a short timeout and reports whether it matched, instead of erroring out -
-- used to tell apart the several states a real submit click can land on (see the header
-- comment), none of which this script can otherwise distinguish (there's no way to read the
-- page's full markup back out of `fyde.browser`, only to ask it whether a given selector is
-- there).
local function browser_has(selector)
  local ok = pcall(function()
    fyde.browser:wait_for(selector, PROBE_TIMEOUT_MS)
  end)
  return ok
end

-- Waits up to `timeout_ms` for `selector`, as a series of short `wait_for` calls rather than one
-- long one. A click that submits a form navigates the webview, and a `wait_for` issued right
-- after it can land in the page being unloaded: its polling JS dies with that page and never
-- replies, so a single long call just sits out its whole timeout ("timed out ... waiting for the
-- browser") even though the next page rendered the expected selector long before. Re-issuing a
-- short call each time puts a fresh poller into whichever page is current.
local WAIT_STEP_MS = 2000
local function wait_across_navigation(selector, timeout_ms)
  for _ = 1, math.ceil(timeout_ms / WAIT_STEP_MS) do
    if pcall(function()
      fyde.browser:wait_for(selector, WAIT_STEP_MS)
    end) then
      return true
    end
  end
  return false
end

-- Fills the six single-digit OTP fields (`#numOTP1`..`#numOTP6`) from `code`, a 6-digit string.
local function fill_otp_digits(code)
  for i = 1, 6 do
    fyde.browser:fill("#numOTP" .. i, code:sub(i, i))
  end
end

-- Asks the user for the OTP just emailed to them, fills the six digit fields, and clicks the
-- submit control a second time.
local function submit_otp()
  local asked, answer = pcall(fyde.input.ask, "Ameli sent a one-time passcode (OTP) - enter it:")
  local otp = asked and tostring(answer):gsub("%D", "") or ""
  if #otp ~= 6 then
    fyde.log.warn("expected a 6-digit OTP, got " .. #otp .. " digit(s)")
    error("MFA_FAILED", 0)
  end

  fill_otp_digits(otp)
  fyde.browser:click(SUBMIT_CONTROL)
  if not wait_across_navigation(LOGGED_IN_MARKER, POST_SUBMIT_TIMEOUT_MS) then
    fyde.log.warn("the one-time passcode was not accepted")
    error("MFA_FAILED", 0)
  end
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")

  fyde.progress.step("Submitting credentials")
  fyde.browser:fill(USER_FIELD, params.identifiant)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)

  -- A real click lands on one of three states (see header comment) - wait for any of them with
  -- one grouped selector (document.querySelector accepts a comma-separated selector list), then
  -- probe each individually to tell them apart.
  local ok = wait_across_navigation(
    LOGGED_IN_MARKER .. ", " .. OTP_REQUEST_BUTTON .. ", " .. OTP_FIRST_DIGIT,
    POST_SUBMIT_TIMEOUT_MS
  )
  if not ok then
    -- None of the three known states showed up - dump whatever actually rendered instead of
    -- just erroring blind, so a future run tells us which 4th state this script doesn't handle
    -- yet (error page, captcha, a slower-than-expected render, ...) instead of just "timed out".
    local html_ok, html = pcall(function()
      return fyde.browser:html()
    end)
    if html_ok then
      fyde.log.info("post-submit timeout - page length: " .. #html)
      local body = fyde.html.select(html, "body")[1]
      fyde.log.info("post-submit timeout - page text: " .. ((body and body.text or ""):gsub("%s+", " ")):sub(1, 300):gsub("[\128-\255]+$", ""))
      fyde.log.info("post-submit timeout - still has SUBMIT_CONTROL: " .. tostring(html:find(SUBMIT_CONTROL:sub(2), 1, true) ~= nil))
      for _, marker in ipairs({ "BoutonGenerationOTP", "numOTP1", "deconnexionButton", "userfield" }) do
        fyde.log.info("post-submit timeout - has " .. marker .. ": " .. tostring(html:find(marker, 1, true) ~= nil))
      end
      local err_zone_start = html:find("zone%-erreur")
      if err_zone_start then
        fyde.log.info("post-submit timeout - around first zone-erreur: " .. html:sub(err_zone_start, err_zone_start + 1500))
      end
      local token_start = html:find('name="token"')
      if token_start then
        fyde.log.info("post-submit timeout - around token field: " .. html:sub(token_start, token_start + 150))
      end
    else
      fyde.log.info("post-submit timeout - fetching page markup for diagnosis also failed: " .. tostring(html))
    end
    if browser_has(USER_FIELD) then
      fyde.log.warn("still on the login form after submitting: credentials rejected")
      error("INVALID_CREDENTIALS", 0)
    end
    -- The site's WAF answers too many logins in a short time (observed after ~8 in 20 minutes)
    -- with a bare "The requested URL was rejected" page, for a while.
    if html_ok and html:find("requested URL was rejected", 1, true) then
      error("the site's firewall rejected the login (too many recent attempts?) - retry later", 0)
    end
    error("timed out waiting for the page after submitting credentials", 0)
  end

  if browser_has(LOGGED_IN_MARKER) then
    fyde.log.info("logged in without a one-time passcode step")
  elseif browser_has(OTP_REQUEST_BUTTON) then
    fyde.progress.step("Requesting a security code")
    fyde.browser:click(OTP_REQUEST_BUTTON)
    if not wait_across_navigation(OTP_FIRST_DIGIT, POST_SUBMIT_TIMEOUT_MS) then
      error("the one-time passcode form never showed up after requesting a code", 0)
    end

    fyde.progress.step("Waiting for the one-time passcode")
    submit_otp()
  elseif browser_has(OTP_FIRST_DIGIT) then
    fyde.progress.step("Waiting for the one-time passcode")
    submit_otp()
  elseif browser_has(USER_FIELD) then
    fyde.log.warn("still on the login form after submitting: credentials rejected")
    error("INVALID_CREDENTIALS", 0)
  else
    error(
      "login did not land on a recognized state after submitting credentials - the site "
        .. "changed in a way this script doesn't handle yet"
    )
  end

  if not browser_has(LOGGED_IN_MARKER) then
    error(
      "login did not succeed - found no 'Se déconnecter' link, so the session does not "
        .. "appear authenticated"
    )
  end
  fyde.log.info("authenticated")
end

local PORTAL = "https://assure.ameli.fr/PortailAS/appmanager/PortailAS/assure?_nfpb=true&_pageLabel="
local PAGE_TIMEOUT_MS = 30000

-- "Mes paiements" (last 6 months, every beneficiary): one link per payment, e.g.
-- `/PortailAS/PDFServletDetailPaiementPT.dopdf?idPaiement=...` (`PT` for a payment to a third
-- party, `RS` for a reimbursement of care; `idPaiement` is an opaque, per-session token). Payments
-- are grouped under a month heading ("septembre 2026"), each row starting with its day and
-- abbreviated month ("29 sept.") and a label ("Paiement à un tiers").
local PAYMENTS_URL = PORTAL .. "as_paiements_page"
local PAYMENT_LINK = "a[href*='PDFServletDetailPaiement']"

-- "Attestation de droits" (Vue/Vuetify app): a combobox listing every beneficiary of the account
-- (`[role=option]` items in a menu that only exists while open), and a download button that
-- stays disabled until at least one is selected. One attestation is saved per beneficiary.
local ATTESTATION_URL = "https://assure.ameli.fr/compte/asdo/attestation-droits"
local ATTESTATION_COMBO = "input[role=combobox][aria-label^='Attestation pour']"
local ATTESTATION_OPTION = "[role=option]"
local ATTESTATION_DOWNLOAD = "button[data-cy=btnTelecharger]"

-- "Relevés mensuels" (Vue/Vuetify app): one row per month ("SEPTEMBRE 2026"), with a "Télécharger
-- le PDF" button when there was a payment that month and "Aucun paiement" otherwise. Only the
-- latest months render until "Afficher plus de relevés" is clicked (up to 27 months in all). Every
-- row's button is identical, so the k-th one is reached through its row - see `nth_in_rows`.
local MONTHLY_URL = "https://assure.ameli.fr/compte/aspm/releves-mensuels"
local MONTHLY_DOWNLOAD = "button[data-testid='download-btn']"
local MONTHLY_MORE = "button[data-cy=afficherPlusBtn]"

local MONTHS = {
  janv = 1, janvier = 1, ["f\195\169vr"] = 2, ["f\195\169vrier"] = 2, mars = 3, avr = 4, avril = 4,
  mai = 5, juin = 6, juil = 7, juillet = 7, ["ao\195\187t"] = 8, sept = 9, septembre = 9,
  oct = 10, octobre = 10, nov = 11, novembre = 11, ["d\195\169c"] = 12, ["d\195\169cembre"] = 12,
}

-- Month number for a French month name or abbreviation, in any case (accented capitals included).
local function month_number(word)
  local lower = word:lower():gsub("\195\137", "\195\169"):gsub("\195\155", "\195\187")
  return MONTHS[lower]
end

local sleep = fyde.helpers.sleep

-- At most `n` bytes of `s`, never cutting a UTF-8 character in half (the host rejects invalid
-- UTF-8 in a log line).
local function clip(s, n)
  if #s <= n then
    return s
  end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) >= 128 and (s:byte(cut + 1) or 0) < 192 do
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- The page's markup with scripts, styles and tags stripped - plain text, whitespace collapsed.
local function visible_text(html)
  local text = html:gsub("<script.-</script>", " ")
  text = text:gsub("<style.-</style>", " ")
  text = text:gsub("<[^>]*>", " ")
  text = text:gsub("<[^>]*$", " ")
  text = text:gsub("&nbsp;", " ")
  text = text:gsub("\194\160", " ")
  text = text:gsub("&#39;", "'")
  text = text:gsub("%s+", " ")
  return text
end

local function trim(s)
  return ((s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function sanitize(filename)
  return (filename:gsub("[^%w%._-]", "_"))
end

local function classified(fields)
  fields.category = "health"
  fields.subcategory = "health_insurance"
  return fields
end

-- Clicks `selector` and saves what the webview downloads as `filename`; returns the bytes saved,
-- or nil (with a warning) when no PDF came back.
local function download_pdf(selector, filename, fields)
  local ok, bytes = pcall(function()
    return fyde.browser:download(selector, 60000)
  end)
  if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
    fyde.save_document(sanitize(filename), bytes, classified(fields))
    return bytes
  end
  fyde.log.warn("could not download " .. filename .. ": " .. tostring(ok and "not a PDF" or bytes))
  return nil
end

-- Logs every form control on the page with its attributes - used when a page doesn't look the
-- way this script expects, so the report shows what it looks like instead.
local function log_controls(label, html)
  fyde.log.info(label .. " text: " .. clip(visible_text(html), 2000))
  for _, tag in ipairs({ "select", "button", "input", "[role=option]", "[role=listbox]" }) do
    for _, el in ipairs(fyde.html.select(html, tag)) do
      local attrs = {}
      for k, v in pairs(el.attrs or {}) do
        if k ~= "style" then
          table.insert(attrs, k .. "=" .. clip(tostring(v), 80))
        end
      end
      table.sort(attrs)
      fyde.log.info(label .. " " .. tag .. ": " .. table.concat(attrs, " ") .. " | " .. clip(trim(el.text), 80))
    end
  end
end

local function fetch_payments()
  fyde.progress.step("Listing payments")
  fyde.browser:open(PAYMENTS_URL)
  sleep(1500)
  if not wait_across_navigation(PAYMENT_LINK .. ", #paiements_1paiementForm", PAGE_TIMEOUT_MS) then
    log_controls("payments page", fyde.browser:html())
    error("the payments page never showed up", 0)
  end
  local html = fyde.browser:html()
  local links = fyde.html.select(html, PAYMENT_LINK)
  fyde.log.info(#links .. " payment statement(s) found")

  fyde.progress.step("Downloading payment statements")
  local per_date, saved, search_from = {}, 0, 1
  for n, link in ipairs(links) do
    local href = link.attrs.href
    local kind = (href:match("PDFServletDetailPaiement(%u+)%.dopdf") or "xx"):lower()
    local at = html:find(href, search_from, true) or search_from
    search_from = at + 1
    -- Everything up to the link: a month's heading can sit far above its later rows.
    local before = visible_text(html:sub(1, at))

    -- The row's own "29 sept." (and the label after it), under the last "septembre 2026" heading.
    local year, day, month, label
    for word, yyyy in before:gmatch("([%a\128-\255]+) (%d%d%d%d)") do
      if month_number(word) then
        year = yyyy
      end
    end
    for dd, word, rest in before:gmatch("(%d%d?) ([%a\128-\255]+)%.? ([^%d]*)") do
      if month_number(word) then
        day, month, label = tonumber(dd), month_number(word), trim(rest)
      end
    end

    local date = (year and day) and string.format("%s-%02d-%02d", year, month, day) or "sans-date"
    per_date[date .. kind] = (per_date[date .. kind] or 0) + 1
    local suffix = per_date[date .. kind] > 1 and ("-" .. per_date[date .. kind]) or ""
    local shown = (year and day) and string.format("%02d/%02d/%s", day, month, year) or "date inconnue"
    fyde.progress.update(n, #links, shown)
    if download_pdf("a[href='" .. href .. "']", "ameli-paiement-" .. date .. "-" .. kind .. suffix .. ".pdf", {
      name = "D\195\169compte ameli du " .. shown .. ((label and label ~= "") and (" - " .. label) or ""),
      type = "reimbursement_statement",
    }) then
      saved = saved + 1
    end
  end
  if saved < #links then
    error((#links - saved) .. " payment statement(s) could not be downloaded", 0)
  end
end

-- Opens the beneficiary menu if it isn't already, and returns the page with it open.
local function open_attestation_menu()
  if not browser_has(ATTESTATION_OPTION) then
    fyde.browser:click(ATTESTATION_COMBO)
    if not wait_across_navigation(ATTESTATION_OPTION, 10000) then
      log_controls("attestation menu", fyde.browser:html())
      error("the beneficiary menu of the attestation de droits page never opened", 0)
    end
    sleep(500)
  end
  return fyde.browser:html()
end

local function option_selector(index)
  return ATTESTATION_OPTION .. ":nth-child(" .. index .. " of " .. ATTESTATION_OPTION .. ")"
end

-- Opens the attestation page afresh (a download replaces the form, and a fresh page has nobody
-- selected yet) and returns it with the beneficiary menu open.
local function open_attestation_page()
  fyde.browser:open(ATTESTATION_URL)
  sleep(1500)
  if not wait_across_navigation(ATTESTATION_COMBO, PAGE_TIMEOUT_MS) then
    log_controls("attestation page", fyde.browser:html())
    error("no beneficiary field on the attestation de droits page", 0)
  end
  return open_attestation_menu()
end

local function fetch_attestations()
  fyde.progress.step("Opening the attestation de droits page")
  local options = {}
  for index, option in ipairs(fyde.html.select(open_attestation_page(), ATTESTATION_OPTION)) do
    local name = trim(option.text)
    -- A "select everyone" entry, if any, isn't a beneficiary of its own.
    if name ~= "" and not name:lower():find("tous", 1, true) then
      table.insert(options, { index = index, name = name })
    end
  end
  fyde.log.info(#options .. " beneficiar" .. (#options == 1 and "y" or "ies") .. " in the attestation de droits menu")
  if #options == 0 then
    log_controls("attestation menu", fyde.browser:html())
    error("the attestation de droits menu lists no beneficiary", 0)
  end

  fyde.progress.step("Downloading the attestations de droits")
  local saved = 0
  for n, option in ipairs(options) do
    fyde.progress.update(n, #options, option.name)
    if n > 1 then
      open_attestation_page()
    end
    fyde.browser:click(option_selector(option.index))
    sleep(1000)
    if not wait_across_navigation(ATTESTATION_DOWNLOAD .. ":not([disabled])", 10000) then
      log_controls("attestation " .. n, fyde.browser:html())
      error("the attestation de droits download button stayed disabled", 0)
    end
    if download_pdf(ATTESTATION_DOWNLOAD, "ameli-attestation-droits-" .. option.name .. ".pdf", {
      name = "Attestation de droits ameli - " .. option.name,
      type = "rights_certificate",
    }) then
      saved = saved + 1
    end
  end
  if saved < #options then
    error((#options - saved) .. " attestation(s) de droits could not be downloaded", 0)
  end
end

-- The k-th monthly-statement button, through the k-th row that has one: `rows_depth` is how
-- many levels above the button a row sits (rows being siblings of one another).
local function nth_in_rows(rows_depth, k)
  local down = string.rep("* > ", rows_depth - 1)
  return "*:nth-child(" .. k .. " of :has(> " .. down .. MONTHLY_DOWNLOAD .. ")) > " .. down .. MONTHLY_DOWNLOAD
end

local function fetch_monthly_statements()
  fyde.progress.step("Opening the relev\195\169s mensuels page")
  fyde.browser:open(MONTHLY_URL)
  sleep(1500)
  if not wait_across_navigation(MONTHLY_DOWNLOAD .. ", " .. MONTHLY_MORE, PAGE_TIMEOUT_MS) then
    log_controls("monthly page", fyde.browser:html())
    error("no relev\195\169 mensuel on the relev\195\169s mensuels page", 0)
  end
  sleep(1000)

  -- Load every month the page has before collecting them.
  local html = fyde.browser:html()
  local count = #fyde.html.select(html, MONTHLY_DOWNLOAD)
  for _ = 1, 15 do
    if not browser_has(MONTHLY_MORE .. ":not([disabled])") then
      break
    end
    fyde.browser:click(MONTHLY_MORE)
    sleep(2500)
    html = fyde.browser:html()
    local now = #fyde.html.select(html, MONTHLY_DOWNLOAD)
    if now == count then
      break
    end
    count = now
  end
  fyde.log.info(count .. " relev\195\169(s) mensuel(s) found")

  -- Find how far above its button a row sits: the first level where a 2nd row with a button
  -- exists. With a single statement, the button itself is enough.
  local depth
  if count > 1 then
    for d = 1, 8 do
      if browser_has(nth_in_rows(d, 2)) then
        depth = d
        break
      end
    end
    if not depth then
      log_controls("monthly page", html)
      error("could not tell the relev\195\169s mensuels rows apart", 0)
    end
  end

  fyde.progress.step("Downloading the relev\195\169s mensuels")
  local saved, seen_month, search_from = 0, {}, 1
  for k = 1, count do
    -- The month is the last "SEPTEMBRE 2026" heading before this row's button.
    local at = html:find('data-testid="download-btn"', search_from, true) or search_from
    search_from = at + 1
    local year, month
    for word, yyyy in visible_text(html:sub(math.max(1, at - 3000), at)):gmatch("([%a\128-\255]+) (%d%d%d%d)") do
      if month_number(word) then
        year, month = yyyy, month_number(word)
      end
    end
    local period = year and string.format("%s-%02d", year, month) or ("releve-" .. k)
    if seen_month[period] then
      period = period .. "-" .. k
    end
    seen_month[period] = true
    fyde.progress.update(k, count, period)
    if download_pdf(depth and nth_in_rows(depth, k) or MONTHLY_DOWNLOAD, "ameli-releve-mensuel-" .. period .. ".pdf", {
      name = "Relev\195\169 mensuel ameli - " .. (year and string.format("%02d/%s", month, year) or period),
      type = "reimbursement_statement",
    }) then
      saved = saved + 1
    end
  end
  if saved < count then
    error((count - saved) .. " relev\195\169(s) mensuel(s) could not be downloaded", 0)
  end
end

function M.run(params)
  fyde.progress.step("Visiting the login page")
  -- A real browser follows LOGIN_URL's redirect chain (through ameliconnect.ameli.fr's OAuth2
  -- flow) on its own; unlike the old fyde.http-based version, there's no manual Location-header
  -- chasing to do here.
  fyde.browser:open(LOGIN_URL)
  if not wait_across_navigation(USER_FIELD .. ", " .. LOGGED_IN_MARKER, FORM_LOAD_TIMEOUT_MS) then
    log_controls("login page", fyde.browser:html())
    error("neither the login form nor a logged-in page showed up", 0)
  end
  if browser_has(LOGGED_IN_MARKER) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  -- Each section is tried even when another one fails; the first failure is raised once all ran.
  local failure
  for _, fetch in ipairs({ fetch_attestations, fetch_monthly_statements, fetch_payments }) do
    local ok, err = pcall(fetch)
    if not ok then
      fyde.log.warn(tostring(err))
      failure = failure or err
    end
  end
  if failure then
    error(failure, 0)
  end
end

return M
