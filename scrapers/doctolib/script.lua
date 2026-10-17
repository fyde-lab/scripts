-- Scraper for Doctolib (doctolib.fr), the medical appointment platform: downloads the
-- documents shared with the patient (prescriptions, reports...).
--
-- `/sessions/new` gives the
-- `meta[name=csrf-token]`, then `/login.json` takes a JSON body (remember, kind=patient,
-- username, password) with that `x-csrf-token` - HTTP 401 means bad credentials. Documents
-- come from `/account/documents.json?page=1` (`documents[]` with `url`, `name`, `shared_at`,
-- `created_by`). Doctolib now adds a second factor (e-mail/SMS code) for new devices, which
-- the original implementation predates: if the login answer asks for one, the code is asked and submitted to
-- the same endpoint (field names unconfirmed). Unverified (see README.md).

local M = {}

local BASE = "https://www.doctolib.fr"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains
local ask_code = helpers.ask_code
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function documents()
  local resp = fyde.http.get(BASE .. "/account/documents.json?page=1", { Accept = "application/json" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  return data and data.documents
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/sessions/new")
  local csrf = fyde.html.select(page.body, "meta[name='csrf-token']")[1]
  if not csrf then
    error("Doctolib login page (csrf-token) not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local headers = { ["x-csrf-token"] = csrf.attrs.content or "", Referer = BASE .. "/sessions/new", Accept = "application/json" }
  local resp = fyde.http.post_json(BASE .. "/login.json", {
    remember = true,
    kind = "patient",
    username = params.username,
    password = params.password,
  }, headers)
  if resp.status == 401 then
    fail(INVALID_CREDENTIALS)
  end
  local body = json_or_nil(resp.body) or {}
  if body.otp_required or body.two_factor_required or contains(resp.body, "otp") and resp.status >= 400 then
    local code = ask_code("Code de vérification Doctolib")
    local otp = fyde.http.post_json(BASE .. "/login.json", { remember = true, kind = "patient", username = params.username, password = params.password, otp = code }, headers)
    if otp.status >= 400 then
      fail(MFA_FAILED, "HTTP " .. otp.status)
    end
  elseif resp.status >= 400 then
    error("Doctolib login answered HTTP " .. resp.status)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local docs = documents()
  if docs then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    docs = documents() or {}
  end

  fyde.progress.step("Downloading documents")
  for _, doc in ipairs(docs) do
    if doc.url then
      save_pdf(BASE .. doc.url, tostring(doc.shared_at) .. "_" .. tostring(doc.name) .. "_" .. tostring(doc.created_by) .. ".pdf", {
        name = tostring(doc.name),
        type = "medical_document",
        category = "health",
        subcategory = "care",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
