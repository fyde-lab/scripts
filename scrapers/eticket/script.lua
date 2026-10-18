-- Scraper for e-Ticket by Qiis (eticket.qiis.fr), a school canteen/after-school billing
-- service: downloads the invoices and the family's documents.
--
-- `eticket-app.qiis.fr/api/v1/auth/
-- login?login=..&password=..&requestFirebaseCustomToken=true` answers `status: "Success"` and a
-- Firebase custom token (anything else = bad credentials), exchanged for an ID token at
-- Google's `identitytoolkit/v3/relyingparty/verifyCustomToken` (with the app's public API key).
-- The original implementation then spoke Firebase's realtime-database websocket protocol; this sandbox has no
-- websocket, so the same database is read through Firebase's REST API instead
-- (`qiis-eticket-production.firebaseio.com/<path>.json?auth=<ID token>`), with the
-- `metaManagerId`/`familyId` taken from the ID token's claims (what the websocket `auth`
-- answer returned): `/meta/<m>/family/<f>/invoice` (entries with an `attachment.url`) and
-- `/meta/<m>/family/<f>/document/native` (`dlUrl`). Tokens expire, so every run logs in again
-- unless the ID token kept in fyde.session still works. Unverified (see README.md).

local M = {}

local API_KEY = "AIzaSyDERcRUv900BN5lb4TIAFooo2aoqu4T32c"
local DB = "https://qiis-eticket-production.firebaseio.com"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local url_encode = helpers.url_encode
local base64url_decode = helpers.base64url_decode
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function claims(id_token)
  return json_or_nil(base64url_decode(id_token:match("^[^.]+%.([^.]+)") or "")) or {}
end

local function query(path, token)
  local resp = fyde.http.get(DB .. path .. ".json?auth=" .. token)
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("logging_in")
  local resp = fyde.http.get("https://eticket-app.qiis.fr/api/v1/auth/login?login=" .. url_encode(params.username)
    .. "&password=" .. url_encode(params.password) .. "&requestFirebaseCustomToken=true")
  if resp.status >= 500 then
    error("e-Ticket login answered HTTP " .. resp.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local body = json_or_nil(resp.body) or {}
  if body.status ~= "Success" or not body.firebaseCustomToken then
    fail(INVALID_CREDENTIALS, tostring(body.status))
  end
  local verify = fyde.http.post_json("https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyCustomToken?key=" .. API_KEY,
    { returnSecureToken = true, token = body.firebaseCustomToken })
  local id = (json_or_nil(verify.body) or {}).idToken
  if not id then
    error("could not exchange the e-Ticket token (HTTP " .. verify.status .. ")")
  end
  fyde.session.eticket_id_token = id
  return id
end

function M.run(params)
  fyde.progress.step("checking_session")
  local token = fyde.session.eticket_id_token
  local auth = token and claims(token) or {}
  local base = auth.metaManagerId and ("/meta/" .. auth.metaManagerId .. "/family/" .. tostring(auth.familyId))
  if base and query(base .. "/invoice", token) == 200 then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    token = login(params)
    auth = claims(token)
    if not auth.metaManagerId then
      error("the e-Ticket token carries no metaManagerId/familyId claims")
    end
    base = "/meta/" .. auth.metaManagerId .. "/family/" .. tostring(auth.familyId)
  end

  fyde.progress.step("downloading_documents")
  local _, invoices = query(base .. "/invoice", token)
  for _, invoice in pairs(type(invoices) == "table" and invoices or {}) do
    if type(invoice) == "table" and invoice.attachment and invoice.attachment.url then
      local body = invoice.body or {}
      local date = tostring(body.invoiceDate or ""):sub(1, 10)
      save_pdf(invoice.attachment.url, date .. "_eTickets_" .. tostring((tonumber(body.totalAmountTTCCent) or 0) / 100) .. "EUR_" .. tostring(body.reference) .. ".pdf", {
        name = tostring(body.label or "Facture e-Ticket"),
        type = "invoice",
        category = "family",
        subcategory = "childcare_school",
      })
    end
  end

  local _, documents = query(base .. "/document/native", token)
  for _, doc in pairs(type(documents) == "table" and documents or {}) do
    if type(doc) == "table" and doc.dlUrl then
      save_pdf(doc.dlUrl, tostring(doc.name) .. ".pdf", {
        name = tostring(doc.name),
        category = "family",
        subcategory = "childcare_school",
      })
    end
  end
  fyde.progress.step("done")
end

return M
