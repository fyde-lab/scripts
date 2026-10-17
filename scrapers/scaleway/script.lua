-- Scraper for Scaleway (scaleway.com), the cloud provider: downloads the paid invoices.
--
-- `api.scaleway.com/account/v2/login`
-- takes {email, password, captcha} (the original implementation solved the console's reCAPTCHA through a paid
-- service - not available here, so the call is made without it and a captcha demand is
-- reported as such); a 403 "2FA_error" asks for the authenticator code, sent as `2FA_token` to
-- `/account/v2/login/jwt` (a refusal there = MFA_FAILED); "required passwordless auth for unknown
-- ip" (magic link) is unsupported; any other refusal = bad credentials. The answer's `token` is
-- the `X-Session-Token`; `iam/v1alpha1/users/<jwt.issuer_id>` gives the organization, whose
-- invoices are listed by `billing/v1/invoices?organization_id=...` (paid ones downloaded with
-- `?format=pdf`). The original implementation deleted its session JWT at the end (DELETE
-- `iam/v1alpha1/jwts/<jti>`); fyde.http has no DELETE, so the JWT is kept in fyde.session instead
-- and reused by the next run while the users endpoint still accepts it. Unverified (see
-- README.md).

local M = {}

local API = "https://api.scaleway.com"

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
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains
local sanitize = helpers.sanitize
local ask_code = helpers.ask_code

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
  local body = { email = params.username, password = params.password }
  local resp = fyde.http.post_json(API .. "/account/v2/login", body)
  if resp.status >= 500 then
    error("Scaleway answered HTTP " .. resp.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local data = json_or_nil(resp.body) or {}
  if resp.status == 403 and contains(resp.body, "2FA_error") then
    body["2FA_token"] = ask_code("Code de double authentification Scaleway")
    resp = fyde.http.post_json(API .. "/account/v2/login/jwt", body)
    data = json_or_nil(resp.body) or {}
    if resp.status >= 400 or not data.token then
      fail(MFA_FAILED, data.message)
    end
  elseif resp.status >= 400 then
    if contains(resp.body, "captcha") then
      error("Scaleway asks for a captcha, which this scraper can't solve")
    elseif contains(resp.body, "passwordless auth for unknown ip") then
      error("Scaleway asks for a magic-link login from this IP (not supported)")
    end
    fail(INVALID_CREDENTIALS, data.message)
  end
  if not data.token then
    error("Scaleway login answered no token")
  end
  return data
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local function me(token, issuer)
    local resp = fyde.http.get(API .. "/iam/v1alpha1/users/" .. tostring(issuer), { ["X-Session-Token"] = token })
    return resp.status == 200 and json_or_nil(resp.body) or nil
  end
  local token, issuer = fyde.session.scaleway_token, fyde.session.scaleway_issuer
  local user = token and me(token, issuer)
  if user then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    local session = login(params)
    token, issuer = session.token, session.jwt and session.jwt.issuer_id
    fyde.session.scaleway_token, fyde.session.scaleway_issuer = token, issuer
    user = me(token, issuer) or {}
  end
  local headers = { ["X-Session-Token"] = token }
  fyde.progress.step("Downloading invoices")
  local list = json_or_nil(fyde.http.get(API .. "/billing/v1/invoices?organization_id=" .. tostring(user.organization_id), headers).body) or {}
  for _, invoice in ipairs(list.invoices or {}) do
    if invoice.state == "paid" then
      local date = tostring(invoice.start_date):sub(1, 10)
      save_pdf(API .. "/billing/v1/invoices/" .. tostring(invoice.organization_id) .. "/" .. tostring(invoice.start_date) .. "/" .. tostring(invoice.id) .. "?format=pdf",
        date .. "_" .. tostring(invoice.total_taxed) .. "_" .. tostring(invoice.currency) .. ".pdf", {
          name = "Facture Scaleway " .. date,
          type = "invoice",
          category = "subscriptions",
          subcategory = "cloud_software",
        }, headers)
    end
  end
  fyde.progress.step("Done")
end

return M
