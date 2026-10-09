-- Scraper for Pajemploi (pajemploi.urssaf.fr), Urssaf's service for parents employing a
-- child-minder: downloads the payslips ("bulletins de salaire") and the yearly tax
-- certificates ("attestations fiscales").
--
-- Ported from github.com/konnectors/cozy-konnector-pajemploi (src/auth.js, src/employer.js,
-- src/childminder.js, src/payslip.js): a session is valid when `/pajeweb/connect.htm` doesn't
-- redirect away. Login: the info home page, then `/pajeweb/logindec.htm` (a ".message"
-- mentioning "maintenance" means the vendor is down; a `.g-recaptcha` means the konnector had
-- to solve a captcha through a paid service - not available here), then `j_username`/
-- `j_password` posted to `/pajeweb/login-pajemploi.htm`; the `input#j_username` form still
-- being there means bad credentials. Employer payslips: `ajaxlistebs.jsp` (period range since
-- 01/2004), one `#tabVsTous tr[onclick]` per payslip with its `ref`/`norng` in the onclick JS,
-- each PDF served by `paje_bulletinsalaire.pdf` for that ref/norng (the konnector POSTed them;
-- fyde.http can only download with GET, so they're sent as query parameters - unconfirmed).
-- Tax certificates: one `paje_atfiempl.pdf?annee=<year>` per year offered by `atfirecap.htm`.
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.pajemploi.urssaf.fr/pajeweb"
local LOGIN_PAGE = BASE .. "/logindec.htm"

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper ported from github.com/konnectors - see README.md).
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

-- Port of cozy-konnector-libs' `signin({ formSelector })`: reads the first form matching
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

local function logged_in()
  local resp = fyde.http.get(BASE .. "/connect.htm")
  return resp.status == 200 and resp.url:find("/pajeweb/connect.htm", 1, true) ~= nil and not has(resp, "input#j_username")
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get("https://www.pajemploi.urssaf.fr/pajewebinfo/cms/sites/pajewebinfo/accueil.html")
  local page = fyde.http.get(LOGIN_PAGE)
  local message = fyde.html.select(page.body, ".message")[1]
  if message and contains(message.text, "maintenance") then
    error("Pajemploi is under maintenance (vendor down)")
  end
  if not has(page, "input#j_username, input[name='j_username']") then
    error("Pajemploi login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if has(page, ".g-recaptcha") then
    error("Pajemploi asks for a reCAPTCHA, which this scraper can't solve")
  end
  local resp = fyde.http.post_form(BASE .. "/login-pajemploi.htm", { j_username = params.username, j_password = params.password })
  if has(resp, "input#j_username") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if logged_in() then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading payslips")
  -- No clock in the sandbox: ask for a period ending far enough in the future.
  local list = fyde.http.post_form(BASE .. "/ajaxlistebs.jsp", {
    activite = "T", byAsc = "false", dtDebAnnee = "2004", dtDebMois = "01", dtFinAnnee = "2099", dtFinMois = "12",
    noIntSala = "", order = "periode", paye = "false",
  })
  for _, row in ipairs(fyde.html.select(list.body, "#tabVsTous tr[onclick]")) do
    local ref, norng = (row.attrs.onclick or ""):match("getElementById%('ref'%)%.value='([^']+)';document%.getElementById%('norng'%)%.value='([^']+)'")
    local cells = fyde.html.select(row.html, "td")
    if ref and cells[2] then
      local month, year = cells[1].text:match("(%d%d)/(%d%d%d%d)")
      local employee = trim(cells[2].text)
      save_pdf(BASE .. "/paje_bulletinsalaire.pdf?ref=" .. ref .. "&norng=" .. norng, sanitize(employee) .. "_" .. (year or "") .. "-" .. (month or "") .. ".pdf", {
        name = "Bulletin de salaire Pajemploi " .. employee .. " " .. (month or "") .. "/" .. (year or ""),
        type = "pay_sheet",
        source_category = "gov",
        source_sub_category = "family",
        subjects = { employee },
        purpose = "employment",
      })
    end
  end

  fyde.progress.step("Downloading tax certificates")
  local years = fyde.http.get(BASE .. "/atfirecap.htm")
  for _, option in ipairs(fyde.html.select(years.body, "form option")) do
    local year = option.attrs.value
    if year and year:match("^%d%d%d%d$") then
      local page = fyde.http.post_form(BASE .. "/atfirecap.htm", { annee = year })
      if page.body:find('action="/pajeweb/paje_atfiempl.pdf', 1, true) then
        save_pdf(BASE .. "/paje_atfiempl.pdf?annee=" .. year, year .. "_Attestation_fiscale.pdf", {
          name = "Attestation fiscale Pajemploi " .. year,
          type = "other_tax_document",
          source_category = "gov",
          source_sub_category = "tax",
          purpose = "attestation",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
