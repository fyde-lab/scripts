-- Scraper for Deezer (deezer.com), the music streaming service: saves the subscription
-- payment receipts.
--
-- The original implementation solved the login
-- page's reCAPTCHA through a paid service, read `checkFormLogin` from
-- `ajax/gw-light.php?method=deezer.getUserData` and posted type=login/mail/password/
-- checkFormLogin/reCaptchaToken to `ajax/action.php` ("success" / "error" = bad credentials).
-- With no captcha solver here, the login goes through `fyde.browser` on `/fr/login` (the
-- widget may or may not pass in the embedded webview - unconfirmed). A session is valid when
-- `/fr/login` sends straight back to the home page. Receipts: `.history-list > li` entries
-- (title, `.payment-history-date`, `.payment-history-price`, link) of
-- `/account/subscription`; they are HTML pages, so - like the original implementation, which saved them as
-- .html - their text is saved, here as a text-only PDF. The original implementation's playlists import is
-- data, not documents, so it's not ported. Unverified (see README.md).

local M = {}

local BASE = "https://www.deezer.com"
local LOGIN_URL = BASE .. "/fr/login"
local SUBSCRIPTION_URL = BASE .. "/account/subscription"
local BAD_CREDENTIALS = { "e-mail ou mot de passe", "adresse e-mail ou le mot de passe", "incorrect", "invalid" }

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

local LOGGED_IN = { "logged_in", selector = ".history-list, [data-testid='account-menu'], #account_dropdown, a[href*='/account']" }

local function login(params)
  fyde.progress.step("Logging in")
  if open_and_wait(LOGIN_URL, { { "login", selector = "input[type='password']" } }, 30000) ~= "login" then
    error("Deezer login form not found")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  if present("#gdpr-btn-refuse-all") then
    fyde.browser:click("#gdpr-btn-refuse-all")
  end
  fill_first({ "#login_mail", "input[name='email']", "input[type='email']" }, params.username)
  fill_first({ "#login_password", "input[name='password']", "input[type='password']" }, params.password)
  click_first({ "#login_form_submit", "button[type='submit']" })
  local state = wait_state({ { "bad", text = BAD_CREDENTIALS }, { "moved", selector = "[data-testid='header'], #page_sidebar" } }, 30000)
  if state == "bad" then
    fail(INVALID_CREDENTIALS)
  end
  if open_and_wait(SUBSCRIPTION_URL, { LOGGED_IN, { "login", selector = "input[type='password']" } }, 30000) ~= "logged_in" then
    if present("input[type='password']") then
      fail(INVALID_CREDENTIALS, "still on the login form")
    end
    error("Deezer login did not complete (captcha?) - page says: " .. page_text():sub(1, 300))
  end
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  if open_and_wait(SUBSCRIPTION_URL, { LOGGED_IN, { "login", selector = "input[type='password']" } }, 30000) == "logged_in" then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    login(params)
  end

  fyde.progress.step("Saving receipts")
  local entries = fyde.html.select(page_html(), ".history-list > li")
  for i = 2, #entries do
    local entry = entries[i]
    local link = fyde.html.select(entry.html, "a")[1]
    local date = fyde.html.select(entry.html, ".payment-history-date")[1]
    local price = fyde.html.select(entry.html, ".payment-history-price")[1]
    local title = fyde.html.select(entry.html, ".payment-history-title")[1]
    if link and link.attrs.href then
      fyde.browser:open(link.attrs.href:match("^https?://") and link.attrs.href or (BASE .. link.attrs.href))
      sleep(3000)
      local lines = {}
      for line in page_text():gmatch("[^\n]+") do
        if trim(line) ~= "" then
          lines[#lines + 1] = trim(line)
        end
      end
      local d = date and trim(date.text) or tostring(i)
      fyde.save_document(sanitize(d) .. "_deezer.pdf", text_pdf("Deezer - " .. (title and trim(title.text) or "Reçu"), lines), {
        name = "Reçu Deezer " .. d .. (price and (" (" .. trim(price.text) .. ")") or ""),
        type = "invoice",
        source_category = "web",
        purpose = "invoice",
      })
    end
  end
  fyde.progress.step("Done")
end

return M
