-- Scraper for Fortuneo (mabanque.fortuneo.fr), the online bank: saves a statement of each
-- account's recent operations.
--
-- The original form login
-- (`form[name="acces_identification"]` on `/fr/identification.jsp`) is gone: that URL now
-- redirects to `/mon-espace`, a client-rendered React page, so the login is driven through
-- `fyde.browser`: `#LOGIN` (a numeric identifier) and `#PASSWD`, sent by the "Connexion"
-- submit button; a wrong login shows "L'identifiant ou le mot de passe ne correspondent à aucun
-- compte existant" (checked live, with made-up credentials). Success is taken to show an
-- `a[href="/logoff"]` link as before (unconfirmed), and "Sécurité renforcée tous les 90 jours"
-- to mean a user action is needed on the site. Accounts: the `#menu_mes_comptes ul div.compte`
-- entries (number in `a > div`, label in the link title), read from the webview (unconfirmed
-- since the redesign). The original implementation imported operations from a CSV inside a ZIP export into
-- banking doctypes; this sandbox can't unzip, so this port saves each account page's
-- operations table (`#tableauConsultationHisto`) as a text-only PDF instead. Unverified (see
-- README.md).

local M = {}

local BASE = "https://mabanque.fortuneo.fr"
local LOGIN_URL = BASE .. "/mon-espace"
local HOME_URL = BASE .. "/fr/prive/default.jsp"
local LOGGED_IN = { "logged_in", selector = "a[href='/logoff'], #menu_mes_comptes" }
local BAD_CREDENTIALS = { "ne correspondent à aucun compte", "identifiant ou le mot de passe" }

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

-- `wait_for` only waits for a selector to appear, so sleeping means waiting on one that never
-- exists.
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

local function present(selector)
  return #fyde.html.select(page_html(), selector) > 0
end

local function page_text()
  local body = fyde.html.select(page_html(), "body")[1]
  return body and body.text or ""
end

-- Polls the current page until one of `states` matches and returns its name (or nil after
-- `timeout_ms`). Each state is `{ name, selector = css }` or `{ name, text = { needles } }`.
-- Polling in short chunks also survives `fyde.browser:open` not waiting for navigation (a
-- `wait_for` issued against the previous page just times out and gets retried).
local function wait_state(states, timeout_ms)
  local waited = 0
  repeat
    local html = page_html()
    local text
    for _, state in ipairs(states) do
      if state.selector and #fyde.html.select(html, state.selector) > 0 then
        return state[1]
      end
      if state.text then
        if not text then
          local body = fyde.html.select(html, "body")[1]
          text = body and body.text or ""
        end
        if contains_any(text, state.text) then
          return state[1]
        end
      end
    end
    sleep(1000)
    waited = waited + 1000
  until waited >= (timeout_ms or 30000)
  return nil
end

local function open_and_wait(url, states, timeout_ms)
  fyde.browser:open(url)
  sleep(1500)
  return wait_state(states, timeout_ms)
end

-- Fills the first present selector of each candidate list.
local function fill_first(selectors, value)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:fill(selector, value)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

local function click_first(selectors)
  for _, selector in ipairs(selectors) do
    if present(selector) then
      fyde.browser:click(selector)
      return selector
    end
  end
  error("none of " .. table.concat(selectors, ", ") .. " is on the page")
end

-- Clicks `selector` (a download link/button) and saves what the browser downloads.
local function browser_save(selector, filename, fields)
  local ok, bytes = pcall(function()
    return fyde.browser:download(selector, 60000)
  end)
  if ok and type(bytes) == "string" and bytes:sub(1, 4) == "%PDF" then
    fyde.save_document(sanitize(filename), bytes, fields)
    return true
  end
  fyde.log.warn("could not download " .. filename .. ": " .. tostring(ok and "not a PDF" or bytes))
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
  if open_and_wait(LOGIN_URL, { LOGGED_IN, { "login", selector = "#PASSWD" } }, 45000) ~= "login" then
    error("Fortuneo login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present("#popin_tc_privacy_button_2") then
    fyde.browser:click("#popin_tc_privacy_button_2")
  end
  fyde.browser:fill("#LOGIN", params.username)
  fyde.browser:fill("#PASSWD", params.password)
  click_first({ "form button[type='submit'][class]", "#valider_login" })
  local state = wait_state({ LOGGED_IN, { "bad", text = BAD_CREDENTIALS } }, 45000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if contains(page_text(), "curité renforcée tous les 90 jours") then
    error("Fortuneo requires a periodic security check on its website (user action needed)")
  end
  if state ~= "logged_in" then
    if present("#PASSWD") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Fortuneo login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(HOME_URL, { LOGGED_IN, { "login", selector = "#PASSWD" } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
    open_and_wait(HOME_URL, { LOGGED_IN }, 30000)
  end

  fyde.progress.step("Saving account statements")
  for _, account in ipairs(fyde.html.select(page_html(), "#menu_mes_comptes ul div.compte")) do
    local link = fyde.html.select(account.html, "a")[1]
    local number = fyde.html.select(account.html, "a > div")[1]
    number = number and (number.text:match("%s(%S+)") or trim(number.text)) or "compte"
    local href = link and link.attrs.href
    if href then
      open_and_wait(href:sub(1, 1) == "/" and (BASE .. href) or href, { { "table", selector = "#tableauConsultationHisto" } }, 30000)
      local lines = {}
      for _, row in ipairs(fyde.html.select(page_html(), "#tableauConsultationHisto tr")) do
        local cells = {}
        for _, cell in ipairs(fyde.html.select(row.html, "td, th")) do
          cells[#cells + 1] = trim(cell.text:gsub("%s+", " "))
        end
        if #cells > 0 then
          lines[#lines + 1] = table.concat(cells, " | ")
        end
      end
      if #lines > 0 then
        fyde.save_document("Fortuneo_" .. sanitize(number) .. ".pdf", text_pdf("Fortuneo - " .. (link.attrs.title or number), lines), {
          name = "Opérations Fortuneo " .. (link.attrs.title or number),
          type = "statement",
          category = "money",
          subcategory = "banking",
        })
      end
    end
  end
  fyde.progress.step("Done")
end

return M
