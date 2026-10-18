-- Scraper for the particulier space on impots.gouv.fr.
--
-- Unlike Didaxis, this site has no plain login form: impots.gouv.fr/particulier redirects to
-- an OAuth2/OIDC identity provider (cfspart-idp.impots.gouv.fr) running a legacy multi-step
-- "Gotham" login flow. The real steps (reverse-engineered from the live site - there is no
-- public documentation for this):
--   0. GET the particulier homepage (https://cfspart.impots.gouv.fr/) first. It 302s through
--      the idp's /oauth2/authorize and back, which is what actually sets the session/state
--      cookies (plus ShieldSquare bot-management ones) that `/GetContexte` below checks -
--      skip this and GetContexte always answers context "ERR" regardless of the fiscal
--      number. A real browser always does this (it's how the login form gets rendered at
--      all), so it's not optional here either.
--   1. POST the fiscal number alone to `/GetContexte`. The response isn't a normal page; it's
--      a tiny HTML snippet whose only content is a `parent.postMessage('ctx,<CODE>', ...)`
--      call. In a browser, the parent page's JS listens for this and switches the visible form
--      based on <CODE> (e.g. "LMDP" = normal password account, "3S"/"PAS" = account creation,
--      "CODE" = account locked, needs a mailed unlock code, "EXISTEPAS" = unknown number).
--      This script only knows how to continue when <CODE> is "LMDP". (Confusingly, the site's
--      own JS then sets the *separate* `lmAuth` field to the string "LDAP" when submitting the
--      password in step 2 below - that's an unrelated internal auth-backend value, not another
--      spelling of this context code.)
--   2. POST the fiscal number + password (plus the other form fields, emptied) to `/` on the
--      same idp host - found hardcoded as `urlLoginMotDePasse = '/'` in customScript.js, since
--      it's never visible as a real form `action` attribute in the HTML (set dynamically by
--      the same JS that reacts to step 1's postMessage).
--   2b. Some accounts (not all - it's a per-account setting, not universal) have an email
--      security code (OTP/MFA) enabled. When step 2 succeeds, instead of either the login form
--      again or a logged-in page, the response is a form with id="otpform" (action
--      `/restapiotp2fcheck?skin=partDsfr&authType=sso`) asking for a 6-digit code just emailed
--      to the account's address, plus a hidden `token` field tying the code back to this
--      attempt. This script detects that form, asks for the code via `fyde.input.ask` (which
--      blocks on real stdin - a human needs to read the email and type it in), and POSTs it to
--      that endpoint before continuing to step 3.
--   3. Re-visit the normal entrypoint (https://cfspart.impots.gouv.fr/). With a valid idp
--      session cookie now set, the OIDC dance completes silently instead of showing the login
--      form again, landing on the authenticated particulier space.
-- From there, scraping mirrors the heuristics in demo-fyde's impots_scraper.js (its JS
-- equivalent for a WebView-driven crawl): find the "Documents" nav link, visit it once, and
-- collect links that look like documents.
--
-- The login page also runs ShieldSquare/Radware bot-management (aperture.js / perfdrive.com /
-- eupulse.shieldsquare.net) in the browser. `fyde.http` doesn't evaluate that script (it runs
-- no JS), so requests may get flagged or rate-limited in ways a real browser wouldn't be - if login
-- keeps failing with a plausible-looking response, that's the most likely cause, not a bug in
-- the field names below.
--
-- IMPORTANT: repeated failed login attempts against a real fiscal number can lock the account
-- (the site's own recovery flow for that is mailing a physical unlock code - see the "CODE"
-- case above). Don't loop/retry this blindly against real credentials.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.html, fyde.progress, fyde.input, fyde.save_document.

local M = {}

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local PART_BASE = "https://cfspart.impots.gouv.fr"
local IDP_BASE = "https://cfspart-idp.impots.gouv.fr"

-- Never follow anything that looks like a logout, and only treat links that look like real
-- documents as documents - mirrors impots_scraper.js's DOC_HREF/FORBIDDEN regexes exactly.
local FORBIDDEN_PATTERNS = { "logout", "deconnexion", "decoglobale", "/deco" }
local DOC_HREF_PATTERNS = { ".pdf", "affichage_document", "idensua", "telecharg" }

local function matches_any(haystack, patterns)
  local lower = haystack:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function sanitize(name)
  name = name:gsub("%s+", " ")
  name = name:match("^%s*(.-)%s*$")
  name = name:gsub('[<>:"/\\|%?%*]', "_")
  name = name:gsub("%c", "")
  if #name > 150 then
    name = name:sub(1, 150)
  end
  if name == "" then
    name = "document"
  end
  return name
end

--- Resolves a possibly-relative href found on `page_url` into an absolute URL.
local function resolve_url(page_url, href)
  if href:match("^https?://") then
    return href
  end
  if href:sub(1, 1) == "/" then
    local domain = page_url:match("^(https?://[^/]+)")
    return (domain or PART_BASE) .. href
  end
  local dir = page_url:match("(.*/)") or (PART_BASE .. "/")
  return dir .. href
end

--- Extracts the `<CODE>` out of a `/GetContexte` response's
--- `parent.postMessage('ctx,<CODE>', ...)` payload.
local function parse_context_code(body)
  return body:match("postMessage%s*%(%s*['\"]ctx,([%w]+)['\"]")
end

--- Step 1 of the login flow: tells the server which fiscal number we're trying to log in as,
--- and gets back a context code describing what kind of account it is. `referer` is the
--- login page's own URL (see M.run) - a real browser sends it as the Referer on this POST
--- since it's submitting a form from that page, and the idp may check it.
local function get_context(spi, referer)
  local resp = fyde.http.post_form(IDP_BASE .. "/GetContexte", {
    url = "",
    lmAuth = "",
    authType = "",
    spi = spi,
    pwd = "",
    fg = "",
    rfr = "",
    teledec = "",
    dateNaissance = "",
  }, { Referer = referer })
  if resp.status >= 400 then
    error("GetContexte request failed with HTTP status " .. resp.status)
  end
  return parse_context_code(resp.body)
end

--- Step 2: submits the fiscal number + password to the real (hardcoded, see header comment)
--- login endpoint, once GetContexte has confirmed this is a normal password-protected account.
--- Same `referer` as `get_context` - same page, same form.
local function submit_password(spi, password, referer)
  return fyde.http.post_form(IDP_BASE .. "/", {
    url = "",
    lmAuth = "LDAP",
    authType = "",
    spi = spi,
    pwd = password,
    fg = "",
    rfr = "",
    teledec = "",
    dateNaissance = "",
  }, { Referer = referer })
end

--- True once the password step comes back asking for an emailed security code (OTP/MFA)
--- instead of either the login form again or a logged-in page - some accounts (not all) have
--- this enabled. Identified by the id of its real `<form>`, same approach as `is_logged_in`.
local function is_otp_challenge(html)
  return html:find('id="otpform"', 1, true) ~= nil
end

--- Pulls the per-session `token` hidden field out of the OTP form - it ties the code the user
--- enters back to this specific login attempt, and must be echoed back in step 3.
local function parse_otp_token(html)
  return html:match('name="token"%s+value="([^"]+)"')
end

--- Step 3 (only when `is_otp_challenge` is true): submits the user-entered emailed code to the
--- real (found in the OTP form's `action`) verification endpoint, alongside the token from
--- step 2's response and the form's other fields (always the same defaults - `stayconnected`
--- aside, which just avoids a second code on a future run from the same session).
local function submit_otp(token, code, referer)
  return fyde.http.post_form(IDP_BASE .. "/restapiotp2fcheck?skin=partDsfr&authType=sso", {
    token = token,
    checkLogins = "",
    stayconnected = "1",
    reselect = "",
    escape = "",
    skin = "partDsfr",
    code = code,
  }, { Referer = referer })
end

--- True once we're past the login form - i.e. the page no longer contains the Gotham login
--- form's marker id.
local function is_logged_in(html)
  return not html:find('id="formulairePrincipal"', 1, true)
end

local function find_documents_link(html, page_url)
  local anchors = fyde.html.select(html, "a")
  for _, anchor in ipairs(anchors) do
    local text = anchor.text:match("^%s*(.-)%s*$")
    if text:lower() == "documents" and anchor.attrs.href then
      return resolve_url(page_url, anchor.attrs.href)
    end
  end
  return nil
end

local function extract_documents(html)
  local docs = {}
  local seen = {}
  local anchors = fyde.html.select(html, "a[href]")
  for _, anchor in ipairs(anchors) do
    local href = anchor.attrs.href or ""
    if href ~= "" and not matches_any(href, FORBIDDEN_PATTERNS) and matches_any(href, DOC_HREF_PATTERNS) then
      if not seen[href] then
        seen[href] = true
        local text = anchor.text:match("^%s*(.-)%s*$")
        if text == "" then
          text = "document"
        end
        table.insert(docs, { text = text, href = href })
      end
    end
  end
  return docs
end

function M.run(params)
  local spi = params["fiscal-number"]
  local password = params.password

  -- Step 0 (see header comment): picks up the session/bot-management cookies GetContexte
  -- needs - without this it always answers context "ERR". `login_page_url` is where this
  -- lands after following the oauth2 redirect - the same URL a real browser would send back
  -- as Referer on the GetContexte/login POSTs below, since it's submitting the form found on
  -- that page. fyde.http's cookie jar is restored from the previous run's saved cookies
  -- before this script even starts, so a still-valid idp session cookie from a previous run can
  -- also mean this GET already lands us on the authenticated homepage, completing the OIDC
  -- dance silently and skipping the rest of the login flow below entirely.
  fyde.progress.step("checking_session")
  local home = fyde.http.get(PART_BASE .. "/")
  local login_page_url = home.url

  if is_logged_in(home.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    fyde.log.info("LOGIN_PAGE_FOUND")
    fyde.progress.step("logging_in")
    local context_code = get_context(spi, login_page_url)
    if context_code == "EXISTEPAS" then
      -- No account for this fiscal number: a wrong username.
      fyde.log.warn("GetContexte: unknown fiscal number")
      error("INVALID_CREDENTIALS", 0)
    end
    if context_code ~= "LMDP" then
      error(
        "GetContexte returned context '"
          .. tostring(context_code)
          .. "' instead of 'LMDP' (a normal password account) - this script doesn't support "
          .. "account creation, locked-account unlock codes, or unrecognized fiscal numbers."
      )
    end
    fyde.log.info("account recognized as a password account, logging in")

    local login_resp = submit_password(spi, password, login_page_url)
    if login_resp.status >= 400 then
      error("login request failed with HTTP status " .. login_resp.status)
    end

    local otp_submitted = false
    if is_otp_challenge(login_resp.body) then
      local otp_token = parse_otp_token(login_resp.body)
      if not otp_token then
        error(
          "detected the emailed security code (OTP) form but couldn't find its 'token' field"
        )
      end
      fyde.log.info("account requires an emailed security code")
      local asked, code = pcall(fyde.input.ask, "Enter the 6-digit security code emailed to you: ")
      if not asked or tostring(code):gsub("%s", "") == "" then
        fyde.log.warn("no security code was provided")
        error("MFA_FAILED", 0)
      end
      otp_submitted = true
      local otp_resp = submit_otp(otp_token, code, login_page_url)
      if otp_resp.status >= 400 then
        error("security code verification request failed with HTTP status " .. otp_resp.status)
      end
    end

    -- The idp session cookie is now set (if login succeeded); re-entering the normal entrypoint
    -- should complete the OIDC flow silently instead of showing the login form again.
    home = fyde.http.get(PART_BASE .. "/")
    if not is_logged_in(home.body) then
      fyde.log.warn("login failed: still seeing the login form after authenticating")
      error(otp_submitted and "MFA_FAILED" or "INVALID_CREDENTIALS", 0)
    end
    fyde.log.info("login succeeded")
  end

  fyde.progress.step("listing_documents")
  -- home.url (not PART_BASE) is the real base: the homepage GET actually redirects through
  -- monprofil-webapp/monCompte into the legacy /enp/ app, landing on /enp/accueilensupres.do.
  -- Resolving the page's relative href against the wrong base silently produces a working but
  -- wrong URL (the root-domain, single-year documents.do) instead of /enp/documents.do, which
  -- is the one that actually renders every year's documents server-side in one response.
  local documents_url = find_documents_link(home.body, home.url)
  if not documents_url then
    error("could not find a 'Documents' link on the authenticated homepage")
  end

  local page = fyde.http.get(documents_url)
  if not is_logged_in(page.body) then
    error("session was logged out while opening the Documents section")
  end

  -- No JS engine here, so the live site's year-selector <select> (which reloads its table via
  -- client-side JS, not a plain link) can't be driven the way impots_scraper.js does it from a
  -- real WebView. This only ever sees whatever year the page renders server-side by default,
  -- same limitation as didaxis.lua's DataTable "show 100 rows" selector.
  local docs = extract_documents(page.body)
  fyde.log.info(string.format("%d document(s) found", #docs))

  for i, doc in ipairs(docs) do
    fyde.progress.update(i, #docs)

    local url = resolve_url(documents_url, doc.href)
    local download = fyde.http.download(url)

    if download.status == 200 and not download.content_type:find("html", 1, true) then
      fyde.save_document("impots/" .. sanitize(doc.text) .. ".pdf", download.body, {
        name = doc.text,
        type = "tax_notice",
        category = "taxes",
        subcategory = "income_tax",
      })
    else
      fyde.log.warn(string.format(
        "failed to download '%s' (status %d, content-type %s)",
        doc.text, download.status, download.content_type
      ))
    end
  end

  fyde.progress.step("done")
end

return M
