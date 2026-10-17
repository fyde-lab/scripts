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
local fail = helpers.fail
local sanitize = helpers.sanitize

local function absolute(base, href)
  if not href or href == "" then
    return base
  end
  href = href:gsub("&amp;", "&")
  if href:match("^https?://") then
    return href
  end
  local origin = base:match("^(https?://[^/]+)")
  if href:sub(1, 2) == "//" then
    return base:match("^(https?:)") .. href
  end
  if href:sub(1, 1) == "/" then
    return origin .. href
  end
  if href:sub(1, 1) == "?" then
    return (base:gsub("%?.*$", "")) .. href
  end
  local dir = (base:gsub("[?#].*$", "")):match("^(https?://.*/)") or (origin .. "/")
  return dir .. href
end

-- Form login helper (`signin({ formSelector })`-style): reads the first form matching
-- `selector` on `page` (a fyde.http response) and returns its absolute action URL plus every
-- named input's current value (unchecked checkboxes/radios left out, like a browser does).
local function read_form(page, selector)
  local form = fyde.html.select(page.body, selector)[1]
  if not form then
    return nil
  end
  local fields = {}
  for _, input in ipairs(fyde.html.select(form.html, "input[name]")) do
    local kind = (input.attrs.type or "text"):lower()
    if (kind ~= "checkbox" and kind ~= "radio") or input.attrs.checked then
      fields[input.attrs.name] = input.attrs.value or ""
    end
  end
  return absolute(page.url, form.attrs.action), fields
end

-- Fills `values` into the form matching `selector` on `page` and posts it.
local function submit_form(page, selector, values, headers)
  local action, fields = read_form(page, selector)
  if not action then
    error("no form matching '" .. selector .. "' on " .. tostring(page.url))
  end
  for name, value in pairs(values) do
    fields[name] = value
  end
  return fyde.http.post_form(action, fields, headers)
end

local function has(page_or_html, selector)
  local html = type(page_or_html) == "table" and page_or_html.body or page_or_html
  return #fyde.html.select(html or "", selector) > 0
end

local function json_or_nil(body)
  local ok, value = pcall(fyde.json.decode, body or "")
  if ok then
    return value
  end
  return nil
end

-- Downloads `url` and saves it as `filename` when it really is a PDF; returns true on success.
local function save_pdf(url, filename, fields, headers)
  local resp = fyde.http.download(url, headers)
  local content_type = resp.content_type or ""
  local is_pdf = content_type:find("pdf", 1, true) or (resp.body or ""):sub(1, 4) == "%PDF"
  if resp.status == 200 and is_pdf then
    fyde.save_document(sanitize(filename), resp.body, fields)
    return true
  end
  fyde.log.warn(string.format("skipping %s (status %d, content-type %s)", filename, resp.status, content_type))
  return false
end
-- luacheck: pop

local function login(params)
  fyde.progress.step("Logging in")
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
