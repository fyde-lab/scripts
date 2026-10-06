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
--      and clicks the submit control again. **Not yet exercised end to end** - confirmed only up
--      through the OTP request landing on the six-digit form, not through a real code submission.
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
-- **No document-fetching logic yet.** Past login, `fyde.browser` has no bridge back to
-- `fyde.http` (its webview cookie jar is entirely separate from `fyde.http`'s own - see
-- `browser::Service::submit`'s doc comment), so the "monthly statements" page this script used
-- to probe (still true: unconfirmed selectors) would also need driving through `fyde.browser`,
-- not ported back to `fyde.http`, once this login flow itself is confirmed working.

local M = {}

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

-- Fills the six single-digit OTP fields (`#numOTP1`..`#numOTP6`) from `code`, a 6-digit string.
local function fill_otp_digits(code)
  for i = 1, 6 do
    fyde.browser:fill("#numOTP" .. i, code:sub(i, i))
  end
end

-- Asks the user for the OTP just emailed to them, fills the six digit fields, and clicks the
-- submit control a second time.
local function submit_otp()
  local otp = fyde.input.ask("Ameli sent a one-time passcode (OTP) - enter it:"):gsub("%D", "")
  if #otp ~= 6 then
    error("expected a 6-digit OTP, got " .. #otp .. " digit(s)")
  end

  fill_otp_digits(otp)
  fyde.browser:click(SUBMIT_CONTROL)
  fyde.browser:wait_for(LOGGED_IN_MARKER, POST_SUBMIT_TIMEOUT_MS)
end

function M.run(params)
  fyde.progress.step("Visiting the login page")
  -- A real browser follows LOGIN_URL's redirect chain (through ameliconnect.ameli.fr's OAuth2
  -- flow) on its own; unlike the old fyde.http-based version, there's no manual Location-header
  -- chasing to do here.
  fyde.browser:open(LOGIN_URL)
  fyde.browser:wait_for(USER_FIELD, FORM_LOAD_TIMEOUT_MS)

  fyde.progress.step("Submitting credentials")
  fyde.browser:fill(USER_FIELD, params.identifiant)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT_CONTROL)

  -- A real click lands on one of three states (see header comment) - wait for any of them with
  -- one grouped selector (document.querySelector accepts a comma-separated selector list), then
  -- probe each individually to tell them apart.
  local ok, err = pcall(function()
    fyde.browser:wait_for(
      LOGGED_IN_MARKER .. ", " .. OTP_REQUEST_BUTTON .. ", " .. OTP_FIRST_DIGIT,
      POST_SUBMIT_TIMEOUT_MS
    )
  end)
  if not ok then
    -- None of the three known states showed up - dump whatever actually rendered instead of
    -- just erroring blind, so a future run tells us which 4th state this script doesn't handle
    -- yet (error page, captcha, a slower-than-expected render, ...) instead of just "timed out".
    local html_ok, html = pcall(function()
      return fyde.browser:html()
    end)
    if html_ok then
      fyde.log.info("post-submit timeout - page markup (first 4000 chars): " .. html:sub(1, 4000))
    else
      fyde.log.info("post-submit timeout - fetching page markup for diagnosis also failed: " .. tostring(html))
    end
    error(err)
  end

  if browser_has(LOGGED_IN_MARKER) then
    fyde.log.info("logged in without a one-time passcode step")
  elseif browser_has(OTP_REQUEST_BUTTON) then
    fyde.progress.step("Requesting a security code")
    fyde.browser:click(OTP_REQUEST_BUTTON)
    fyde.browser:wait_for(OTP_FIRST_DIGIT, POST_SUBMIT_TIMEOUT_MS)

    fyde.progress.step("Waiting for the one-time passcode")
    submit_otp()
  elseif browser_has(OTP_FIRST_DIGIT) then
    fyde.progress.step("Waiting for the one-time passcode")
    submit_otp()
  else
    error(
      "login did not land on a recognized state after submitting credentials - wrong "
        .. "identifiant/password, or the site changed in a way this script doesn't handle yet"
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

return M
