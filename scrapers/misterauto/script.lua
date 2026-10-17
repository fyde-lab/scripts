-- Scraper for Mister Auto (mister-auto.com), the car-parts retailer: downloads order invoices.
--
-- Login posts `#login_form`
-- (`personnelle[email]`/`personnelle[password]`) from `/moncompte/` (the original implementation didn't
-- validate it; here the orders table must then be reachable, and the form coming back means
-- bad credentials). Orders: `/moncompte/commandes.html`, `#cmd_table tbody tr` rows - a normal
-- row is date, id, amount, ..., invoice link (6th cell); rows sharing a date cell with
-- `rowspan` are grouped orders whose own rows are id, amount, ..., link (5th cell).
-- Unverified (see README.md).

local M = {}

local BASE = "https://www.mister-auto.com/moncompte/"
local ORDERS_URL = BASE .. "commandes.html"

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
  local page = fyde.http.get(BASE)
  if not has(page, "#login_form") then
    error("Mister Auto login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "#login_form", { ["personnelle[email]"] = params.username, ["personnelle[password]"] = params.password })
  if has(resp, "#login_form") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if has(page, "#cmd_table") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(ORDERS_URL)
    if not has(page, "#cmd_table") then
      fail(INVALID_CREDENTIALS, "orders not reachable after login")
    end
  end

  fyde.progress.step("Downloading invoices")
  local group_date
  for _, row in ipairs(fyde.html.select(page.body, "#cmd_table tbody tr")) do
    local cells = fyde.html.select(row.html, "td")
    local link = fyde.html.select(row.html, "a[href]")
    link = link[#link]
    local date, id
    if cells[1] and cells[1].attrs.rowspan then
      group_date = trim(cells[1].text)
      date, id = group_date, cells[2] and trim(cells[2].text)
    else
      date, id = group_date or "", cells[1] and trim(cells[1].text)
    end
    if link and id then
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      save_pdf(absolute(BASE, link.attrs.href), "misterauto-" .. (y and (y .. "-" .. m .. "-" .. d) or "commande") .. "-" .. sanitize(id) .. ".pdf", {
        name = "Facture Mister Auto " .. id,
        type = "invoice",
        category = "shopping",
        subcategory = "online",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
