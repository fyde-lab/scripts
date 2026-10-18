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

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local json_or_nil = helpers.json_or_nil

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
  fyde.progress.step("checking_session")
  local me = api("/me", token)
  fyde.log.info("token valid for " .. tostring(me.name))

  fyde.progress.step("listing_documents")
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
  fyde.progress.step("done")
end

return M
