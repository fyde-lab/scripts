-- Scraper for E.Leclerc Drive (leclercdrive.fr): downloads the order forms ("bons de
-- commande") of past orders.
--
-- The original implementation logged in through a JSONP
-- call to `secure.leclercdrive.fr/drive/connecter.ashz` and solved the Datadome captcha that
-- answered it through a paid service. Every leclercdrive.fr host now answers plain HTTP with a
-- Datadome captcha page (HTTP 403), while a real webview passes its passive check, so the whole
-- flow runs in `fyde.browser` (captcha-delivery.com allowed for Datadome's own scripts). The
-- portal's header popin (confirmed against the live site): "Se connecter"
-- (`a.aWPAD346_NonConnecte`) reveals `input.txtWCLD312_Login`, "Continuer"
-- (`button.btnWCLD312_Continuer`) then reveals `input.txtWCLD312_Mdp` and "Me connecter"
-- (`button.btnWCLD312_Valider`); bad credentials un-hide `div.divWCLD312_IdIncorrects` ("Votre
-- login et/ou votre mot de passe est incorrect"), and a logged-in page un-hides
-- `div.divWPAD346_Connecte` (and its dataLayer says `"Client_EstConnecte":"oui"`). The popin
-- also holds an hCaptcha (`div.divWCCD042_Captcha`) the site only un-hides after repeated
-- failures - not solvable here. Orders, unverified (no account): "Accéder à Mon compte"
-- (`aiguillage.aspx?iPage=2`) leads to the store's account pages, whose first
-- `a[href*='mes-commandes']` link lists orders per year (`select[id*='ddlFiltreAnnees']`, an
-- auto-postback select); each `div[class*='ResumeCommande']` has the order number, date and an
-- `a[href*='bon-de-commande.aspx']` PDF, downloaded through the webview. See README.md.

local M = {}

local BASE = "https://www.leclercdrive.fr"
local ACCOUNT_URL = BASE .. "/aiguillage.aspx?iPage=2"
local OPEN_POPIN = "a.aWPAD346_NonConnecte"
local LOGIN_FIELD = "input.txtWCLD312_Login"
local CONTINUE = "button.btnWCLD312_Continuer"
local PASSWORD_FIELD = "input.txtWCLD312_Mdp"
local SUBMIT = "button.btnWCLD312_Valider"
local BAD_CREDENTIALS = "div.divWCLD312_IdIncorrects:not(.masquer), div.divWCLD312_MaxTentatives:not(.masquer)"
local CAPTCHA = "div.divWCCD042_Captcha:not(.masquer)"
local LOGGED_IN = "div.divWPAD346_Connecte:not(.masquer)"
local LOGGED_OUT = "div.divWPAD346_NonConnecte:not(.masquer)"
local YEAR_SELECT = "select[id*='ddlFiltreAnnees']"
local ORDER = "div[id*='_upHistoriqueCommandes'] div[class*='ResumeCommande']"

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

local function sleep(ms)
  pcall(function()
    fyde.browser:wait_for("#__fyde_scraper_sleep__", ms)
  end)
end

local function page_html()
  local ok, html = pcall(function()
    return fyde.browser:html()
  end)
  return ok and html or ""
end

local function logged_in(html)
  return has(html, LOGGED_IN) or contains(html, '"Client_EstConnecte":"oui"')
end

-- Opens `url` and waits (up to `timeout_ms`, past Datadome's check) for one of `selectors` to
-- show up; returns the page's markup either way.
local function open(url, selectors, timeout_ms)
  fyde.browser:open(url)
  local html = ""
  for _ = 1, math.ceil(timeout_ms / 1000) do
    sleep(1000)
    html = page_html()
    for _, selector in ipairs(selectors) do
      if has(html, selector) then
        return html
      end
    end
  end
  return html
end

-- Waits (up to `timeout_ms`) for `selector` to be shown, i.e. present without the site's
-- `masquer` class.
local function wait_shown(selector, timeout_ms)
  for _ = 1, math.ceil(timeout_ms / 500) do
    local html = page_html()
    for _, el in ipairs(fyde.html.select(html, selector)) do
      if not (" " .. (el.attrs.class or "") .. " "):find(" masquer ", 1, true) then
        return true
      end
    end
    sleep(500)
  end
  return false
end

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Logging in")
  fyde.browser:click(OPEN_POPIN)
  sleep(1000)
  fyde.browser:fill(LOGIN_FIELD, params.username)
  fyde.browser:click(CONTINUE)
  if not wait_shown(PASSWORD_FIELD, 20000) then
    local html = page_html()
    if has(html, BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS, "e-mail address rejected")
    end
    error("Leclerc Drive login: no password field after entering the e-mail address")
  end
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT)
  for _ = 1, 30 do
    sleep(1000)
    local html = page_html()
    if has(html, BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    elseif has(html, CAPTCHA) then
      fyde.save_document("after.html", html, {name="x", type="invoice", source_category="alimentation", purpose="invoice"}) -- DEBUG
      error("Leclerc Drive asks for an hCaptcha before logging in (too many attempts?)")
    elseif logged_in(html) and not has(html, PASSWORD_FIELD .. ":not(.masquer)") then
      return
    end
  end
  fyde.save_document("after.html", page_html(), {name="x", type="invoice", source_category="alimentation", purpose="invoice"}) -- DEBUG
  error("Leclerc Drive login did not complete (no account header after submitting)")
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local html = open(BASE, { LOGGED_IN, LOGGED_OUT }, 45000)
  if logged_in(html) then
    fyde.log.info("ALREADY_LOGGED_IN")
  elseif has(html, LOGIN_FIELD) then
    login(params)
  else
    error("Leclerc Drive login form not found (Datadome check not passed?)")
  end

  fyde.progress.step("Downloading order forms")
  local account = open(ACCOUNT_URL, { "a[href*='mes-commandes']" }, 30000)
  local orders_link = fyde.html.select(account, "a[href*='mes-commandes']")[1]
  if not orders_link then
    error("no 'mes commandes' link on the Leclerc Drive account page")
  end
  local orders_url = absolute(BASE, orders_link.attrs.href)
  local orders = open(orders_url, { ORDER, YEAR_SELECT }, 30000)
  local years = {}
  for _, option in ipairs(fyde.html.select(orders, YEAR_SELECT .. " option")) do
    years[#years + 1] = option.attrs.value
  end
  if #years == 0 then
    years = { false }
  end
  for _, year in ipairs(years) do
    if year then
      fyde.browser:fill(YEAR_SELECT, year)
      sleep(5000)
    end
    for _, order in ipairs(fyde.html.select(page_html(), ORDER)) do
      local number = fyde.html.select(order.html, "a[id*='NumeroCommande']")[1]
      local info = fyde.html.select(order.html, "span[id*='_lblCommandeInfo']")[1]
      local pdf = fyde.html.select(order.html, "a[href*='bon-de-commande.aspx']")[1]
      local ref = sanitize(number and number.text or "")
      if pdf and pdf.attrs.href then
        local d, m, y = (info and info.text or ""):match("(%d%d)/(%d%d)/(%d%d%d%d)")
        local ok, bytes = pcall(function()
          return fyde.browser:download("a[href='" .. pdf.attrs.href:gsub("'", "\\'") .. "']", 60000)
        end)
        if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
          fyde.save_document((y and (y .. "-" .. m .. "-" .. d) or "commande") .. "_" .. ref .. "_leclercdrive.pdf", bytes, {
            name = "Commande Leclerc Drive " .. (y and (d .. "/" .. m .. "/" .. y) or ref),
            type = "invoice",
            source_category = "alimentation",
            purpose = "invoice",
          })
        else
          fyde.log.warn("no order form PDF for order " .. ref .. ": " .. tostring(ok and "not a PDF" or bytes))
        end
      end
    end
  end
  fyde.progress.step("Done")
end

return M
