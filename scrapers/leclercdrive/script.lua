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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local contains = helpers.contains
local sanitize = helpers.sanitize
local url_encode = helpers.url_encode
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("logging_in")
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
  fyde.progress.step("checking_session")
  local home = fyde.http.get(BASE)
  local mag = home.url:match("[?&]mag=([^&]+)")
  if mag then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    mag = login(params)
  end

  fyde.progress.step("downloading_documents")
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
  fyde.progress.step("done")
end

return M
