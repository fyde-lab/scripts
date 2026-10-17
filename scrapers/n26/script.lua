-- Scraper for N26 (n26.com), the mobile bank: downloads the monthly account statements.
--
-- The original implementation used the `n26` npm client against
-- N26's private API (api.tech26.de): an OAuth2 password grant (`/oauth2/token`,
-- grant_type=password, client "android:secret" as basic auth) - a 4xx below 500 meant
-- LOGIN_FAILED - then `/api/accounts` and `/api/smrt/transactions`, imported into
-- banking doctypes. Since 2019 N26 answers the password grant with `mfa_required` and an
-- `mfaToken`: the second factor is requested with `/api/mfa/challenge` (challengeType "oob",
-- an approval in the N26 app), then the token is obtained with grant_type=mfa_oob - the user is
-- asked to confirm (fyde.input.ask) once they approved it; a token still refused afterwards is
-- MFA_FAILED. Documents: `/api/statements` lists the monthly statements, each served as a PDF
-- by `/api/statements/<id>` with `Accept: application/pdf`. The access token is kept in
-- fyde.session (N26 tokens are short-lived, so most runs need the app approval again).
-- Unverified (see README.md).

local M = {}

local API = "https://api.tech26.de"
local BASIC = "Basic YW5kcm9pZDpzZWNyZXQ="

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local ask_code = helpers.ask_code
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function device_token()
  if not fyde.session.n26_device then
    local hex = {}
    for i = 1, 32 do
      hex[i] = string.format("%x", math.random(0, 15))
    end
    local s = table.concat(hex)
    fyde.session.n26_device = s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-4" .. s:sub(14, 16) .. "-a" .. s:sub(18, 20) .. "-" .. s:sub(21, 32)
  end
  return fyde.session.n26_device
end

local function token_request(form)
  local resp = fyde.http.post_form(API .. "/oauth2/token", form, { Authorization = BASIC, ["device-token"] = device_token() })
  return resp.status, json_or_nil(resp.body) or {}
end

local function api_get(path, token)
  local resp = fyde.http.get(API .. path, { Authorization = "Bearer " .. token })
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("Logging in")
  local status, body = token_request({ grant_type = "password", username = params.username, password = params.password })
  if status >= 500 then
    error("N26 answered HTTP " .. status .. " (vendor down)")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if body.access_token then
    return body.access_token
  end
  local mfa = body.mfaToken or (body.userMessage and body.mfaToken)
  if status == 403 and mfa then
    local challenge = fyde.http.post_json(API .. "/api/mfa/challenge", { challengeType = "oob", mfaToken = mfa },
      { Authorization = BASIC, ["device-token"] = device_token() })
    if challenge.status >= 400 then
      fail(MFA_FAILED, "could not start the app approval (HTTP " .. challenge.status .. ")")
    end
    for _ = 1, 3 do
      ask_code("Approuvez la connexion dans l'application N26, puis répondez OK")
      status, body = token_request({ grant_type = "mfa_oob", mfaToken = mfa })
      if body.access_token then
        return body.access_token
      end
    end
    fail(MFA_FAILED, "the N26 app approval was not received")
  end
  fail(INVALID_CREDENTIALS, "HTTP " .. status)
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local token = fyde.session.n26_token
  if token and api_get("/api/me", token) == 200 then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    token = login(params)
    fyde.session.n26_token = token
  end

  fyde.progress.step("Downloading statements")
  local _, statements = api_get("/api/statements", token)
  for _, statement in ipairs(type(statements) == "table" and statements or {}) do
    local id = statement.id
    if id then
      local month = string.format("%04d-%02d", tonumber(statement.year) or 0, tonumber(statement.month) or 0)
      save_pdf(API .. "/api/statements/" .. id, "N26_releve_" .. month .. ".pdf", {
        name = "Relevé N26 " .. month,
        type = "statement",
        category = "money",
        subcategory = "banking",
      }, { Authorization = "Bearer " .. token, Accept = "application/pdf" })
    end
  end
  fyde.progress.step("Done")
end

return M
