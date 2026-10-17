-- Scraper for Auchan Drive's customer account, now part of auchan.fr: downloads order invoices.
--
-- The original auchandrive.fr site now
-- redirects to auchan.fr, where the old `/drive/client/identification` form is gone (404).
-- Rebuilt against the live site: `www.auchan.fr/client/mes-commandes` redirects a logged-out
-- visitor to a Keycloak SSO (compte.auchan.fr, realm `auchan.fr`) whose `form#kc-form-login`
-- takes `username`/`password`. The form carries a reCAPTCHA v3 field (`g-recaptcha-response`)
-- that this host can't fill; posted empty, bad credentials still get "Nom d'utilisateur ou mot
-- de passe invalide." (confirmed against the live site) - whether a correct login goes through
-- without a token is not. Success hands back to `mes-commandes?auth_callback=1`.
-- Documents: the original implementation rendered drive orders' print pages into PDFs itself; that page is gone
-- too. Not verified (no account): invoices are looked for as PDF/"facture" links on the orders
-- page (see README.md).

local M = {}

local ORIGIN = "https://www.auchan.fr"
local ORDERS_URL = ORIGIN .. "/client/mes-commandes"
local SSO_HOST = "compte.auchan.fr"
local LOGIN_FORM = "form#kc-form-login"
local BAD_CREDENTIALS = { "mot de passe invalide", "Invalid username or password" }

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
local contains = helpers.contains
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize
local absolute = helpers.absolute
local submit_form = helpers.submit_form
local has = helpers.has
local save_pdf = helpers.save_pdf

-- Minimal text-only PDF writer, for sites that have
-- no downloadable document and whose data has to be rendered into one: each entry of `lines`
-- becomes one line of Helvetica (WinAnsi; characters outside Latin-1 become '?').
local function text_pdf(title, lines)
  local function latin1(s)
    local out = {}
    for _, cp in utf8.codes(s) do
      out[#out + 1] = cp < 256 and string.char(cp) or "?"
    end
    return (table.concat(out):gsub("[\\()]", "\\%0"))
  end
  local all = { title, "" }
  for _, line in ipairs(lines) do
    all[#all + 1] = line
  end
  local per_page, pages = 48, {}
  for first = 1, #all, per_page do
    local ops = { "BT /F1 11 Tf 14 TL 50 790 Td" }
    for i = first, math.min(first + per_page - 1, #all) do
      ops[#ops + 1] = "(" .. latin1(all[i]) .. ") Tj T*"
    end
    ops[#ops + 1] = "ET"
    pages[#pages + 1] = table.concat(ops, "\n")
  end
  local objects = { "<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>" }
  local kids = {}
  for _, content in ipairs(pages) do
    objects[#objects + 1] = "<< /Length " .. #content .. " >>\nstream\n" .. content .. "\nendstream"
    objects[#objects + 1] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents " .. (#objects) .. " 0 R >>"
    kids[#kids + 1] = #objects .. " 0 R"
  end
  objects[2] = "<< /Type /Pages /Kids [" .. table.concat(kids, " ") .. "] /Count " .. #kids .. " >>"
  local out, offsets = { "%PDF-1.4\n" }, {}
  local size = #out[1]
  for i, body in ipairs(objects) do
    offsets[i] = size
    local chunk = i .. " 0 obj\n" .. body .. "\nendobj\n"
    out[#out + 1] = chunk
    size = size + #chunk
  end
  local xref = { "xref\n0 " .. (#objects + 1) .. "\n0000000000 65535 f \n" }
  for _, offset in ipairs(offsets) do
    xref[#xref + 1] = string.format("%010d 00000 n \n", offset)
  end
  out[#out + 1] = table.concat(xref)
  out[#out + 1] = "trailer\n<< /Size " .. (#objects + 1) .. " /Root 1 0 R >>\nstartxref\n" .. size .. "\n%%EOF\n"
  return table.concat(out)
end

-- Flattens an HTML page/fragment into text lines for text_pdf (headings, paragraphs, list
-- items and table rows, in document order).
local function html_lines(html)
  local lines = {}
  for _, el in ipairs(fyde.html.select(html, "h1, h2, h3, h4, p, li, tr, dt, dd")) do
    local text = trim(el.text:gsub("%s+", " "))
    if text ~= "" then
      lines[#lines + 1] = text
    end
  end
  return lines
end
-- luacheck: pop

local function on_sso(page)
  return contains(page.url, SSO_HOST)
end

-- `page` is the SSO login page the orders page redirected to.
local function login(params, page)
  fyde.progress.step("Logging in")
  if not has(page, LOGIN_FORM) then
    error("Auchan login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, LOGIN_FORM, {
    username = params.username,
    password = params.password,
    rememberMe = "on",
  })
  if has(resp, LOGIN_FORM) or on_sso(resp) then
    if contains_any(resp.body, BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    end
    error("Auchan login did not complete (reCAPTCHA?) - still on " .. resp.url)
  end
  return resp
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(ORDERS_URL)
  if not on_sso(page) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params, page)
    page = fyde.http.get(ORDERS_URL)
  end

  fyde.progress.step("Downloading invoices")
  local seen, count = {}, 0
  for _, link in ipairs(fyde.html.select(page.body, "a[href]")) do
    local href = link.attrs.href or ""
    local text = trim(link.text or "")
    if (href:lower():find("%.pdf") or contains_any(href .. " " .. text, { "facture", "invoice" })) and not seen[href] then
      seen[href] = true
      count = count + 1
      local label = text ~= "" and text or tostring(count)
      save_pdf(absolute(page.url, href), "auchan_" .. count .. "_" .. sanitize(label) .. ".pdf", {
        name = "Facture Auchan " .. label,
        type = "invoice",
        category = "shopping",
        subcategory = "groceries",
      })
    end
  end
  if count == 0 then
    fyde.log.warn("no invoice link found on " .. page.url)
  end
  fyde.progress.step("Done")
end

return M
