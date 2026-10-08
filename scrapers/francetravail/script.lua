-- Scraper for France Travail's ("Pôle emploi") job-seeker personal space
-- (candidat.francetravail.fr/espacepersonnel), a Single Page Application that authenticates
-- against a separate ForgeRock/OpenAM identity server (authentification-candidat.francetravail.fr)
-- via the OAuth2/OIDC implicit flow (`response_type=id_token token`).
--
-- **Built from a real login HAR capture** (`~/francetravail-har.json`, not committed here).
-- Unlike `didaxis`/`impots`, this isn't a plain HTML form POST: ForgeRock AM drives login through
-- a stateful, JSON "callback" auth tree - each `POST .../authenticate` either returns the next
-- batch of callbacks to fill in (an `authId` plus a `callbacks` array, each with an `input` the
-- client writes its answer into) or, once the tree is satisfied, a final `{tokenId, successUrl}`
-- with no more callbacks. The HAR shows this tree's stages, in order, for this account:
--
--   1. `SaisieLoginMdp` - a `NameCallback`/`PasswordCallback` pair, filled with
--      `params.username`/`params.password`.
--   2. (unlabelled) a `DeviceProfileCallback` - a JS-collected browser/hardware fingerprint,
--      submitted as a JSON string. Confirmed in the HAR to be plain client-reported metadata (not
--      a computed/signed proof the server could reject), so this script submits a fixed, static
--      profile instead of trying to run real browser JS, which this host doesn't have anyway -
--      see `device_profile_json()`.
--   3. `SelectionMoyenDeContact` - choose how the one-time code is delivered. Two
--      `HiddenValueCallback`s advertise the available channels (`COURRIEL`/email,
--      `SMS`), echoed back by their `id` (not their masked `value`), plus a `ConfirmationCallback`
--      picking one by index - this script always picks index 0 (`COURRIEL`/email, confirmed in
--      the HAR to also be what the captured session chose), since nothing here can read an SMS.
--   4. `OTPCollectorPage` - a one-time code, delivered out-of-band (email/SMS) and asked for via
--      `fyde.input.ask` the same way `ameli`/`caf` ask for theirs. Oddly laid out as 8 separate
--      single-digit-looking `PasswordCallback` boxes, but the HAR shows the *entire* code
--      submitted in just the first one, the rest left empty, and the server still accepted it -
--      this script mirrors that exactly rather than trying to split the code across boxes.
--   5. `SaveMoyenDeConfiance` - "Enregister" (save this device as trusted) vs "Passer" (skip).
--      This script always picks "Enregister" (index 0, also what the HAR's session chose), in
--      the hope that a later run's `DeviceProfileCallback` (same persisted `identifier`, see
--      `device_identifier()`) gets recognized and skips the OTP step - **unconfirmed**: the HAR
--      only covers one login, so whether trusting the device actually avoids OTP on a later run
--      hasn't been verified against a real second login yet.
--   6. (unlabelled) the `DeviceProfileCallback` again, submitted identically to step 2 (confirmed
--      in the HAR: byte-for-byte the same JSON both times within one session).
--   7. Final response: `{tokenId, successUrl, realm}`, no more callbacks. `successUrl` is a
--      realm-scoped `.../oauth2/realms/root/realms/individu/authorize` URL; `GET`-ing it 302s to
--      `REDIRECT_URI` with `access_token`/`id_token` in the response's URL *fragment* (never sent
--      to the server, and not preserved by `fyde.http`'s redirect-following either - see
--      `is_logged_in()` for why that's fine, since nothing here currently needs the tokens
--      themselves).
--
-- **Already-logged-in check**: re-request the top-level `/connexion/oauth2/authorize` endpoint.
-- With a still-valid SSO session (cookie-based, restored automatically from the previous run by
-- `fyde.http`'s cookie jar), the server 302s straight through to `candidat.francetravail.fr`; with
-- no session, it 302s down to the login page instead, landing on
-- `authentification-candidat.francetravail.fr`. The final host alone is a reliable marker without
-- needing to read the (unavailable) fragment or any response header.
--
-- **Not yet implemented: document fetching.** The HAR this script was built from only covers the
-- login flow - it stops right after landing back on the SPA's homepage, before showing where
-- documents/attestations actually live in this espace personnel. A follow-up HAR capturing that
-- part of the site is needed before `fyde.save_document` calls can be added here.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs):
-- fyde.log, fyde.http, fyde.json, fyde.progress, fyde.input.

local M = {}

local AUTHENTICATE_URL =
  "https://authentification-candidat.francetravail.fr/connexion/json/realms/root/realms/individu/authenticate"
local AUTHORIZE_PATH = "https://authentification-candidat.francetravail.fr/connexion/oauth2/authorize"
local AUTHORIZE_REALM_PATH =
  "https://authentification-candidat.francetravail.fr/connexion/oauth2/realms/root/realms/individu/authorize"
local REDIRECT_URI = "https://candidat.francetravail.fr/espacepersonnel/"

-- The SPA's own public OAuth client, read from its committed `assets/configuration/config.json`
-- (`pn073ClientId`/`pn073Scopes`) in the HAR - not a secret, just baked into the client-side app.
local CLIENT_ID = "USG_PN073-tdbcandidat_6408B42F17FC872440D4FF01BA6BAB16999CD903772C528808D1E6FA2B585CF2"
local SCOPES = "application_" .. CLIENT_ID
  .. " compteUsager contexteAuthentification coordonnees courrier email etatcivil idIdentiteExterne"
  .. " idRci individu logW messagerieintegree navigation nomenclature notifications openid pilote"
  .. " pole_emploi prdvl profile reclamation suggestions mesrdvs offre criteresrecherchesoffres"
  .. " profilpro document"

-- Fixed rather than randomized per run - this script doesn't validate the state/nonce echoed
-- back against what it sent (no real OIDC client-side verification happening here), so there's
-- nothing random protects against in this context.
local STATE = "fydeScraperState1"
local NONCE = "fydeScraperNonce1"

-- Confirmed required/present on every `authenticate` call in the HAR. `Accept-Encoding:
-- identity` is added for the same reason as `NO_COMPRESSION_HEADERS` below - this host serves
-- a raw deflate stream `fyde.http`'s decoder can't parse.
local AUTH_HEADERS = {
  ["Accept-API-Version"] = "protocol=1.0,resource=2.1",
  ["X-Password"] = "anonymous",
  ["X-Username"] = "anonymous",
  ["X-NoSession"] = "true",
  ["Origin"] = "https://authentification-candidat.francetravail.fr",
  ["Accept-Encoding"] = "identity",
}

-- Percent-encodes a query parameter value (RFC 3986 unreserved set kept as-is, everything else
-- escaped, spaces as %20 rather than form-encoded "+" since these go in a URL query, not a body).
local function urlencode(str)
  return (str:gsub("[^%w%-%.~_]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Builds the OAuth2/OIDC implicit-flow authorize URL against `base`: either the top-level
-- `/connexion/oauth2/authorize` (used to check for an existing SSO session) or the realm-scoped
-- `/connexion/oauth2/realms/root/realms/individu/authorize` (used as the authenticate call's
-- `goto` destination, per the HAR) - same query shape either way.
local function authorize_url(base)
  return base
    .. "?realm=" .. urlencode("/individu")
    .. "&response_type=" .. urlencode("id_token token")
    .. "&scope=" .. urlencode(SCOPES)
    .. "&client_id=" .. urlencode(CLIENT_ID)
    .. "&state=" .. urlencode(STATE)
    .. "&nonce=" .. urlencode(NONCE)
    .. "&redirect_uri=" .. urlencode(REDIRECT_URI)
end

-- A stable per-install device fingerprint ("identifier"), generated once and persisted via
-- fyde.session across runs - mirrors a real browser's own localStorage-backed device id, which
-- the site's DeviceProfileCallback (sent twice per login - see header comment) ties to the
-- "SaveMoyenDeConfiance" (save as trusted device) step, confirmed in the HAR to carry the exact
-- same identifier both times within one session.
local function device_identifier()
  if not fyde.session.device_identifier then
    fyde.session.device_identifier = string.format(
      "%d-%d-%d",
      math.random(1000000000, 9999999999),
      math.random(100000000, 999999999),
      math.random(1000000000, 9999999999)
    )
  end
  return fyde.session.device_identifier
end

-- The DeviceProfileCallback payload, confirmed in the HAR to be submitted identically at both
-- points the auth tree asks for it. Fields the real capture sent as JSON `null` are omitted
-- (fyde.json has no null sentinel) rather than approximated - a fixed, plausible Linux/Firefox
-- profile is enough to satisfy the callback without claiming a browser session this host doesn't
-- have.
local function device_profile_json()
  return fyde.json.encode({
    identifier = device_identifier(),
    metadata = {
      hardware = {
        hardwareConcurrency = 8,
        maxTouchPoints = 0,
        oscpu = "Linux x86_64",
        display = { width = 1920, height = 1080, pixelDepth = 24, angle = 0 },
      },
      browser = {
        userAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:157.0) Gecko/20100101 Firefox/157.0",
        appName = "Netscape",
        appCodeName = "Mozilla",
        appVersion = "5.0 (X11)",
        buildID = "20181001000000",
        product = "Gecko",
        productSub = "20100101",
        vendor = "",
        vendorSub = "",
        plugins = "internal-pdf-viewer;internal-pdf-viewer;internal-pdf-viewer;internal-pdf-viewer;"
          .. "internal-pdf-viewer;",
      },
      platform = {
        language = "en-US",
        platform = "Linux x86_64",
        deviceName = "Linux (Browser)",
        fonts = "cursive;monospace;sans-serif;fantasy;Arial;Courier;Courier New;Times;"
          .. "Times New Roman;",
        timezone = -120,
      },
    },
  })
end

-- Checks for a still-valid SSO session by re-requesting the authorize endpoint: with no valid
-- session, the server 302s all the way down to the login page (host stays
-- authentification-candidat.francetravail.fr, confirmed in the HAR's entries 4-6); with one, it
-- 302s straight through to `REDIRECT_URI` with the tokens in the response's URL fragment -
-- fragments never reach the server and aren't preserved by `fyde.http`'s redirect-following
-- either, but the final host alone is already a reliable marker (candidat.francetravail.fr vs
-- authentification-candidat.francetravail.fr).
-- `Accept-Encoding: identity` disables response compression: the authentification-candidat
-- host's `XUI/` login page serves `Content-Encoding: deflate` as a raw (non-zlib-wrapped)
-- deflate stream, which `fyde.http`'s decoder (strict about the zlib header) rejects with
-- "incorrect header check" - confirmed by comparing against `curl --compressed`, which decodes
-- the same bytes fine since it isn't strict about the header. Asking for uncompressed content
-- sidesteps the decoder entirely rather than needing a raw-deflate-without-header mode.
local NO_COMPRESSION_HEADERS = { ["Accept-Encoding"] = "identity" }

local function is_logged_in()
  local resp = fyde.http.get(authorize_url(AUTHORIZE_PATH), NO_COMPRESSION_HEADERS)
  return resp.status == 200 and resp.url:find("^https://candidat%.francetravail%.fr/") ~= nil
end

-- Fills in one callback's input value in place, based on its `type` and the tree's current
-- `stage` - the generic shape of ForgeRock/OpenAM's callback-based auth trees, confirmed against
-- every stage this login actually goes through (see header comment). `otp_index` counts
-- PasswordCallbacks seen so far within the current response, since OTPCollectorPage's whole code
-- goes in the *first* one (see header comment, step 4).
local function fill_callback(stage, cb, params, otp, otp_index)
  local cb_type = cb.type
  if cb_type == "NameCallback" then
    cb.input[1].value = params.username
  elseif cb_type == "PasswordCallback" then
    if stage == "OTPCollectorPage" then
      otp_index.n = otp_index.n + 1
      cb.input[1].value = otp_index.n == 1 and otp or ""
    else
      cb.input[1].value = params.password
    end
  elseif cb_type == "HiddenValueCallback" then
    -- The value a real browser echoes back is the callback's own `id` (e.g. "COURRIEL"/"SMS"),
    -- not its (masked) display `value` - confirmed in the HAR.
    cb.input[1].value = cb.id
  elseif cb_type == "ConfirmationCallback" then
    -- Always option 0 - see header comment, steps 3/4/5, for what that picks at each stage.
    cb.input[1].value = "0"
  elseif cb_type == "DeviceProfileCallback" then
    cb.input[1].value = device_profile_json()
  end
  -- TextOutputCallback and any other output-only callback type has no `input` to fill.
end

-- Walks the ForgeRock/OpenAM callback-based auth tree to completion: starts a fresh tree, then
-- repeatedly fills in and resubmits whatever callbacks the latest response asks for until it
-- returns a final `{tokenId, successUrl}` (no more `callbacks`) instead. `otp` is read once, the
-- first (and, per the HAR, only) time an OTPCollectorPage stage is reached - `fyde.input.ask`
-- blocks for it, since the code is emailed/texted out-of-band and can't be known ahead of time.
local function login(params)
  local goto_url = authorize_url(AUTHORIZE_REALM_PATH)
  local authenticate_url = AUTHENTICATE_URL .. "?goto=" .. urlencode(goto_url)

  fyde.progress.step("Submitting credentials")
  local resp = fyde.http.post_json(authenticate_url, {}, AUTH_HEADERS)
  local otp_asked = false
  local otp = nil

  for _ = 1, 10 do
    if resp.status ~= 200 then
      error(string.format(
        "POST %s -> unexpected status %d: %s", authenticate_url, resp.status, resp.body
      ))
    end
    local decoded = fyde.json.decode(resp.body)
    if not decoded.callbacks then
      -- Final step of the tree: {tokenId, successUrl, realm} - no more callbacks to fill.
      if not decoded.successUrl then
        error("authenticate tree completed with no successUrl: " .. resp.body)
      end
      fyde.progress.step("Finishing the OAuth exchange")
      local final_resp = fyde.http.get(decoded.successUrl, NO_COMPRESSION_HEADERS)
      fyde.log.info(string.format(
        "GET successUrl -> status %d, landed on %s", final_resp.status, final_resp.url
      ))
      return
    end

    local stage = decoded.stage
    fyde.log.info("auth tree stage: " .. tostring(stage))

    if stage == "SelectionMoyenDeContact" then
      fyde.progress.step("Choosing how to receive the one-time code")
    elseif stage == "OTPCollectorPage" then
      fyde.progress.step("Waiting for the one-time code")
      if not otp_asked then
        otp = (fyde.input.ask(
          "France Travail sent a one-time code (email/SMS) - enter it:"
        )):gsub("%D", "")
        otp_asked = true
        if #otp == 0 then
          error("expected a numeric one-time code, got none")
        end
      end
    elseif stage == "SaveMoyenDeConfiance" then
      fyde.progress.step("Responding to the trusted-device prompt")
    end

    local otp_index = { n = 0 }
    for _, cb in ipairs(decoded.callbacks) do
      fill_callback(stage, cb, params, otp, otp_index)
    end

    resp = fyde.http.post_json(authenticate_url, {
      authId = decoded.authId,
      callbacks = decoded.callbacks,
      stage = stage,
    }, AUTH_HEADERS)
  end

  error("authenticate tree did not complete after 10 steps - the site likely added a new step "
    .. "this script doesn't handle yet")
end

function M.run(params)
  -- fyde.http's cookie jar is restored from the previous run automatically (see host/session.rs),
  -- so a still-valid SSO session can let this skip straight past login - mirrors
  -- didaxis/script.lua's and caf/script.lua's "Checking for an existing session" pattern.
  fyde.progress.step("Checking for an existing session")
  if is_logged_in() then
    fyde.log.info("restored session is still valid, skipping login")
  else
    login(params)
    if not is_logged_in() then
      error("login did not succeed - still not landing on candidat.francetravail.fr after "
        .. "completing the auth tree")
    end
    fyde.log.info("authenticated")
  end

  -- Document fetching isn't wired up yet - see header comment: the HAR this script was built
  -- from only covers the login flow, not the documents section of the espace personnel.
  fyde.progress.step("Done")
end

return M
