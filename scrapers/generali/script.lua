-- Scraper for Generali's customer area (generali.fr/espace-client): downloads the health
-- reimbursement statements.
--
-- the password is typed on a virtual keypad - each
-- `#generali-connexion-form button.c-field__keyboard__btn` shows its digit as a base64 PNG in
-- its `style` and posts its `data-value`; the original implementation recognised the 10 images, here by an
-- 8-character fingerprint of each (DIGIT_FINGERPRINTS, taken from digipad.js). The form is
-- posted with identifiant, `keyboard` ("<value>|<value>|...|"), op=Connexion,
-- form_id=generali_connexion_form and form_build_id. "Vos codes d'accès ne sont pas reconnus"
-- means bad credentials; success shows a `.consulter-mes-remboursements` link (with
-- `contrat=<id>`). Reimbursements come from the Drupal AJAX endpoint
-- `.../sante/mes-remboursements/more?contrat=<id>&start=<n>` (10 at a time, the HTML being the
-- `insert`/`before` command's data, more pages while there is no `remove` command); each
-- `.c-details__infos` block has a `.telecharger-reglement a` statement link. Unverified (see
-- README.md).

local M = {}

local BASE = "https://www.generali.fr"
local LOGIN_URL = BASE .. "/espace-client/public/connexion"
local MORE_URL = BASE .. "/espace-client/private/individuel/mes-contrats/sante/mes-remboursements/more?"
local DIGIT_FINGERPRINTS = {
  ["0"] = "rxhYKt1i", ["1"] = "ndTYlaN5", ["2"] = "jVakWSEk", ["3"] = "TPgXYjIZ", ["4"] = "gOSgcpTt",
  ["5"] = "5l+W9y2b", ["6"] = "1sZYukaC", ["7"] = "ArWBxENI", ["8"] = "QsqIkVoY", ["9"] = "EIpBRFgn",
}

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
local contains_any = helpers.contains_any
local trim = helpers.trim
local sanitize = helpers.sanitize

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
-- luacheck: pop

local function keypad(page)
  local table_ = {}
  for _, button in ipairs(fyde.html.select(page.body, "#generali-connexion-form button.c-field__keyboard__btn")) do
    for digit, fingerprint in pairs(DIGIT_FINGERPRINTS) do
      if (button.attrs.style or ""):find(fingerprint, 1, true) then
        table_[digit] = button.attrs["data-value"]
      end
    end
  end
  return table_
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(LOGIN_URL)
  if not has(page, "#generali-connexion-form") then
    error("Generali login form not found on " .. page.url)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local keys, encoded = keypad(page), {}
  for digit in tostring(params.password):gmatch(".") do
    if not keys[digit] then
      fail(INVALID_CREDENTIALS, "the Generali password is made of digits typed on the keypad")
    end
    encoded[#encoded + 1] = keys[digit]
  end
  local build = fyde.html.select(page.body, "#generali-connexion-form input[name='form_build_id']")[1]
  local resp = fyde.http.post_form(LOGIN_URL, {
    identifiant = params.username,
    keyboard = table.concat(encoded, "|") .. "|",
    op = "Connexion",
    form_id = "generali_connexion_form",
    form_build_id = build and build.attrs.value or "",
  })
  if contains_any(resp.body, { "Vos codes d&apos;acc&#xE8;s ne sont pas reconnus", "Vos codes d'acc\195\168s ne sont pas reconnus" }) then
    fail(INVALID_CREDENTIALS)
  end
  return resp
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local page = fyde.http.get(BASE .. "/espace-client/private/individuel")
  if has(page, ".consulter-mes-remboursements") then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    page = login(params)
  end
  local link = fyde.html.select(page.body, ".consulter-mes-remboursements")[1]
  local contract = link and (link.attrs.href or ""):match("contrat=(.*)")
  if not contract then
    error("no reimbursements link after login (vendor down?)")
  end

  fyde.progress.step("Downloading reimbursement statements")
  local start = 0
  while true do
    local commands = json_or_nil(fyde.http.get(MORE_URL .. "contrat=" .. contract .. "&start=" .. start).body) or {}
    local html, more = "", true
    for _, command in ipairs(commands) do
      if command.command == "insert" and command.method == "before" and html == "" then
        html = command.data or ""
      elseif command.command == "remove" then
        more = false
      end
    end
    for _, block in ipairs(fyde.html.select(html, ".c-details__infos")) do
      local results = fyde.html.select(block.html, ".c-details__result")
      local statement = fyde.html.select(block.html, ".telecharger-reglement a")[1]
      if statement and statement.attrs.href then
        local date = results[1] and trim(results[1].text) or ""
        local d, m, y = date:match("(%d+)/(%d+)/(%d+)")
        save_pdf(BASE .. statement.attrs.href, (y and string.format("%s-%02d-%02d", y, tonumber(m), tonumber(d)) or sanitize(date)) .. "_generali.pdf", {
          name = "Remboursement Generali " .. date,
          type = "reimbursement_statement",
          category = "health",
          subcategory = "complementary_health",
        })
      end
    end
    if not more or #commands == 0 then
      break
    end
    start = start + 10
  end
  fyde.progress.step("Done")
end

return M
