-- Scraper for Darty (darty.com), the electronics/home-appliance retailer: downloads the bills
-- of purchased products.
--
-- A
-- session is valid when `/webapp/wcs/stores/controller/ec/products` doesn't redirect to
-- `/espace_client/connexion`. Login: GET then POST `/espace_client/connexion` (email/password,
-- with that page as referer) - HTTP 401 means bad credentials. Products: `ec/products/table`
-- (`?filtre=0&pagination=<n>`, page count from the last `a[data-page]`), one `.item_product`
-- per product with its `data-omniture-*` attributes (date, price, codic) and a
-- `a[data-tracking="bill-product"]` bill link under `/webapp/wcs/stores/controller/`; products
-- whose bill isn't generated yet have an `a[data-token]` (data-num/time/token) to POST to
-- `FactureMagasinGeneration` first, then the page is reloaded. Unverified (see README.md).

local M = {}

local ROOT = "https://www.darty.com"
local LOGIN_URL = ROOT .. "/espace_client/connexion"
local CONTROLLER = ROOT .. "/webapp/wcs/stores/controller/"
local HEADERS = { Accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", ["Accept-Language"] = "fr,fr-FR;q=0.8" }

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
local trim = helpers.trim
local sanitize = helpers.sanitize
local has = helpers.has

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL, HEADERS)
  if page.status >= 400 or not has(page, "input[type='password'], input[name='password']") then
    error("Darty login form not found on " .. page.url .. " (HTTP " .. page.status .. ")")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(LOGIN_URL, { email = params.username, password = params.password }, {
    referer = LOGIN_URL,
    Accept = HEADERS.Accept,
  })
  if resp.status == 401 or resp.url:find("/espace_client/connexion", 1, true) and has(resp, "input[name='password']") then
    fail(INVALID_CREDENTIALS, "HTTP " .. resp.status)
  end
end

local function table_page(n)
  return fyde.http.get(CONTROLLER .. "ec/products/table?filtre=0&pagination=" .. n, HEADERS)
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local check = fyde.http.get(CONTROLLER .. "ec/products", HEADERS)
  if check.status == 200 and not check.url:find("/espace_client/connexion", 1, true) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Downloading bills")
  local first = table_page(1)
  local pages = 1
  for _, a in ipairs(fyde.html.select(first.body, "a[data-page]")) do
    pages = math.max(pages, tonumber(a.attrs["data-page"]) or 1)
  end
  for n = 1, pages do
    local page = n == 1 and first or table_page(n)
    local generated = false
    for _, product in ipairs(fyde.html.select(page.body, ".item_product")) do
      local gen = fyde.html.select(product.html, "a[data-token]")[1]
      if gen then
        fyde.http.post_form(CONTROLLER .. "FactureMagasinGeneration?numCmd=" .. (gen.attrs["data-num"] or "")
          .. "&placeOrderTime=" .. (gen.attrs["data-time"] or "") .. "&token=" .. (gen.attrs["data-token"] or ""), {})
        generated = true
      end
    end
    if generated then
      page = table_page(n)
    end
    for _, product in ipairs(fyde.html.select(page.body, ".item_product")) do
      local bill = fyde.html.select(product.html, "a[data-tracking='bill-product']")[1]
      local href = bill and bill.attrs.href or ""
      if href:find("^/webapp/wcs/stores/controller/") then
        local date = (product.attrs["data-omniture-date"] or ""):match("(%d%d/%d%d/%d%d%d%d)") or ""
        local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
        local label = fyde.html.select(product.html, "a[href^='/nav/codic/']")[1]
        save_pdf(ROOT .. href, (y and (y .. "-" .. m .. "-" .. d) or "") .. "-" .. sanitize(label and label.text or (product.attrs["data-omniture-codic"] or "produit")) .. ".pdf", {
          name = "Facture Darty " .. (label and trim(label.text) or ""),
          type = "invoice",
          category = "shopping",
          subcategory = "online",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
