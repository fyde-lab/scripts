-- Scraper for Stickers Discount (stickers-discount.com), a sticker printing shop: downloads
-- order invoices.
--
-- Login posts
-- `form[name="formconnex"]` (identifiant/pass/envoi_newsletter=Connexion) from
-- `.../mon-compte.php`; logged in shows an `a[href='logout.php']` link. Invoices: the
-- `tr.tableauPbeige` rows of `stickers-discount-mes-commandes.php` (invoice link and number,
-- date, order number, amount). Unverified (see README.md).

local M = {}

local BASE = "https://www.stickers-discount.com/impression-stickers-autocollant"
local ORDERS_URL = BASE .. "/stickers-discount-mes-commandes.php"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local trim = helpers.trim
local sanitize = helpers.sanitize
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/mon-compte.php")
  if not has(page, "form[name='formconnex']") then
    error("Stickers Discount login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form[name='formconnex']", { identifiant = params.username, pass = params.password, envoi_newsletter = "Connexion" })
  if not has(resp, "a[href='logout.php']") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if has(page, "a[href='logout.php']") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  for _, row in ipairs(fyde.html.select(page.body, "tr.tableauPbeige")) do
    local link = fyde.html.select(row.html, "td a")[1]
    local cells = fyde.html.select(row.html, "td")
    if link and link.attrs.href then
      local date = cells[2] and trim(cells[2].text) or ""
      save_pdf(BASE .. "/" .. link.attrs.href, sanitize(date) .. "_" .. sanitize(trim(link.text)) .. ".pdf", {
        name = "Facture Stickers Discount " .. trim(link.text),
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
