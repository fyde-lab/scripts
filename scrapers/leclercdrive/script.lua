-- Scraper for E.Leclerc Drive (leclercdrive.fr): downloads the order forms ("bons de
-- commande") of past orders.
--
-- A session is valid when the
-- home page redirects to a URL carrying the user's store (`?mag=<id>`). Login is a JSONP call:
-- `secure.leclercdrive.fr/drive/connecter.ashz?callbackJsonp=...&d={"sLogin":..,
-- "sMotDePasse":..,"fResterConnecte":true}`, whose `objDonneesReponse.iTypeConnexion` is -1 for
-- bad credentials and whose `sNoPL` is the store; a Datadome captcha may answer instead (the
-- original implementation solved it through a paid service - not possible here). The store's site URL comes
-- from `api-pointsretrait.leclercdrive.fr/.../PointsRetraitParNoPointLivraison/na/drive/<mag>`
-- (`sUrlSiteCourses`), whose first `a[href*='mes-commandes']` link lists orders per year (the
-- page's form re-posted with each `select[id*='ddlFiltreAnnees']` option); each
-- `div[class*='ResumeCommande']` has the order number, date, amount and an
-- `a[href*='bon-de-commande.aspx']` PDF. Unverified (see README.md).

local M = {}

local BASE = "https://www.leclercdrive.fr"

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

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function login(params)
  fyde.progress.step("Logging in")
  fyde.http.get(BASE)
  fyde.log.info("LOGIN_PAGE_FOUND")
  local payload = fyde.json.encode({ sLogin = params.username, sMotDePasse = params.password, fResterConnecte = true })
  local resp = fyde.http.get("https://secure.leclercdrive.fr/drive/connecter.ashz?callbackJsonp=jQuery18303470315301443705_1&d=" .. url_encode(payload))
  if contains(resp.body, "captcha") or contains(resp.body, "datado") then
    error("Leclerc Drive answered with a Datadome captcha")
  end
  local data = json_or_nil(resp.body:match("%((.*)%)") or "")
  local details = data and data.objDonneesReponse
  if not details then
    error("unexpected Leclerc Drive login answer (HTTP " .. resp.status .. ")")
  end
  if details.iTypeConnexion == -1 then
    fail(INVALID_CREDENTIALS)
  end
  return tostring(details.sNoPL)
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local home = fyde.http.get(BASE)
  local mag = home.url:match("[?&]mag=([^&]+)")
  if mag then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    mag = login(params)
  end

  fyde.progress.step("Downloading order forms")
  local details = json_or_nil(fyde.http.get("https://api-pointsretrait.leclercdrive.fr/API_PointsRetrait/ApiPointsRetrait/PointsRetraitParNoPointLivraison/na/drive/" .. mag).body) or {}
  local store = details.sReponse and details.sReponse[1] and details.sReponse[1].sUrlSiteCourses
  if not store then
    error("could not find the Leclerc Drive store site")
  end
  local store_page = fyde.http.get(store)
  local orders_link = fyde.html.select(store_page.body, "a[href*='mes-commandes']")[1]
  if not orders_link then
    error("no 'mes commandes' link on the store site")
  end
  local orders_url = absolute(store_page.url, orders_link.attrs.href)
  local orders = fyde.http.get(orders_url)
  local year_select = fyde.html.select(orders.body, "select[id*='ddlFiltreAnnees']")[1]
  for _, option in ipairs(fyde.html.select(orders.body, "select[id*='ddlFiltreAnnees'] option")) do
    local year_page = submit_form(orders, "form", { [year_select.attrs.name] = option.attrs.value })
    for _, order in ipairs(fyde.html.select(year_page.body, "div[id*='_upHistoriqueCommandes'] div[class*='ResumeCommande']")) do
      local pdf = fyde.html.select(order.html, "a[href*='bon-de-commande.aspx']")[1]
      local number = fyde.html.select(order.html, "a[id*='NumeroCommande']")[1]
      local info = fyde.html.select(order.html, "span[id*='_lblCommandeInfo']")[1]
      if pdf and pdf.attrs.href then
        local d, m, y = (info and info.text or ""):match("(%d%d)/(%d%d)/(%d%d%d%d)")
        save_pdf(absolute(orders_url, pdf.attrs.href), (y and (y .. "-" .. m .. "-" .. d) or "commande") .. "_" .. sanitize(number and number.text or "") .. "_leclercdrive.pdf", {
          name = "Commande Leclerc Drive " .. (y and (d .. "/" .. m .. "/" .. y) or ""),
          type = "invoice",
          category = "shopping",
          subcategory = "groceries",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
