-- Scraper for Le Monde diplomatique's shop (boutique.monde-diplomatique.fr): saves one
-- document per purchase (subscriptions, issues).
--
-- Login posts
-- `form#identification_sso` (email/mot_de_passe) from `www.monde-diplomatique.fr/sso/connexion/
-- ?retour=...boutique...`; logged in shows `#session_deconnexion`. Purchases: the
-- `.achats-ligne` rows of `/sales/order/history/` (date, title, number, amount); each order page
-- (`/gsales/order/view/id/<n>`, `.my-account`) was rendered into a PDF by the original implementation - here a
-- text-only PDF. Unverified (see README.md).

local M = {}

local SHOP = "https://boutique.monde-diplomatique.fr"
local HISTORY_URL = SHOP .. "/sales/order/history/"
local LOGIN_URL = "https://www.monde-diplomatique.fr/sso/connexion/?retour=https%3A%2F%2Fboutique.monde-diplomatique.fr%2Fcustomer%2Faccount"

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

-- A `kind:value` subject for fyde.save_document's `subjects`: who or what the document concerns
-- when the account covers several (`person`, `line`, `account`, `contract`, `place`, `vehicle`
-- or `trip`). The value is lowercased with runs of spaces/punctuation turned into "-"; nil for a
-- blank value, which a `subjects` list simply skips.
local function subject(kind, value)
  local slug = trim(value or ""):lower():gsub("[%s%p]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return nil
  end
  return kind .. ":" .. slug
end

-- Masks all but the last `keep` characters of an identifier (phone number, IBAN, contract
-- number...), enough to tell them apart without spelling them out in a subject.
local function mask(value, keep)
  value = (value or ""):gsub("%s", "")
  if #value <= keep then
    return value
  end
  return string.rep("x", #value - keep) .. value:sub(-keep)
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

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "form#identification_sso") then
    error("Monde diplomatique login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = submit_form(page, "form#identification_sso", { email = params.username, mot_de_passe = params.password })
  if not has(resp, "#session_deconnexion") then
    fail(INVALID_CREDENTIALS)
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(HISTORY_URL)
  if has(page, "#session_deconnexion, .achats-ligne") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    page = fyde.http.get(HISTORY_URL)
  end

  fyde.progress.step("Saving purchases")
  for _, row in ipairs(fyde.html.select(page.body, ".achats-ligne")) do
    local cells = fyde.html.select(row.html, "td")
    if #cells >= 4 then
      local number = trim(cells[3].text):match("(%d+)%s*$") or trim(cells[3].text)
      local title = trim(cells[2].text:gsub("%s+", " "))
      local url = SHOP .. "/gsales/order/view/id/" .. number
      local order = fyde.http.get(url)
      local account = fyde.html.select(order.body, ".my-account")[1]
      local lines = html_lines(account and account.html or order.body)
      table.insert(lines, 1, "Généré depuis " .. url)
      fyde.save_document(sanitize(title) .. "-" .. number .. ".pdf", text_pdf("Le Monde diplomatique - commande " .. number, lines), {
        name = "Le Monde diplomatique - " .. title,
        type = "invoice",
        category = "subscriptions",
        subcategory = "media",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
