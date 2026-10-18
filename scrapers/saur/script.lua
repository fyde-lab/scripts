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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local base64url_decode = helpers.base64url_decode
local json_or_nil = helpers.json_or_nil


local function get(path)
  local resp = fyde.http.get(API .. path, { Authorization = "Bearer " .. tostring(fyde.session.saur_token), Accept = "application/json" })
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("logging_in")
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
  fyde.progress.step("checking_session")
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

  fyde.progress.step("downloading_documents")
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
  fyde.progress.step("done")
end

return M
