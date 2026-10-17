-- Scraper for SAUR's customer area (saurclient.fr), a water utility: downloads the water bills.
--
-- `apib2c.azure.saurclient.fr/admin/auth`
-- took a JSON password grant (username, password, client_id=frontjs-client, scope=api-scope)
-- and answered `token.access_token` plus the `defaultContract` (customerAccountId,
-- billingAgreementId). That endpoint now answers HTTP 500; the current app
-- (mon-espace.saurclient.fr) posts the same grant, plus `isRecaptchaV3`/`captchaToken` flags, to
-- `/admin/v2/auth` - which answers made-up credentials with HTTP 401 `ClientNotFound` without
-- any captcha token (checked live); its success answer is unconfirmed. 504 = vendor down. Bills:
-- `/inv/billing_agreements/<billing id>/product_invoices` (reference, amountIncludingTaxes,
-- settlementDate/dueDate); each PDF comes base64-encoded in `gedDocuments[0].data` of
-- `/inv/customer_accounts/<account id>/product_invoices/<reference>/download`. The token and ids
-- are kept in fyde.session to skip the login while still accepted. Unverified (see README.md).

local M = {}

local API = "https://apib2c.azure.saurclient.fr"

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

local function base64url_decode(s)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  s = s:gsub("-", "+"):gsub("_", "/"):gsub("[^%w%+/]", "")
  local bits = s:gsub(".", function(c)
    local v = alphabet:find(c, 1, true) - 1
    local out = ""
    for i = 6, 1, -1 do
      out = out .. ((v >> (i - 1)) & 1)
    end
    return out
  end)
  return (bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
    if #byte ~= 8 then
      return ""
    end
    return string.char(tonumber(byte, 2))
  end))
end


local function get(path)
  local resp = fyde.http.get(API .. path, { Authorization = "Bearer " .. tostring(fyde.session.saur_token), Accept = "application/json" })
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("Logging in")
  local resp = fyde.http.post_json(API .. "/admin/v2/auth", {
    username = params.username,
    password = params.password,
    client_id = "frontjs-client",
    grant_type = "password",
    scope = "api-scope",
    isRecaptchaV3 = true,
    captchaToken = false,
  }, { Origin = "https://mon-espace.saurclient.fr", Referer = "https://mon-espace.saurclient.fr/" })
  if resp.status == 504 or resp.status >= 500 then
    error("SAUR answered HTTP " .. resp.status .. " (vendor down)")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local body = json_or_nil(resp.body) or {}
  if resp.status == 401 then
    fail(INVALID_CREDENTIALS, body.message)
  end
  -- The v2 answer's shape on success is unconfirmed: the old `token.access_token` or a plain
  -- `token` string, with the default contract either inline or from `GET /admin/v2/auth`.
  local token = type(body.token) == "table" and body.token.access_token or body.token
  if type(token) ~= "string" or token == "" then
    error("unexpected SAUR login answer (HTTP " .. resp.status .. ")")
  end
  fyde.session.saur_token = token
  local contract = body.defaultContract
  if not contract then
    local status, user = get("/admin/v2/auth")
    contract = status == 200 and type(user) == "table" and user.defaultContract or nil
  end
  if not contract then
    error("SAUR login accepted, but no default contract found in its answer")
  end
  fyde.session.saur_account = contract.customerAccountId
  fyde.session.saur_billing = contract.billingAgreementId
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local status, list
  if fyde.session.saur_token and fyde.session.saur_billing then
    status, list = get("/inv/billing_agreements/" .. fyde.session.saur_billing .. "/product_invoices")
  end
  if status == 200 and type(list) == "table" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = select(2, get("/inv/billing_agreements/" .. fyde.session.saur_billing .. "/product_invoices"))
  end

  fyde.progress.step("Downloading bills")
  for _, invoice in ipairs(type(list) == "table" and list or {}) do
    local file = select(2, get("/inv/customer_accounts/" .. tostring(fyde.session.saur_account) .. "/product_invoices/" .. tostring(invoice.reference) .. "/download"))
    local data = file and file.gedDocuments and file.gedDocuments[1] and file.gedDocuments[1].data
    local pdf = data and base64url_decode(data)
    if pdf and pdf:sub(1, 4) == "%PDF" then
      local date = tostring(invoice.settlementDate or invoice.dueDate or ""):sub(1, 10)
      fyde.save_document(date .. "_saur_" .. string.format("%.2f", tonumber(invoice.amountIncludingTaxes) or 0) .. "Eur_" .. tostring(invoice.reference) .. ".pdf", pdf, {
        name = "Facture SAUR " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "water",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
