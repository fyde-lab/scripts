-- Scraper for Trainline (thetrainline.com): downloads the purchase/refund proofs of every
-- booking.
--
-- The JSON API
-- `api/v5_1/account/signin` takes the email/password form (HTTP 422 = bad credentials) and
-- answers `meta.token`, sent afterwards as `Authorization: Token token="<token>"`. Bookings:
-- `api/v5_1/pnrs` then `api/v5_1/pnrs?date=<first day of the month before the oldest
-- sort_date>` while `proofs` keeps coming; each proof with a `url` is a PDF. The token is kept
-- in fyde.session so the next run can skip the login while it's still accepted. Trainline
-- has since changed its login (captcha, SPA), so this API may be gone. Unverified (see
-- README.md).

local M = {}

local BASE = "https://www.thetrainline.com/"

local helpers = fyde.helpers
local INVALID_CREDENTIALS = helpers.INVALID_CREDENTIALS
local fail = helpers.fail
local json_or_nil = helpers.json_or_nil
local save_pdf = helpers.save_pdf

local function api(path, token)
  local resp = fyde.http.get(BASE .. path, { Authorization = 'Token token="' .. token .. '"', Accept = "application/json" })
  return resp.status, json_or_nil(resp.body)
end

local function login(params)
  fyde.progress.step("Logging in")
  local page = fyde.http.get(BASE)
  if page.status >= 500 then
    error("Trainline answered HTTP " .. page.status)
  end
  fyde.log.info("LOGIN_PAGE_FOUND")
  local resp = fyde.http.post_form(BASE .. "api/v5_1/account/signin", { email = params.username, password = params.password }, { Accept = "application/json" })
  if resp.status == 422 or resp.status == 401 then
    fail(INVALID_CREDENTIALS)
  end
  local body = json_or_nil(resp.body)
  local token = body and body.meta and body.meta.token
  if not token then
    error("Trainline sign-in answered HTTP " .. resp.status .. " without a token")
  end
  fyde.session.trainline_token = token
  return token
end

local function previous_month(pnrs)
  local oldest
  for _, pnr in ipairs(pnrs or {}) do
    local d = tostring(pnr.sort_date or ""):sub(1, 10)
    if d ~= "" and (not oldest or d < oldest) then
      oldest = d
    end
  end
  if not oldest then
    return nil
  end
  local y, m = tonumber(oldest:sub(1, 4)), tonumber(oldest:sub(6, 7))
  m = m - 1
  if m == 0 then
    y, m = y - 1, 12
  end
  return string.format("%04d-%02d-01", y, m)
end

function M.run(params)
  fyde.progress.step("Checking for an existing session")
  local token = fyde.session.trainline_token
  local status, page
  if token then
    status, page = api("api/v5_1/pnrs", token)
  end
  if status == 200 and page then
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    token = login(params)
    page = select(2, api("api/v5_1/pnrs", token))
  end

  fyde.progress.step("Downloading proofs")
  local seen = {}
  for _ = 1, 200 do
    if not (page and page.proofs and #page.proofs > 0) then
      break
    end
    for _, proof in ipairs(page.proofs) do
      if proof.url and not seen[proof.id or proof.url] then
        seen[proof.id or proof.url] = true
        local date = tostring(proof.created_at or ""):sub(1, 10)
        save_pdf(proof.url, date .. "_trainline_" .. tostring(proof.id) .. ".pdf", {
          name = (proof.type == "purchase" and "Achat" or "Remboursement") .. " Trainline " .. date,
          type = "invoice",
          category = "transport",
          subcategory = "train",
        })
      end
    end
    local next_date = previous_month(page.pnrs)
    if not next_date then
      break
    end
    page = select(2, api("api/v5_1/pnrs?date=" .. next_date, token))
  end
  fyde.progress.step("Done")
end

return M
