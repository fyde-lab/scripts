-- Scraper for SFR's fixed-line/box customer area (espace-client.sfr.fr), legacy box area:
-- downloads the box bills.
--
-- The CAS login page
-- (`www.sfr.fr/bounce?...casforcetheme=mire-sfr-et-moi`) gives the `lt` token (a `.g-recaptcha`
-- there means a captcha is required - CHALLENGE_ASKED), then `www.sfr.fr/cas/login?domain=
-- mire-sfr-et-moi&service=...` takes lt, execution=e1s1, _eventId=submit, username, password,
-- remember-me; the `#loginForm` still being shown means bad credentials. Bills:
-- `espace-client.sfr.fr/facture-fixe/consultation` (being redirected elsewhere means not
-- logged in), the latest in `#lastFacture a.sr-chevron`, older ones linked from
-- `table.sr-multi-payment tbody tr` (2nd cell) to pages with their own `a.sr-chevron`. See also
-- `sfr`, the newer browser-based port. Unverified (see README.md).

local M = {}

local BOUNCE_URL = "https://www.sfr.fr/bounce?target=//www.sfr.fr/sfr-et-moi/bounce.html&casforcetheme=mire-sfr-et-moi&mire_layer"
local CAS_URL = "https://www.sfr.fr/cas/login?domain=mire-sfr-et-moi&service=https://www.sfr.fr/accueil/j_spring_cas_security_check"
local CLIENT = "https://espace-client.sfr.fr"
local BILLS_URL = CLIENT .. "/facture-fixe/consultation"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BOUNCE_URL)
  if has(page, ".g-recaptcha") then
    error("SFR asks for a captcha (CHALLENGE_ASKED)")
  end
  local lt = fyde.html.select(page.body, "input[name='lt']")[1]
  if not lt then
    error("SFR login form (lt token) not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(CAS_URL, {
    lt = lt.attrs.value or "",
    execution = "e1s1",
    _eventId = "submit",
    username = params.username,
    password = params.password,
    ["remember-me"] = "on",
    identifier = "",
  })
  if has(resp, "#loginForm") then
    fail(INVALID_CREDENTIALS)
  end
end

local function bill_from(html, container, label)
  local block = fyde.html.select(html, container)[1]
  local link = block and fyde.html.select(block.html, "a.sr-chevron")[1]
  if not (link and link.attrs.href) then
    return
  end
  local date = (block.text:match("(%d%d/%d%d/%d%d%d%d)") or label)
  local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
  save_pdf(CLIENT .. link.attrs.href, (y and (y .. m .. d) or sanitize(date)) .. "_SFR_box.pdf", {
    name = "Facture SFR box " .. date,
    type = "invoice",
    category = "housing",
    subcategory = "internet",
  })
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if page.url:find("/facture-fixe/consultation", 1, true) and has(page, "#lastFacture, table.sr-multi-payment") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
    if not page.url:find("/facture-fixe/consultation", 1, true) then
      fail(INVALID_CREDENTIALS, "redirected away from the bills page after login")
    end
  end

  fyde.progress.step("Downloading bills")
  bill_from(page.body, "#lastFacture", "derniere")
  for _, row in ipairs(fyde.html.select(page.body, "table.sr-multi-payment tbody tr")) do
    local cells = fyde.html.select(row.html, "td")
    local link = cells[2] and fyde.html.select(cells[2].html, "a")[1]
    if link and link.attrs.href then
      local detail = fyde.http.get(CLIENT .. link.attrs.href)
      bill_from(detail.body, ".sr-container-wrapper-m", trim(cells[1].text))
    end
  end
  fyde.progress.step("Done")
end

return M
