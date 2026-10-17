-- Scraper for Luko (luko.eu), the home insurer: downloads the invoices and contract documents.
--
-- Everything goes through the GraphQL
-- endpoint `cerbere.luko.eu/v1?lang=fr` - the `Login` mutation (credentials {email, password})
-- answers `login.ok` and a user whose `connection.jwtToken` authenticates the session (the
-- original implementation relied on the cookie it sets; the token is also sent as a bearer here), then
-- `GetPreviousInvoices` (`user.informationsInvoices.invoices[]`: date, amount in cents,
-- downloadUrl) and `GetContractDocuments` (`contracts[0].documents[]` and each user's
-- `insuranceDocuments[]`: title, url). Luko stopped its activity in 2023 (portfolio taken over
-- by Allianz Direct), so this API is likely gone. Unverified (see README.md).

local M = {}

local API = "https://cerbere.luko.eu/v1?lang=fr"

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
local read_form = helpers.read_form

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

local function gql(operation, query, variables)
  local headers = { Accept = "application/json" }
  if fyde.session.luko_jwt then
    headers.Authorization = "Bearer " .. fyde.session.luko_jwt
  end
  local resp = fyde.http.post_json(API, { operationName = operation, variables = variables or {}, query = query }, headers)
  return json_or_nil(resp.body) or {}, resp.status
end

local INVOICES = "query GetPreviousInvoices{\nuser{\ninformationsInvoices{\ninvoices{\ndescription\ndate\namount\namountWithoutDiscount\nstatus\ndownloadUrl\nfailureReason\n}\n}\n}\n}\n"
local DOCUMENTS = "query GetContractDocuments{\ncontracts{\nid\nname\nproductCode\nstate\ndocuments{\nicon\ntitle\ndescription\nurl\ntrackingCode\n}\nusers {\nid\nfirstname\nlastname\ninsuranceRole\ninsuranceDocuments{\nicon\ntitle\ndescription\nurl\ntrackingCode\n}\n}\n}\n}\n"

local function invoices()
  local data = gql("GetPreviousInvoices", INVOICES)
  local user = data.data and data.data.user
  return user and user.informationsInvoices and user.informationsInvoices.invoices
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get("https://fr.luko.eu/")
  fyde.log.info("LOGIN_PAGE_FOUND")
  local data, status = gql("Login", "mutation Login($credentials: credentials!) {\n  login(cred: $credentials) {\nok\nuser {\nid\nemail\nconnection {\njwtToken\n}\n }\n}\n}\n",
    { credentials = { email = params.username, password = params.password } })
  local result = data.data and data.data.login
  if not (result and result.ok) then
    if data.errors or status == 401 or (result and result.ok == false) then
      fail(INVALID_CREDENTIALS)
    end
    error("unexpected Luko login answer (HTTP " .. tostring(status) .. ")")
  end
  fyde.session.luko_jwt = result.user and result.user.connection and result.user.connection.jwtToken
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local list = invoices()
  if list then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    list = invoices() or {}
  end

  fyde.progress.step("Downloading invoices")
  for _, invoice in ipairs(list) do
    if invoice.downloadUrl then
      local date = tostring(invoice.date):sub(1, 10)
      save_pdf(invoice.downloadUrl, date .. "_luko_" .. string.format("%.2f", (tonumber(invoice.amount) or 0) / 100) .. "EUR.pdf", {
        name = "Facture Luko " .. date,
        type = "contract",
        category = "housing",
        subcategory = "home_insurance",
      })
    end
  end

  fyde.progress.step("Downloading contract documents")
  local data = gql("GetContractDocuments", DOCUMENTS)
  local contract = data.data and data.data.contracts and data.data.contracts[1] or {}
  local docs = {}
  for _, doc in ipairs(contract.documents or {}) do
    docs[#docs + 1] = doc
  end
  for _, user in ipairs(contract.users or {}) do
    for _, doc in ipairs(user.insuranceDocuments or {}) do
      docs[#docs + 1] = doc
    end
  end
  for _, doc in ipairs(docs) do
    if doc.url then
      save_pdf(doc.url, "luko_" .. sanitize(doc.title) .. ".pdf", {
        name = tostring(doc.title),
        type = "contract",
        category = "housing",
        subcategory = "home_insurance",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
