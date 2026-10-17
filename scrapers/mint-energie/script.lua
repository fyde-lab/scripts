-- Scraper for Mint Énergie's customer area (mint-energie.com): downloads the bills.
--
-- An ASP.NET login posting the
-- page's `form` (TB_Login/TB_Password/BT_Connexion) from `/Pages/Connexion/connexion.aspx`;
-- logged in shows `#header1_LB_Exit`. Bills: the `.factulist` entries of
-- `/Pages/Compte/informations_paiement.aspx` (`div.colA b` date, `div.colB b` amount,
-- `div.colC a` PDF). Unverified (see README.md).

local M = {}

local BASE = "https://www.mint-energie.com"
local BILLS_URL = BASE .. "/Pages/Compte/informations_paiement.aspx"

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
local absolute = helpers.absolute
local submit_form = helpers.submit_form

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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE .. "/Pages/Connexion/connexion.aspx")
  if not has(page, "input[name='TB_Password'], input[id$='TB_Password']") then
    error("Mint Énergie login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form", { TB_Login = params.username, TB_Password = params.password, BT_Connexion = "se connecter" })
  if not has(resp, "#header1_LB_Exit") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BILLS_URL)
  if has(page, "#header1_LB_Exit") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(BILLS_URL)
  end

  fyde.progress.step("Downloading bills")
  for _, bill in ipairs(fyde.html.select(page.body, ".factulist")) do
    local link = fyde.html.select(bill.html, "div.colC a")[1]
    local date = fyde.html.select(bill.html, "div.colA b")[1]
    local amount = fyde.html.select(bill.html, "div.colB b")[1]
    if link and link.attrs.href then
      date = date and trim(date.text) or ""
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(absolute(BILLS_URL, link.attrs.href), (y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_mint-energie_" .. sanitize(amount and amount.text or "") .. ".pdf", {
        name = "Facture Mint Énergie " .. date,
        type = "invoice",
        category = "housing",
        subcategory = "energy",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
