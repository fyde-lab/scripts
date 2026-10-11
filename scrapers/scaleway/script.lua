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
local INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
local MFA_FAILED = "MFA_FAILED"

local function fail(code, detail)
  if detail then
    fyde.log.warn(code .. ": " .. detail)
  end
  error(code, 0)
end

local function contains(haystack, needle)
  return (haystack or ""):lower():find(needle:lower(), 1, true) ~= nil
end

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if contains(haystack, needle) then
      return true
    end
  end
  return false
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize(name)
  name = trim((name or ""):gsub("%s+", " "))
  name = name:gsub('[<>:"/\\|%?%*]', "_"):gsub("%c", "")
  if name == "" then
    name = "document"
  end
  return name
end

-- Asks the user for a one-time code through fyde.input.ask; an unanswered/empty prompt (or no
-- input handler at all, e.g. an unattended run) is an MFA failure.
local function ask_code(question)
  local ok, code = pcall(fyde.input.ask, question)
  if not ok or type(code) ~= "string" or trim(code) == "" then
    fail(MFA_FAILED, "no one-time code was provided")
  end
  return (code:gsub("%s", ""))
end

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
          type = "web_service_invoice",
          source_category = "web",
          purpose = "invoice",
        }, headers)
    end
  end
  fyde.progress.step("Done")
end

return M
