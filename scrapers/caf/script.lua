-- Scraper for the CAF ("Caisse d'Allocations Familiales") "Mon Compte" personal space
-- (caf.fr), the French family-benefits agency portal.
--
-- **Rewritten from a real login HAR capture** (`~/connect-caf-har.json`, not committed here),
-- replacing an earlier `fyde.browser`-driven revision whose `fill()` calls weren't registering
-- with the login page's Angular reactive form. The HAR shows the Angular app (see git history for
-- how it was reached: `www.caf.fr` -> `/redirect/s/Redirect?page=monCompte` -> a client-side
-- redirect -> `connect.caf.fr/connexionappli/dist/...`) itself only ever talks to a plain JSON
-- API underneath - so this script drives that API directly instead of the Angular UI:
--
--   1. `GET  https://connect.caf.fr/token/public` -> `{access_token, expires_in}` - an anonymous
--      bearer token (JWT, `scope: "public"`, ~300s lifetime), reused as-is for every call below
--      up through step 3 (confirmed in the HAR: the same token on `connexion_personne`,
--      `mfa/envoi_otp`, and `mfa/verifier_otp_saisi`).
--   2. `POST https://connect.caf.fr/api/connexionmiddle/v3/connexion_personne`
--      `{identifiant, motDePasse, origineDemande: "WEB", captcha: "", contexteAppel: "caffr"}` -
--      `identifiant` is CAF's own login field name, the French social security number (NIR), not
--      a generic username (the same reason `impots/script.lua` uses `fiscal-number`). A
--      `codeRetour: 0` response either carries a `"MFA"` entry in `etapesConnexion` (one-time
--      code still required - `ccode`/`token` both `null`, the path in the originally captured
--      HAR) or, confirmed in a later run against the same account shortly after a successful
--      `demandeEvitementOtp: true` login (step 4 below) - an empty `etapesConnexion` with `ccode`
--      and `token` already populated directly, meaning this device is remembered and no OTP step
--      is needed this time.
--   3. `POST https://connect.caf.fr/api/connexionmiddle/v1/mfa/envoi_otp`
--      `{modeEnvoi: "MAIL", contexteAppel: "caffr"}` - requests the code be emailed (the HAR's
--      other confirmed option, `telSecuriseFloute`, would be `modeEnvoi: "SMS"` - not used here
--      since nothing here can read an SMS). `fyde.input.ask` then blocks for a human to read the
--      email and type the 6-digit code back in - the same reason `ameli/script.lua` does this
--      rather than trying to automate an OTP step.
--   4. `POST https://connect.caf.fr/api/connexionmiddle/v1/mfa/verifier_otp_saisi`
--      `{codeVerification, demandeEvitementOtp: true, contexteAppel: "caffr"}` -> a `ccode` (a
--      short-lived one-time redemption code, confirmed in the HAR to carry no bearer/JWT
--      semantics of its own - it's just redeemed by the next GET's query string) plus a second,
--      `scope: "usagers"` `accesToken` the HAR shows going completely unused afterwards (no later
--      request carries it anywhere) - likely meant for a native-app flow this web login doesn't
--      use, so this script doesn't send it either.
--   5. `GET https://wwwd.caf.fr/wpc-connexionportail-web/s/AccesPortail?ccode=<ccode>` - a 302
--      that plants the real portal session (`LtpaToken2`, `JSESSIONID`, `CFSESSIONID` - classic
--      IBM WebSphere Portal cookies, confirmed via the HAR's `Set-Cookie` headers) and redirects
--      to `.../redirect/s/Redirect?page=monCompte`, which in turn lands on the dashboard. From
--      here on it's plain cookie-based session auth - `fyde.http`'s cookie jar carries it
--      automatically, the same as any other scraper here.
--   6. `GET https://wwwd.caf.fr/wps/myportal/caffr/moncompte/tableaudebord` - the dashboard,
--      confirmed logged-in via its `<title>` ("CAF - Mon compte allocataire - Accueil" - distinct
--      from the anonymous homepage's "Page d'accueil Allocataires | CAF ..." title).
--
-- **Anti-bot cookies (`__uzma`.."`__uzmf`, `uzmx` - Reblaze/Uzmob).** The HAR's own `Set-Cookie`
-- headers show every one of these is server-set and `HttpOnly`, not computed by client-side JS -
-- `fyde.http`'s persistent cookie jar picks them up and replays them the same way it would any
-- ordinary session cookie, across every call in this flow, no special handling needed. The
-- `connexion_personne` request in the HAR also carries a custom `uzlc` header whose value doesn't
-- match any single cookie byte-for-byte (so it's likely computed by the page's `stormcaster.js`
-- at request time) - this script does not send it; if the server turns out to actually require it
-- for this endpoint, that would surface as a clear rejection at step 2, not a silent failure.
--
-- **Document fetching**: confirmed via real curl captures of the portal's "Mes attestations"/"Mes
-- paiements"/dashboard pages (not reverse-engineered from guesses) - see `DOCUMENTS`/
-- `PORTAL_JWT_PATTERN` below for the `wwwd.caf.fr/api/*` endpoints this downloads and the portal
-- JWT (embedded in the dashboard's own HTML, not the login-flow token above) that authorizes
-- them. Other dashboard sections (`mes courriers`, etc.) are still unexplored.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.json, fyde.progress, fyde.input, fyde.save_document.

local M = {}

-- Login error contract shared with every scraper ported from github.com/konnectors (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.

local TOKEN_PUBLIC_URL = "https://connect.caf.fr/token/public"
local CONNEXION_URL = "https://connect.caf.fr/api/connexionmiddle/v3/connexion_personne"
local ENVOI_OTP_URL = "https://connect.caf.fr/api/connexionmiddle/v1/mfa/envoi_otp"
local VERIFIER_OTP_URL = "https://connect.caf.fr/api/connexionmiddle/v1/mfa/verifier_otp_saisi"
local ACCES_PORTAIL_URL = "https://wwwd.caf.fr/wpc-connexionportail-web/s/AccesPortail"
local DASHBOARD_URL = "https://wwwd.caf.fr/wps/myportal/caffr/moncompte/tableaudebord"

local LOGGED_IN_TITLE_MARKER = "Mon compte allocataire"

-- The dashboard's own rendered HTML embeds a second, richer bearer token directly in a <script>
-- block - `mapForAngularAppli.appConfig.tokenJWT="Bearer eyJ...";` (confirmed against a real
-- dashboard fetch) - distinct from the `connect.caf.fr` tokens used during login: this one's
-- claims carry `idFoyer`/`matricule`/`codeOrga`, and it's what authorizes the portal's own
-- `wwwd.caf.fr/api/*` endpoints (confirmed against a real curl capture of the attestations
-- endpoints below, using a token copied from exactly this script tag). `urlServletJWT` alongside
-- it (`/wps/s/GenerateTokenJwt/`) is presumably how a real page refreshes it once expired -
-- unused here since this script re-fetches the dashboard (and so a fresh token) on every run.
local PORTAL_JWT_PATTERN = 'tokenJWT%s*=%s*"Bearer%s+([^"]+)"'

-- Each entry is a document the portal exposes under `wwwd.caf.fr/api/*`. Confirmed via real curl
-- captures (not just guessed from the URL shape): each returns a raw `application/pdf` body
-- directly, authenticated by the portal JWT alone (`Authorization: Bearer <token>`) - no cookies
-- needed on top of that, confirmed by a bare `curl` with only that header succeeding. The first
-- three are `derniere_attestation` ("most recent attestation") documents from the "Mes
-- attestations" page; `rms` is a different API namespace entirely (`rmsfront`, not
-- `attestationsfront`), from the main dashboard page instead. None of these slugs are documented
-- anywhere seen so far - they're CAF's own API naming: `paiements` ("attestation de paiement"),
-- `qf` ("attestation de quotient familial"), `mns` and `rms` (meanings unconfirmed - possibly
-- "montant net social" and some RSA-related "revenu minimum/récapitulatif ..." respectively).
local DOCUMENTS = {
  {
    slug = "paiements",
    url = "https://wwwd.caf.fr/api/attestationsfront/v1/mon_compte/derniere_attestation/paiements",
    referer = "https://wwwd.caf.fr/wps/myportal/caffr/moncompte/mespaiementsmesdroits",
    name = "Attestation de paiement",
  },
  {
    slug = "mns",
    url = "https://wwwd.caf.fr/api/attestationsfront/v1/mon_compte/derniere_attestation/mns",
    referer = "https://wwwd.caf.fr/wps/myportal/caffr/moncompte/mesattestations",
    name = "Attestation montant net social",
  },
  {
    slug = "qf",
    url = "https://wwwd.caf.fr/api/attestationsfront/v1/mon_compte/derniere_attestation/qf",
    referer = "https://wwwd.caf.fr/wps/myportal/caffr/moncompte/mesattestations",
    name = "Attestation de quotient familial",
  },
  {
    slug = "rms",
    url = "https://wwwd.caf.fr/api/rmsfront/v1/mon_compte/rms",
    referer = "https://wwwd.caf.fr/wps/myportal/caffr/moncompte/tableaudebord",
    name = "Relevé de compte",
  },
}

-- Fetches a fresh anonymous `scope: "public"` bearer token, used to authenticate every call
-- through `verifier_otp_saisi` (confirmed in the captured HAR - the same token is reused as-is
-- across all three).
local function fetch_public_token()
  local resp = fyde.http.get(TOKEN_PUBLIC_URL)
  if resp.status ~= 200 then
    error(string.format("GET %s -> unexpected status %d", TOKEN_PUBLIC_URL, resp.status))
  end
  local decoded = fyde.json.decode(resp.body)
  if not decoded.access_token then
    error("token/public response had no access_token: " .. resp.body)
  end
  return decoded.access_token
end

local function auth_headers(token)
  return { Authorization = "Bearer " .. token }
end

-- Logs in from scratch: fetches an anonymous token, submits credentials, and - the only path
-- confirmed so far (see header comment) - completes the mandatory email OTP step.
local function login(params)
  fyde.progress.step("Fetching an anonymous session token")
  local token = fetch_public_token()

  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Submitting credentials")
  local connexion_resp = fyde.http.post_json(CONNEXION_URL, {
    identifiant = params.nir,
    motDePasse = params.password,
    origineDemande = "WEB",
    captcha = "",
    contexteAppel = "caffr",
  }, auth_headers(token))
  if connexion_resp.status ~= 200 then
    error(string.format(
      "POST %s -> unexpected status %d: %s",
      CONNEXION_URL, connexion_resp.status, connexion_resp.body
    ))
  end
  local connexion = fyde.json.decode(connexion_resp.body)
  if connexion.codeRetour ~= 0 then
    fyde.log.warn(string.format("login rejected (codeRetour=%s): %s", tostring(connexion.codeRetour), connexion_resp.body))
    error("INVALID_CREDENTIALS", 0)
  end

  local needs_mfa = false
  for _, step in ipairs(connexion.etapesConnexion or {}) do
    if step.nom == "MFA" then
      needs_mfa = true
    end
  end

  local ccode = connexion.ccode
  if ccode then
    fyde.log.info("device remembered, no one-time code needed")
  elseif needs_mfa then
    fyde.progress.step("Requesting a one-time code by email")
    local envoi_resp = fyde.http.post_json(
      ENVOI_OTP_URL,
      { modeEnvoi = "MAIL", contexteAppel = "caffr" },
      auth_headers(token)
    )
    if envoi_resp.status ~= 200 then
      error(string.format(
        "POST %s -> unexpected status %d: %s", ENVOI_OTP_URL, envoi_resp.status, envoi_resp.body
      ))
    end
    local envoi = fyde.json.decode(envoi_resp.body)
    if envoi.codeRetour ~= 0 then
      error("requesting the one-time code failed: " .. envoi_resp.body)
    end

    fyde.progress.step("Waiting for the one-time code")
    local asked, answer = pcall(fyde.input.ask, "CAF emailed a one-time code - enter it:")
    local otp = asked and tostring(answer):gsub("%D", "") or ""
    if #otp == 0 then
      fyde.log.warn("expected a numeric one-time code, got none")
      error("MFA_FAILED", 0)
    end

    local verify_resp = fyde.http.post_json(VERIFIER_OTP_URL, {
      codeVerification = otp,
      demandeEvitementOtp = true,
      contexteAppel = "caffr",
    }, auth_headers(token))
    if verify_resp.status ~= 200 then
      error(string.format(
        "POST %s -> unexpected status %d: %s", VERIFIER_OTP_URL, verify_resp.status, verify_resp.body
      ))
    end
    local verify = fyde.json.decode(verify_resp.body)
    if verify.codeRetour ~= 0 then
      fyde.log.warn("one-time code rejected: " .. verify_resp.body)
      error("MFA_FAILED", 0)
    end
    ccode = verify.ccode
    if not ccode then
      error("verifier_otp_saisi response had no ccode: " .. verify_resp.body)
    end
  else
    -- Neither an MFA step nor a ccode - rather than assume this is an error, check whether
    -- connexion_personne's own response already left us logged in (e.g. it may set the portal
    -- session cookies directly in some account states, with no separate ccode/AccesPortail
    -- redemption needed - unconfirmed, since every login seen so far has gone through one of the
    -- two branches above, but worth checking before giving up).
    fyde.log.info("connexion_personne returned neither an MFA step nor a ccode - checking "
      .. "whether it logged us in directly")
    local check_resp = fyde.http.get(DASHBOARD_URL)
    if check_resp.body:find(LOGGED_IN_TITLE_MARKER, 1, true) then
      fyde.log.info("logged in directly, no ccode/AccesPortail step needed")
      return
    end
    error(
      "connexion_personne returned neither an MFA step nor a ccode, and the dashboard doesn't "
      .. "show the logged-in title marker either - the site changed in a way this script "
      .. "doesn't handle yet: " .. connexion_resp.body
    )
  end

  fyde.progress.step("Opening the portal session")
  local acces_resp = fyde.http.get(ACCES_PORTAIL_URL .. "?ccode=" .. ccode)
  fyde.log.info(string.format(
    "GET %s -> status %d, landed on %s", ACCES_PORTAIL_URL, acces_resp.status, acces_resp.url
  ))
end

-- Extracts the portal JWT embedded in the dashboard's own HTML (see PORTAL_JWT_PATTERN).
local function extract_portal_jwt(dashboard_body)
  local token = dashboard_body:match(PORTAL_JWT_PATTERN)
  if not token then
    error("could not find the embedded portal JWT (tokenJWT) in the dashboard page")
  end
  return token
end

-- Downloads every document in DOCUMENTS, saving each as a PDF. A single document failing (not
-- available for this account, unexpected content, ...) logs a warning rather than aborting the
-- whole run - the same convention as didaxis/script.lua's document loop.
local function fetch_documents(jwt)
  fyde.progress.step("Fetching documents")
  for _, document in ipairs(DOCUMENTS) do
    local headers = {
      Authorization = "Bearer " .. jwt,
      ["Content-Type"] = "application/pdf",
      Accept = "application/json, text/plain, */*",
      Referer = document.referer,
    }
    local ok, resp = pcall(fyde.http.download, document.url, headers)
    if not ok then
      fyde.log.warn(string.format("document %s: request failed: %s", document.slug, tostring(resp)))
    elseif resp.status ~= 200 then
      fyde.log.warn(string.format(
        "document %s: unexpected status %d", document.slug, resp.status
      ))
    elseif not (resp.content_type or ""):find("pdf", 1, true) then
      fyde.log.warn(string.format(
        "document %s: unexpected content-type %q (likely not available for this account)",
        document.slug, resp.content_type
      ))
    else
      local filename = document.slug .. ".pdf"
      fyde.save_document(filename, resp.body, {
        name = document.name,
        type = document.slug,
        source_category = "gov",
        source_sub_category = "family",
        purpose = "attestation",
      })
      fyde.log.info(string.format("saved %s (%d bytes)", filename, #resp.body))
    end
  end
end

function M.run(params)
  -- fyde.http's cookie jar is restored from the previous run's saved cookies (see
  -- host/session.rs) before this script even starts - the portal session this flow establishes
  -- (LtpaToken2/JSESSIONID/CFSESSIONID, see header comment) can still be valid, which would land
  -- us on the real dashboard here without ever hitting CAF's login API or OTP step again. Mirrors
  -- didaxis/script.lua's "Checking for an existing session" pattern.
  fyde.progress.step("Checking for an existing session")
  local dashboard_resp = fyde.http.get(DASHBOARD_URL)
  if dashboard_resp.body:find(LOGGED_IN_TITLE_MARKER, 1, true) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)

    dashboard_resp = fyde.http.get(DASHBOARD_URL)
    fyde.log.info(string.format("GET %s -> status %d", DASHBOARD_URL, dashboard_resp.status))
    if not dashboard_resp.body:find(LOGGED_IN_TITLE_MARKER, 1, true) then
      error(
        "login did not succeed - the dashboard page didn't show the logged-in title marker, so "
        .. "the session does not appear authenticated"
      )
    end
    fyde.log.info("authenticated")
  end

  local jwt = extract_portal_jwt(dashboard_resp.body)
  fetch_documents(jwt)

  fyde.progress.step("Done")
end

return M
