-- Scraper for Viasanté Mutuelle's member area (adherent.viasante.fr, formerly
-- adherent.mutuelle-viasante.fr): downloads the mail documents (reimbursement statements,
-- certificates...) of every contract.
--
-- The original JSON login
-- (`POST /api/identity/login` with {userName, password}) is gone: `GET /api/identity/login` now
-- redirects to an IdentityServer page (`/identity/account/login`, `form#login-form` with
-- `username`/`password`/`button=login`) that answers a wrong login with "Aucun compte n'est
-- associé à cet identifiant ou le mot de passe entré est incorrect" (checked live, with made-up
-- credentials), and a good one with a `form_post` to `/signin-oidc` (unconfirmed). Then
-- `/api/adherent/contrats` lists the contracts (numContrat, souscripteur.numPers), and
-- `/api/adherent/courriers/list?startDate=..&endDate=..` (headers X-NumContrat/X-NumPers) the
-- documents (id, fileName, type, creationDate), each served by `/api/adherent/courriers/
-- document?fileName=..&numContrat=..&codeCentreGestion=VIASANTE&docId=..&type=..`. The
-- original implementation also matched payments to the "PRESTATIONS" mails as bill metadata - not ported.
-- Unverified (see README.md).

local M = {}

local BASE = "https://adherent.viasante.fr"
local LOGIN_FORM = "form#login-form"
local BAD_CREDENTIALS = { "Aucun compte n’est associé", "Aucun compte n'est associé", "mot de passe entré est incorrect" }

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains_any = helpers.contains_any
local url_encode = helpers.url_encode
local submit_form = helpers.submit_form
local has = helpers.has
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function contracts()
  local resp = fyde.http.get(BASE .. "/api/adherent/contrats", { Accept = "application/json" })
  local data = resp.status == 200 and json_or_nil(resp.body)
  return data and data.contrats
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/api/identity/login")
  if not has(page, LOGIN_FORM .. " input[name='password']") then
    error("Viasanté login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, { username = params.username, password = params.password, button = "login" })
  if contains_any(resp.body, BAD_CREDENTIALS) or has(resp, LOGIN_FORM .. " input[name='password']") then
    fail(INVALID_CREDENTIALS)
  end
  -- response_mode=form_post: the identity server answers with a self-submitting form carrying
  -- the authorization code to /signin-oidc, which a browser would post on its own.
  if has(resp, "form[action*='signin-oidc']") then
    submit_form(resp, "form[action*='signin-oidc']", {})
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local list = contracts()
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = contracts()
    if not list then
      fail(INVALID_CREDENTIALS, "contracts not reachable after login")
    end
  end

  fyde.progress.step("Downloading documents")
  for _, contract in ipairs(list) do
    local number = tostring(math.tointeger(tonumber(contract.numContrat)) or contract.numContrat)
    local person = tostring(contract.souscripteur and contract.souscripteur.numPers or "")
    local headers = { ["X-NumContrat"] = number, ["X-NumPers"] = person, Accept = "application/json" }
    local docs = json_or_nil(fyde.http.get(BASE .. "/api/adherent/courriers/list?startDate=2000-01-01T00:00:00.000Z&endDate=2099-12-31T00:00:00.000Z", headers).body) or {}
    for _, doc in ipairs(docs) do
      local date = tostring(doc.creationDate):sub(1, 10)
      save_pdf(BASE .. "/api/adherent/courriers/document?fileName=" .. url_encode(doc.fileName) .. "&numContrat=" .. number
        .. "&codeCentreGestion=VIASANTE&docId=" .. tostring(doc.id) .. "&type=" .. url_encode(doc.type),
        date .. "_viasante_" .. tostring(doc.id) .. ".pdf", {
          name = "Viasanté " .. tostring(doc.type) .. " " .. date,
          type = doc.type == "PRESTATIONS" and "reimbursement_statement" or "medical_document",
          category = "health",
          subcategory = "complementary_health",
        }, { ["Content-Type"] = "application/json" })
    end
  end
  fyde.progress.step("Done")
end

return M
