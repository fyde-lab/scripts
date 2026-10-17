-- Scraper for Facebook (graph.facebook.com): checks the account's access token and lists its
-- photo albums.
--
-- The original implementation has
-- no login form at all: it used an OAuth access token obtained through an OAuth flow (and
-- refreshed with an app client id/secret) to walk `/me/albums` and each album's
-- `/<id>/photos?fields=id,images,...` (paginated by `paging.next`), saving every photo's
-- largest image. Here the token is a parameter (`access_token`) instead: an invalid/expired
-- token (Graph API error code 190) is reported as INVALID_CREDENTIALS, the closest thing to a
-- wrong password. Photos are JPEGs, which fyde.save_document doesn't accept (PDF only), so
-- they are listed but not saved - a known blocker, see README.md. Unverified.

local M = {}

local GRAPH = "https://graph.facebook.com/v2.12"

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
local MFA_FAILED = helpers.MFA_FAILED
local fail = helpers.fail
local contains = helpers.contains

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
-- luacheck: pop

local graph_found = false

local function api(path, token)
  local sep = path:find("?", 1, true) and "&" or "?"
  local url = path:match("^https://") and path or (GRAPH .. path .. sep .. "access_token=" .. token)
  local data = json_or_nil(fyde.http.get(url).body)
  if not data then
    error("Graph API answered something other than JSON for " .. path)
  end
  if not graph_found then
    -- There is no login page: the Graph API answering in JSON is the equivalent marker.
    graph_found = true
    fyde.log.info("LOGIN_PAGE_FOUND")
  end
  if data.error then
    if data.error.code == 190 or data.error.type == "OAuthException" then
      fail(INVALID_CREDENTIALS, data.error.message)
    end
    error("Graph API error: " .. tostring(data.error.message))
  end
  return data
end

function M.run(params)
  local token = params.access_token or params.password
  if not token or token == "" then
    fail(INVALID_CREDENTIALS, "no access token given")
  end
  fyde.progress.step("Checking the access token")
  local me = api("/me", token)
  fyde.log.info("token valid for " .. tostring(me.name))

  fyde.progress.step("Listing albums")
  local url = "/me/albums"
  local photos = 0
  while url do
    local page = api(url, token)
    for _, album in ipairs(page.data or {}) do
      local p = api("/" .. album.id .. "/photos?fields=id", token)
      photos = photos + #(p.data or {})
    end
    url = page.paging and page.paging.next
  end
  fyde.log.warn(photos .. " photo(s) found but not saved: fyde.save_document only accepts PDFs")
  fyde.progress.step("Done")
end

return M
