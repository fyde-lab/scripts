-- Scraper for Humanis' health customer area, now Malakoff Humanis' "espace particulier"
-- (espace-particulier.malakoffhumanis.com): login check only, documents not ported yet.
--
-- The original sante-espaceparticuliers.humanis.com
-- Drupal site now redirects to particulier.malakoffhumanis.com. The new customer area is an
-- Angular SPA that logs in through a CIAM at connexion.malakoffhumanis.com/particuliers - a React
-- app whose JSON API this script talks to directly:
-- - `POST <ciam>/login/api/authenticate` with `{"module": "UsernameAndPassword", "definition":
--   {"username", "password"}}` answers 401 `{"code": 2001, "message": "Invalid credentials"}` for
--   bad credentials (confirmed against the live site); a good login answers with the next module
--   (a 2FA step - TwoFASms/TwoFAEmail/... - or Success), not verified (no account).
-- Documents would then come from the SPA's OAuth2 code flow (`<ciam>/auth/oauth2.0/v1/authorize`)
-- and api.malakoffhumanis.com/ciam (`ppa/application/documents/v1`, with the SPA's `apiKey`),
-- whose client id and calls live in lazily loaded chunks - not ported: a successful login stops
-- with an explicit error. See README.md.

local M = {}

local CIAM = "https://connexion.malakoffhumanis.com/particuliers"
local AUTHENTICATE_URL = CIAM .. "/login/api/authenticate"
local JSON = { Accept = "application/json" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local json_or_nil = helpers.json_or_nil

local function login(params)
  fyde.progress.step("logging_in")
  local resp = fyde.http.post_json(AUTHENTICATE_URL, {
    module = "UsernameAndPassword",
    definition = { username = params.username, password = params.password },
  }, JSON)
  local body = json_or_nil(resp.body)
  if not body then
    error("Malakoff Humanis login API not found (HTTP " .. resp.status .. " from " .. AUTHENTICATE_URL .. ")")
  end
  -- No HTML form here: the login API answering in JSON is the "login page".
  fyde.log.info("LOGIN_PAGE_FOUND")
  if resp.status == 401 or body.code == 2001 then
    fail(INVALID_CREDENTIALS, body.message)
  end
  if resp.status >= 300 then
    error("Malakoff Humanis login answered HTTP " .. resp.status .. ": " .. tostring(body.message))
  end
  return body
end

function M.run(params)
  -- No session check: nothing past the login is ported, so there's no session to reuse yet.
  local answer = login(params)
  error("credentials accepted (next step: " .. tostring(answer.module) .. "), but the Malakoff Humanis "
    .. "documents API isn't ported yet - see this script's header comment", 0)
end

return M
