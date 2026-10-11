-- Scraper for Nespresso (nespresso.com), the coffee retailer: saves one document per order.
--
-- The original implementation posted
-- j_username/j_password to `mosaic/fr/en/ecapi/1/authentication/login` over plain HTTP - that
-- endpoint now sits behind Akamai Bot Manager and answers HTTP 403 to anything without a
-- browser-made `_abck` cookie. So the login is driven through `fyde.browser`: `/fr/fr/secure/
-- login` renders an AngularJS `form#loginForm` with `#emailField`/`#passwordField` and a
-- `#ta-login-page-login-submit` button, which posts to that same endpoint from the page itself
-- (confirmed against the live site). Orders, unverified (no account): the `.my-orders-list
-- .my-orders-list__row-content` rows of `/fr/fr/myaccount/orders/changeList?number=100`
-- (number, amount, date, link to the order page), each order's `.my-order-details` rendered
-- into a text-only PDF as the original implementation did, all read through the webview. See README.md.

local M = {}

local ORDERS_URL = "https://www.nespresso.com/fr/fr/myaccount/orders"

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

local LOGIN_URL = "https://www.nespresso.com/fr/fr/secure/login"
local EMAIL_FIELD = "#emailField"
local PASSWORD_FIELD = "#passwordField"
local SUBMIT = "#ta-login-page-login-submit"
local ORDERS_LIST = ".my-orders-list"

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

local function body_text(html)
  local body = fyde.html.select(html, "body")[1]
  return body and body.text or ""
end

-- Opens `url` and waits (up to `timeout_ms`, past Akamai's sensor script) for one of
-- `selectors` to show up; returns the page's markup either way.
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

local BAD_CREDENTIALS = {
  "mot de passe incorrect",
  "identifiants incorrects",
  "adresse email ou mot de passe",
  "email ou mot de passe",
  "invalid email or password",
}

local function login(params)
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.progress.step("Logging in")
  local h0 = page_html()
  fyde.log.info("DBG before ngform=" .. tostring(has(h0, "#loginForm.ng-pristine, #loginForm.ng-dirty")) .. " len=" .. #h0)
  fyde.browser:fill(EMAIL_FIELD, params.username)
  fyde.browser:fill(PASSWORD_FIELD, params.password)
  fyde.browser:click(SUBMIT)
  for _ = 1, 45 do
    sleep(1000)
    local html = page_html()
    for _, e in ipairs(fyde.html.select(html, ".error-message:not(.ng-hide), [role=alert], .alert, .notification")) do fyde.log.info("DBG " .. trim(e.text:gsub("%s+"," ")):sub(1,200)) end
    local t = fyde.html.select(html, "title")[1]
    fyde.log.info("DBG pw=" .. tostring(has(html, PASSWORD_FIELD)) .. " len=" .. #html .. " title=" .. (t and t.text or "?") .. " ngform=" .. tostring(has(html, "#loginForm.ng-pristine, #loginForm.ng-dirty")))
    for _, e in ipairs(fyde.html.select(html, "h1, h2, link[rel=canonical], meta[property='og:url']")) do fyde.log.info("DBG H " .. trim(e.text:gsub("%s+"," ")):sub(1,120) .. " " .. tostring(e.attrs.href or e.attrs.content)) end
    local error_box = fyde.html.select(html, "#email-error-message:not(.ng-hide)")[1]
    if error_box and trim(error_box.text) ~= "" then
      fail(INVALID_CREDENTIALS, trim(error_box.text:gsub("%s+", " ")))
    elseif has(html, PASSWORD_FIELD) and contains_any(body_text(html), BAD_CREDENTIALS) then
      fail(INVALID_CREDENTIALS)
    elseif not has(html, PASSWORD_FIELD) then
      return
    end
  end
  if has(page_html(), PASSWORD_FIELD) then
    fail(INVALID_CREDENTIALS, "still on the login form")
  end
  error("Nespresso login did not complete")
end

local function cell(html, column)
  local node = fyde.html.select(html, ".my-orders-list__" .. column .. " .my-orders-list__cell--description")[1]
  return node and trim(node.text) or ""
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local html = open(ORDERS_URL .. "/changeList?number=100", { ORDERS_LIST, PASSWORD_FIELD }, 45000)
  if has(html, ORDERS_LIST) then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    if not has(html, PASSWORD_FIELD) then
      html = open(LOGIN_URL, { PASSWORD_FIELD }, 45000)
      if not has(html, PASSWORD_FIELD) then
        error("Nespresso login page not found (Akamai challenge not passed?)")
      end
    end
    login(params)
    html = open(ORDERS_URL .. "/changeList?number=100", { ORDERS_LIST }, 45000)
  end

  fyde.progress.step("Saving orders")
  for _, row in ipairs(fyde.html.select(html, ".my-orders-list .my-orders-list__row-content")) do
    local link = fyde.html.select(row.html, ".my-orders-list__actions .my-orders-list__cell--description a")[1]
    local number, date, amount = cell(row.html, "order"), cell(row.html, "date"), cell(row.html, "amount")
    if link and link.attrs.href then
      local order = open(absolute(ORDERS_URL .. "/", link.attrs.href), { ".my-order-details" }, 30000)
      local details = fyde.html.select(order, ".my-order-details")[1]
      local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
      fyde.save_document((y and (y .. "-" .. m .. "-" .. d) or sanitize(date)) .. "_nespresso_" .. sanitize(amount) .. "_" .. sanitize(number) .. ".pdf",
        text_pdf("Commande Nespresso " .. number, html_lines(details and details.html or order)), {
          name = "Commande Nespresso " .. number,
          type = "invoice",
          source_category = "alimentation",
          purpose = "invoice",
        })
    end
  end
  fyde.progress.step("Done")
end

return M
