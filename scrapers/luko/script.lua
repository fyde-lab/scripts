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

-- A `kind:value` subject for fyde.save_document's `subjects`: who or what the document concerns
-- when the account covers several (`person`, `line`, `account`, `contract`, `place`, `vehicle`
-- or `trip`). The value is lowercased with runs of spaces/punctuation turned into "-"; nil for a
-- blank value, which a `subjects` list simply skips.
local function subject(kind, value)
  local slug = trim(value or ""):lower():gsub("[%s%p]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return nil
  end
  return kind .. ":" .. slug
end

-- Masks all but the last `keep` characters of an identifier (phone number, IBAN, contract
-- number...), enough to tell them apart without spelling them out in a subject.
local function mask(value, keep)
  value = (value or ""):gsub("%s", "")
  if #value <= keep then
    return value
  end
  return string.rep("x", #value - keep) .. value:sub(-keep)
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
