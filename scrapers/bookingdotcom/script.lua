-- Scraper for Booking.com (secure.booking.com): saves one document per reservation.
--
-- Ported from github.com/konnectors/bookingdotcom (src/index.js), whose form login on
-- `myreservations.html` is gone: that page now redirects to account.booking.com, a
-- client-rendered sign-in, so the login is driven through `fyde.browser`. `form.nw-signin` asks
-- for the e-mail (`input[name=username]`, then its submit button - an `#hidden-password` field
-- is only an autofill decoy); what comes next depends on the account: a password field, or an
-- e-mailed 6-digit code (`form.nw-email-otp`, one `input[name=code_<i>]` per digit). A
-- made-up e-mail gets the code step (checked live), so a wrong login can only end in
-- `MFA_FAILED`; the password step and its error message are unconfirmed. Reservations are the
-- `.js-booking_block` (current) and `.mb-container` (past) blocks of `myreservations.html`,
-- read from the webview (layout unconfirmed since the move). Booking.com has no invoices, so
-- the konnector generated a PDF per reservation (name, number, price, dates) - this port writes
-- the same as a text-only PDF. Unverified (see README.md).

local M = {}

local RESERVATIONS_URL = "https://secure.booking.com/myreservations.html"
local SIGNIN_FORM = "form.nw-signin"
local OTP_FORM = "form.nw-email-otp"
local PASSWORD_FIELD = "input[type='password']:not(#hidden-password)"
local RESERVATIONS = ".js-booking_block, .mb-container, .mb-block"
-- No error texts are matched: the sign-in embeds its whole translation table (including "Mot de
-- passe incorrect") as inline JSON, so the page text always "contains" them. Staying on the
-- password field or the code form after submitting is the refusal instead.

-- luacheck: push ignore 211
-- ---------------------------------------------------------------------------------------------
-- Shared block (identical in every scraper ported from github.com/konnectors - see README.md).
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

-- Minimal text-only PDF writer, for sites (like the konnector this was ported from) that have
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

local LOGGED_IN = { "logged_in", selector = RESERVATIONS }

local function text_of(html, selector)
  local node = fyde.html.select(html, selector)[1]
  return node and trim(node.text) or ""
end

local function enter_code()
  local code = ask_code("Code de vérification Booking.com (envoyé par e-mail)")
  for i = 0, 5 do
    fyde.browser:fill(OTP_FORM .. " input[name='code_" .. i .. "']", code:sub(i + 1, i + 1))
  end
  click_first({ OTP_FORM .. " button[type='submit']" })
  local state = wait_state({ LOGGED_IN, { "password", selector = PASSWORD_FIELD } }, 30000)
  if state == nil then
    fail(MFA_FAILED, page_text():sub(1, 200))
  end
  return state
end

local function login(params)
  fyde.progress.step("Logging in")
  if not present(SIGNIN_FORM) then
    open_and_wait(RESERVATIONS_URL, { { "login", selector = SIGNIN_FORM .. " input[name='username']" } }, 30000)
  end
  if not present(SIGNIN_FORM .. " input[name='username']") then
    error("Booking.com sign-in form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  fyde.browser:fill(SIGNIN_FORM .. " input[name='username']", params.username)
  click_first({ SIGNIN_FORM .. " button[type='submit']" })
  local state = wait_state({ { "otp", selector = OTP_FORM }, { "password", selector = PASSWORD_FIELD } }, 30000)
  if state == "otp" then
    state = enter_code()
  end
  if state == "password" then
    fyde.browser:fill(PASSWORD_FIELD, params.password)
    click_first({ "button[type='submit']" })
    state = wait_state({ LOGGED_IN, { "otp", selector = OTP_FORM } }, 30000)
    if state == "otp" then
      state = enter_code()
    elseif state == nil and present(PASSWORD_FIELD) then
      fail(INVALID_CREDENTIALS, "still on the password step")
    end
  end
  if state ~= "logged_in" and open_and_wait(RESERVATIONS_URL, { LOGGED_IN, { "login", selector = SIGNIN_FORM } }, 30000) ~= "logged_in" then
    error("Booking.com login did not complete - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(RESERVATIONS_URL, { LOGGED_IN, { "login", selector = SIGNIN_FORM } }, 45000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Saving reservations")
  for _, block in ipairs(fyde.html.select(page_html(), ".js-booking_block, .mb-container")) do
    local name = text_of(block.html, ".mb-block__hotel-name a, .mb-hotel-name a")
    local number = text_of(block.html, ".mb-block__book-number b.marginRight_5")
    local price = text_of(block.html, ".mb-block__price .mb-block__price__big, .mb-price__unit")
    local dates = {}
    for _, d in ipairs(fyde.html.select(block.html, ".mb-dates__block, .mh-date")) do
      dates[#dates + 1] = trim(d.text:gsub("%s+", " "))
    end
    if number ~= "" then
      fyde.save_document(sanitize((dates[1] or "") .. "-" .. name) .. ".pdf", text_pdf("Booking.com Réservation " .. number, {
        "Hébergement : " .. name,
        "Réservation # : " .. number,
        "Prix : " .. price,
        "Arrivée : " .. (dates[1] or ""),
        "Départ : " .. (dates[2] or ""),
        "Généré depuis " .. RESERVATIONS_URL,
      }), {
        name = "Réservation Booking.com " .. name,
        type = "invoice",
        source_category = "transport",
        purpose = "invoice",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
