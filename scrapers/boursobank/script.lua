-- Scraper for the BoursoBank customer area (clients.boursobank.com, formerly Boursorama
-- Banque / clients.boursorama.com).
--
-- The login flow is aligned with woob's boursorama module (modules/boursorama,
-- PasswordPage.enter_password), which is maintained against the live site:
--   1. set a `brsDomainMigration=migrated` cookie (woob does; without it the final POST gets a
--      generic "Une erreur est survenue" instead of a real credentials check - confirmed live);
--   2. GET the password page for the form's CSRF token (form[_token]);
--   3. GET the virtual keypad: ten shuffled buttons, each an inline base64 SVG of a digit plus
--      an opaque data-matrix-key, and a per-request matrixRandomChallenge;
--   4. POST the client number, the password translated digit-by-digit into matrix keys
--      ("|"-joined), the challenge and the token back to the password page.
-- The keypad digit images are identified by their exact base64 payload (KEYPAD_DIGITS) -
-- confirmed identical to woob's SHA-256 fingerprints for all ten digits.
--
-- Tried and dropped (confirmed live not to be needed for the request to be accepted): the
-- site's own JS also POSTs /connexion/login-status first and rewrites form[passwordAck] with
-- click/timing data; woob does neither and the server accepted the POST without them.
--
-- **Anti-bot cookie (confirmed against the live site).** Without a `__brs_mit` cookie, every
-- clients.boursobank.com page answers 200 with a ~550-byte stub whose inline JS sets
-- `document.cookie="__brs_mit=<32 hex>"` and reloads. The value is in clear in the stub, so
-- `with_brs_mit` reads it and plants it in the cookie jar with `fyde.http.set_cookie`. Sending
-- it as a manual `Cookie` header is NOT an option: wreq skips the jar for any request that
-- already carries one, dropping the session cookies.
--
-- **Confirmed against a real account:** login (no SMS/app strong-authentication step was asked
-- for; it may still be on another device/IP), session reuse on the next run (the dashboard's
-- `/se-deconnecter` link is the logged-in marker), and documents from the four sections
-- doc-downloaders/scrapers/boursorama scrapes (see SECTIONS): statements/contracts
-- (/documents/releves, "load more" pagination), other banks' documents in the coffre-fort
-- (numbered ?page=N), tax documents (/documents/ifu, one request per fiscal year) and RIBs
-- (/documents/compte-bancaire). Every run re-downloads everything listed.
--
-- Every capability this script uses comes from the `fyde` host table, implemented by
-- fyde-sdk's scrapers domain (see ../sdk/src/domains/scrapers/host/*.rs).

local M = {}

local BASE = "https://clients.boursobank.com"
local URL_LOGIN = BASE .. "/connexion/saisie-mot-de-passe"
local URL_KEYBOARD = BASE .. "/connexion/clavier-virtuel"
local URL_DASHBOARD = BASE .. "/"
-- Safety cap on pages walked per section (20-48 rows each).
local MAX_PAGES = 50

-- base64 SVG payload of each virtual keypad button image -> the digit it draws.
local KEYPAD_DIGITS = {
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxwYXRoIGQ9Im0yMC44IDguMy0yLjggMy0uOS0xIDMuOC00aDEuM3YxNy4zaC0xLjV2LTE1LjN6IiBmaWxsPSIjMDAzODgzIi8+PC9zdmc+"] = 1,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMy45IDM1LjloLTMuNmwtLjYgMS42aC0xbDIuOS03LjJoMS4xbDIuOSA3LjJoLTF6bS0zLjMtLjhoM2wtMS41LTMuOXoiLz48cGF0aCBkPSJtMTguNyAzMC4zaDMuMmMxLjIgMCAyIC44IDIgMS44IDAgLjktLjYgMS41LTEuMyAxLjYuOC4xIDEuNC45IDEuNCAxLjggMCAxLjItLjggMS45LTIuMSAxLjloLTMuM3YtNy4xem0zIDMuMWMuOCAwIDEuMi0uNSAxLjItMS4yIDAtLjYtLjQtMS4yLTEuMi0xLjJoLTIuMnYyLjNoMi4yem0wIDMuM2MuOCAwIDEuMy0uNSAxLjMtMS4ycy0uNS0xLjItMS4zLTEuMmgtMi4ydjIuNWgyLjJ6Ii8+PHBhdGggZD0ibTI3LjMgMzMuOWMwLTIuMiAxLjYtMy43IDMuNy0zLjcgMS4zIDAgMi4yLjYgMi43IDEuNGwtLjguNGMtLjQtLjYtMS4yLTEtMi0xLTEuNiAwLTIuOCAxLjItMi44IDIuOXMxLjIgMi45IDIuOCAyLjljLjggMCAxLjYtLjQgMi0xbC44LjRjLS42LjgtMS41IDEuNC0yLjcgMS40LTIuMSAwLTMuNy0xLjUtMy43LTMuN3oiLz48L2c+PHBhdGggZD0ibTE1LjkgMjIuM2M1LjktNC43IDkuOC04LjEgOS44LTExLjQgMC0yLjUtMi0zLjUtMy45LTMuNS0yLjEgMC0zLjguOS00LjcgMi4zbC0xLS45YzEuMi0xLjggMy4zLTIuOCA1LjctMi44IDIuNSAwIDUuNCAxLjQgNS40IDQuOSAwIDMuOC00IDcuMy05IDExLjNoOS4xdjEuM2gtMTEuNHoiLz48L2c+PC9zdmc+"] = 2,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMC4yIDMwLjNoMi41YzIuMiAwIDMuNyAxLjYgMy43IDMuNnMtMS41IDMuNi0zLjcgMy42aC0yLjV6bTIuNSA2LjRjMS43IDAgMi44LTEuMiAyLjgtMi44IDAtMS41LTEtMi44LTIuOC0yLjhoLTEuNnY1LjZ6Ii8+PHBhdGggZD0ibTE5LjkgMzAuM2g0Ljd2LjhoLTMuOHYyLjNoMy43di44aC0zLjd2Mi41aDMuOHYuOGgtNC43eiIvPjxwYXRoIGQ9Im0yOC4xIDMwLjNoNC43di44aC0zLjh2Mi4zaDMuN3YuOGgtMy43djMuM2gtLjl6Ii8+PC9nPjxwYXRoIGQ9Im0xNi4zIDIwLjFjMSAxLjQgMi42IDIuNCA0LjggMi40IDIuNyAwIDQuMy0xLjQgNC4zLTMuNyAwLTIuNS0yLTMuNS00LjYtMy41LS43IDAtMS4zIDAtMS42IDB2LTEuM2gxLjZjMi4zIDAgNC40LTEgNC40LTMuMyAwLTIuMS0xLjktMy4zLTQuMS0zLjMtMiAwLTMuNC44LTQuNiAyLjJsLS45LS45YzEuMi0xLjUgMy4xLTIuNyA1LjYtMi43IDMgMCA1LjYgMS42IDUuNiA0LjYgMCAyLjYtMi4yIDMuOC0zLjcgNCAxLjUuMiA0IDEuNCA0IDQuM3MtMi4xIDQuOS01LjggNC45Yy0yLjggMC00LjktMS4zLTUuOS0yLjl6Ii8+PC9nPjwvc3ZnPg=="] = 3,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMy42IDMwLjJjMS4zIDAgMi4yLjYgMi44IDEuM2wtLjcuNWMtLjUtLjYtMS4yLTEtMi4xLTEtMS42IDAtMi44IDEuMi0yLjggMi45czEuMiAyLjkgMi44IDIuOWMuOSAwIDEuNi0uNCAxLjktLjh2LTEuNWgtMi41di0uOGgzLjR2Mi42Yy0uNy43LTEuNiAxLjItMi44IDEuMi0yIDAtMy43LTEuNS0zLjctMy43czEuNy0zLjYgMy43LTMuNnoiLz48cGF0aCBkPSJtMjUuMSAzNC4yaC00LjJ2My4zaC0uOXYtNy4yaC45djMuMWg0LjJ2LTMuMWguOXY3LjJoLS45eiIvPjxwYXRoIGQ9Im0yOS44IDMwLjNoLjl2Ny4yaC0uOXoiLz48L2c+PHBhdGggZD0ibTIzLjYgMTguOGgtOC4ydi0xLjNsNy43LTExLjJoMnYxMS4yaDIuNXYxLjNoLTIuNXY0LjdoLTEuNXptLTYuNy0xLjNoNi43di05Ljd6Ii8+PC9nPjwvc3ZnPg=="] = 4,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMS42IDM2LjFjLjMuNC43LjcgMS40LjcuOSAwIDEuNC0uNiAxLjQtMS41di01aC45djVjMCAxLjYtMSAyLjMtMi4zIDIuMy0uOCAwLTEuNC0uMi0xLjktLjh6Ii8+PHBhdGggZD0ibTIwLjcgMzQuMy0uNy44djIuNGgtLjl2LTcuMmguOXYzLjdsMy4yLTMuN2gxLjFsLTMgMy40IDMuMiAzLjhoLTEuMXoiLz48cGF0aCBkPSJtMjcuNyAzMC4zaC45djYuNGgzLjR2LjhoLTQuMnYtNy4yeiIvPjwvZz48cGF0aCBkPSJtMTcuNCAyMC4xYzEuMSAxLjYgMi42IDIuNSA0LjggMi41IDIuNSAwIDQuMy0xLjggNC4zLTQuMiAwLTIuNi0xLjgtNC4yLTQuMy00LjItMS42IDAtMi45LjUtNC4yIDEuN2wtMS0uNnYtOWgxMHYxLjNoLTguNXY2LjhjLjktLjggMi4zLTEuNiA0LjEtMS42IDIuOSAwIDUuNSAxLjkgNS41IDUuNSAwIDMuNC0yLjYgNS42LTUuOCA1LjYtMi45IDAtNC42LTEuMS01LjgtMi44eiIvPjwvZz48L3N2Zz4="] = 5,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMy45IDMxLjYtMi40IDUuOWgtLjRsLTIuNC01Ljl2NS45aC0uOXYtNy4yaDEuM2wyLjIgNS40IDIuMi01LjRoMS4zdjcuMmgtLjl6Ii8+PHBhdGggZD0ibTE5LjUgMzEuOHY1LjdoLS45di03LjJoLjlsNC4xIDUuNnYtNS42aC45djcuMmgtLjl6Ii8+PHBhdGggZD0ibTMxLjcgMzAuMmMyLjEgMCAzLjYgMS42IDMuNiAzLjdzLTEuNCAzLjctMy42IDMuN2MtMi4xIDAtMy42LTEuNi0zLjYtMy43czEuNC0zLjcgMy42LTMuN3ptMCAuOGMtMS43IDAtMi43IDEuMi0yLjcgMi45czEgMi45IDIuNiAyLjkgMi42LTEuMiAyLjYtMi45Yy4xLTEuNy0uOS0yLjktMi41LTIuOXoiLz48L2c+PHBhdGggZD0ibTIyLjYgNmMyLjMgMCAzLjYuOSA0LjcgMi4ybC0uOSAxLjFjLS44LTEuMS0xLjktMS45LTMuOC0xLjktMy43IDAtNS4xIDMuOS01LjEgNy42di44Yy43LTEuMiAyLjctMi45IDUtMi45IDMuMSAwIDUuNiAxLjggNS42IDUuNSAwIDIuOC0yLjEgNS41LTUuOCA1LjUtNC43IDAtNi4zLTQuMy02LjMtOC45IDAtNC41IDEuOC05IDYuNi05em0tLjMgOC4yYy0xLjkgMC0zLjcgMS4yLTQuNyAzIC4yIDIuNCAxLjQgNS40IDQuNyA1LjQgMyAwIDQuMy0yLjMgNC4zLTQuMSAwLTIuOS0xLjgtNC4zLTQuMy00LjN6Ii8+PC9nPjwvc3ZnPg=="] = 6,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im01IDMwLjRoMi45YzEuNCAwIDIuMiAxIDIuMiAyLjJzLS44IDIuMi0yLjIgMi4yaC0ydjIuOWgtLjl6bTIuOC44aC0xLjl2Mi44aDEuOWMuOSAwIDEuNC0uNiAxLjQtMS40cy0uNS0xLjQtMS40LTEuNHoiLz48cGF0aCBkPSJtMTkuMyAzNi43LjcuNy0uNi41LS43LS43Yy0uNS4zLTEuMi41LTEuOS41LTIuMSAwLTMuNi0xLjYtMy42LTMuN3MxLjQtMy43IDMuNi0zLjdjMi4xIDAgMy42IDEuNiAzLjYgMy43LS4xIDEuMS0uNCAyLTEuMSAyLjd6bS0xLjItLjEtMS0xLjEuNi0uNSAxIDEuMWMuNC0uNS43LTEuMi43LTIgMC0xLjctMS0yLjktMi42LTIuOXMtMi42IDEuMi0yLjYgMi45IDEgMi45IDIuNiAyLjljLjUtLjEuOS0uMiAxLjMtLjR6Ii8+PHBhdGggZD0ibTI2LjIgMzQuOGgtMS40djIuOWgtLjl2LTcuMmgyLjljMS4zIDAgMi4yLjggMi4yIDIuMiAwIDEuMy0uOSAyLTEuOSAyLjFsMS45IDIuOWgtMXptLjQtMy42aC0xLjl2Mi44aDEuOWMuOCAwIDEuNC0uNiAxLjQtMS40LjEtLjgtLjUtMS40LTEuNC0xLjR6Ii8+PHBhdGggZD0ibTMyLjcgMzUuOWMuNS41IDEuMiAxIDIuMyAxIDEuMyAwIDEuNy0uNyAxLjctMS4yIDAtLjktLjktMS4xLTEuOC0xLjQtMS4yLS4zLTIuNC0uNi0yLjQtMiAwLTEuMiAxLjEtMiAyLjUtMiAxLjEgMCAxLjkuNCAyLjUgMWwtLjcuN2MtLjUtLjYtMS4zLS45LTIuMS0uOS0uOSAwLTEuNS41LTEuNSAxLjEgMCAuNy44LjkgMS43IDEuMiAxLjIuMyAyLjUuNyAyLjUgMi4yIDAgMS0uNyAyLjEtMi42IDIuMS0xLjIgMC0yLjItLjUtMi44LTEuMXoiLz48L2c+PHBhdGggZD0ibTI0LjkgNy42aC05LjV2LTEuM2gxMS4zdjFsLTcuNCAxNi4yaC0xLjZ6Ii8+PC9nPjwvc3ZnPg=="] = 7,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im0xMS44IDMxLjFoLTIuM3YtLjhoNS40di44aC0yLjN2Ni40aC0uOXYtNi40eiIvPjxwYXRoIGQ9Im0xOC4zIDMwLjNoLjl2NC40YzAgMS4zLjcgMi4xIDIgMi4xczItLjggMi0yLjF2LTQuNGguOXY0LjRjMCAxLjgtMSAyLjktMi45IDIuOXMtMi45LTEuMi0yLjktMi45eiIvPjxwYXRoIGQ9Im0yNy4yIDMwLjNoMWwyLjQgNi4yIDIuNC02LjJoMWwtMi45IDcuMmgtMS4xeiIvPjwvZz48cGF0aCBkPSJtMjAuMyAxNC43Yy0yLS41LTQtMS45LTQtNC4yIDAtMy4xIDIuOC00LjUgNS42LTQuNSAyLjcgMCA1LjYgMS40IDUuNiA0LjUgMCAyLjMtMiAzLjYtNCA0LjIgMi4yLjYgNC4zIDIuMiA0LjMgNC42IDAgMi44LTIuNSA0LjYtNS44IDQuNnMtNS45LTEuOC01LjktNC42Yy0uMS0yLjUgMi00LjEgNC4yLTQuNnptMS42LjZjLTEuMS4xLTQuNCAxLjItNC40IDMuOCAwIDIuMSAyLjEgMy40IDQuNCAzLjRzNC40LTEuMyA0LjQtMy40YzAtMi42LTMuNC0zLjYtNC40LTMuOHptMC03LjljLTIuMyAwLTQuMSAxLjItNC4xIDMuMyAwIDIuNCAzLjEgMy4yIDQuMSAzLjQgMS4xLS4yIDQuMS0xIDQuMS0zLjQgMC0yLjEtMS44LTMuMy00LjEtMy4zeiIvPjwvZz48L3N2Zz4="] = 8,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIGZpbGw9IiMwMDM4ODMiPjxnIGVuYWJsZS1iYWNrZ3JvdW5kPSJuZXciPjxwYXRoIGQ9Im03LjYgMzEuNy0xLjYgNS44aC0xbC0yLTcuMmgxbDEuNiA2IDEuNi02aC44bDEuNiA2IDEuNi02aDFsLTIgNy4yaC0xeiIvPjxwYXRoIGQ9Im0xOCAzNC40LTIuMyAzLjFoLTEuMWwyLjgtMy43LTIuNi0zLjVoMS4xbDIuMSAyLjkgMi4xLTIuOWgxLjFsLTIuNiAzLjUgMi44IDMuN2gtMS4xeiIvPjxwYXRoIGQ9Im0yNi42IDM0LjUtMi44LTQuMWgxbDIuMiAzLjMgMi4yLTMuM2gxbC0yLjggNC4xdjNoLS45di0zeiIvPjxwYXRoIGQ9Im0zMy4xIDM2LjggNC01LjZoLTR2LS44aDUuMnYuN2wtNCA1LjZoNC4xdi44aC01LjJ2LS43eiIvPjwvZz48cGF0aCBkPSJtMTcuNyAyMC42Yy44IDEuMSAxLjkgMS45IDMuOCAxLjkgMy44IDAgNS4xLTQgNS4xLTcuNnYtLjhjLS44IDEuMi0yLjcgMi45LTUuMSAyLjktMy4xIDAtNS42LTEuOC01LjYtNS41LjEtMi44IDIuMi01LjUgNS45LTUuNSA0LjcgMCA2LjMgNC4zIDYuMyA4LjkgMCA0LjQtMS44IDguOS02LjYgOC45LTIuMyAwLTMuNi0uOS00LjYtMi4yem00LjEtMTMuMmMtMyAwLTQuMyAyLjMtNC4zIDQuMSAwIDIuOCAxLjkgNC4yIDQuMyA0LjIgMS45IDAgMy43LTEuMiA0LjctMy0uMi0yLjMtMS40LTUuMy00LjctNS4zeiIvPjwvZz48L3N2Zz4="] = 9,
  ["PHN2ZyBlbmFibGUtYmFja2dyb3VuZD0ibmV3IDAgMCA0MiA0MiIgdmlld0JveD0iMCAwIDQyIDQyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxwYXRoIGQ9Im0yMS41IDZjNC42IDAgNi40IDQuOCA2LjQgOC45cy0xLjggOC45LTYuNCA4LjljLTQuNyAwLTYuNC00LjgtNi40LTguOXMxLjgtOC45IDYuNC04Ljl6bTAgMS40Yy0zLjYgMC00LjggNC00LjggNy42IDAgMy41IDEuMiA3LjYgNC44IDcuNnM0LjgtNCA0LjgtNy42LTEuMi03LjYtNC44LTcuNnoiIGZpbGw9IiMwMDM4ODMiLz48L3N2Zz4="] = 0,
}

local function is_logged_in(html)
  return html:find('href="/se-deconnecter"', 1, true) ~= nil
end

--- woob sets this before its first request; the site appears to gate the new boursobank.com
--- domain's pages on it.
local function set_domain_migration_cookie()
  fyde.http.set_cookie(BASE .. "/", "brsDomainMigration=migrated; Path=/")
end

--- GETs `url`, solving the `__brs_mit` JS cookie stub first if that's what came back.
local function with_brs_mit(url)
  local resp = fyde.http.get(url)
  local mit = resp.body:match('document%.cookie="__brs_mit=(%x+)')
  if not mit then
    return resp
  end
  if not fyde.http.set_cookie then
    error("site requires the __brs_mit JS cookie, but this host has no fyde.http.set_cookie")
  end
  fyde.log.info("solving __brs_mit cookie stub")
  fyde.http.set_cookie(BASE .. "/", "__brs_mit=" .. mit .. "; Domain=.clients.boursobank.com; Path=/")
  resp = fyde.http.get(url)
  if resp.body:find("__brs_mit=", 1, true) and #resp.body < 2000 then
    error("still served the __brs_mit stub after setting the cookie")
  end
  return resp
end

local function first_attr(html, selector, attr)
  local found = fyde.html.select(html, selector)
  if found[1] then
    return found[1].attrs[attr]
  end
  return nil
end

--- Maps each digit to its matrix key on this keypad instance.
local function parse_keypad(html)
  local keys = {}
  local buttons = fyde.html.select(html, "[data-matrix-key]")
  for _, button in ipairs(buttons) do
    local img = fyde.html.select(button.html, "img")[1]
    local src = img and img.attrs.src or ""
    local b64 = src:match("base64,%s*([A-Za-z0-9+/=]+)")
    local digit = b64 and KEYPAD_DIGITS[b64]
    if digit == nil then
      fyde.log.warn("unknown keypad image: " .. (b64 or src))
    else
      keys[digit] = button.attrs["data-matrix-key"]
    end
  end
  return keys, #buttons
end

local function login(username, password)
  -- Mirrors woob's boursorama module (modules/boursorama, PasswordPage.enter_password), which
  -- is maintained against the live site: password page for the token, keypad, then one POST.
  local page = with_brs_mit(URL_LOGIN)
  local token = first_attr(page.body, "input#form__token", "value")
  if not token then
    error("login page has no form[_token] input (status " .. page.status .. ", url " .. page.url .. ")")
  end
  fyde.log.info("LOGIN_PAGE_FOUND")

  -- The keypad only has digits 0-9 and the page asks for "les 8 chiffres": reject anything else
  -- before burning a (lockout-counted) login attempt on it.
  if not password:match("^%d%d%d%d%d%d%d%d$") then
    fyde.log.warn("password must be the 8-digit BoursoBank code (got " .. #password .. " chars)")
    error("INVALID_CREDENTIALS", 0)
  end

  -- Same rule the site's own JS applies (new-forms.js `submitLogin`): 6 to 12 characters. A
  -- 16-digit card/account number here is the classic mistake.
  if #username < 6 or #username > 12 then
    fyde.log.warn("username must be the BoursoBank client ID (6-12 characters, got " .. #username .. ")")
    error("INVALID_CREDENTIALS", 0)
  end

  -- Step 2: the virtual keypad (loaded via hinclude on the password step).
  local keyboard = fyde.http.get(URL_KEYBOARD)
  local challenge = keyboard.body:match('val%("([^"]+)"%)')
  if not challenge then
    error("virtual keypad has no matrixRandomChallenge (status " .. keyboard.status .. ")")
  end
  local keys, count = parse_keypad(keyboard.body)
  fyde.log.info(string.format("virtual keypad: %d button(s)", count))
  local encoded = {}
  for c in password:gmatch(".") do
    local key = keys[tonumber(c)]
    if not key then
      error("could not map password digit to a virtual keypad key")
    end
    table.insert(encoded, key)
  end

  -- Step 3: the final form submit, to the password page itself (the form has no action). Start
  -- from every form[...] input's default value (passwordAck stays {"js":false}, as woob sends
  -- it), then fill in what woob fills in - including its two extra top-level fields.
  local form = {}
  for _, input in ipairs(fyde.html.select(page.body, 'input[name^="form["]')) do
    form[input.attrs.name] = input.attrs.value or ""
  end
  form["form[clientNumber]"] = username
  form["form[password]"] = table.concat(encoded, "|")
  form["form[fakePassword]"] = string.rep("\226\128\162", #password) -- "•" per digit
  form["form[matrixRandomChallenge]"] = challenge
  form["form[_token]"] = token
  form["platformAuthenticatorAvailable"] = "-1"
  form["_token"] = token
  return fyde.http.post_form(URL_LOGIN, form)
end

local function trim(text)
  return (text:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function sanitize(name)
  name = name:gsub("%c", "")
  name = trim(name)
  name = name:gsub('[<>:"/\\|%?%*]', "-")
  if #name > 150 then
    name = name:sub(1, 150)
  end
  if name == "" then
    name = "document"
  end
  return name
end

local function html_unescape(text)
  return (text:gsub("&amp;", "&"))
end

--- Parses the document rows of one page of a /documents/* table. The four sections use three
--- slightly different row layouts, all handled here:
---   * releves / compte-bancaire: `td.documents__name a`, `td.documents__account`;
---   * ifu: the link is `a.documents__name` directly;
---   * coffre-fort (releves-autres-banques): `tr[data-id]` is the document id, the link opens a
---     viewer, and the source bank is in `td.documents__type`. The viewer page links to
---     `/documents/coffre-fort/telecharger?documentId=<id>` for the original file, so that URL is
---     built straight from the id instead of fetching the viewer.
local function parse_rows(html)
  local rows = {}
  for _, tr in ipairs(fyde.html.select(html, "tr.table__line")) do
    -- A bare <tr> outside a <table> gets dropped by the HTML parser, taking its cells with it.
    local row_html = "<table>" .. tr.html .. "</table>"
    local link = fyde.html.select(row_html, "a.documents__name[href]")[1]
      or fyde.html.select(row_html, "td.documents__name a[href]")[1]
      or fyde.html.select(row_html, 'a[href*="coffre-fort/visualiser?documentId="]')[1]
    if link then
      local url = html_unescape(link.attrs.href)
      local id = tr.attrs["data-id"]
      if id and url:find("coffre-fort/visualiser", 1, true) then
        url = "/documents/coffre-fort/telecharger?documentId=" .. id
      end
      if url:sub(1, 1) == "/" then
        url = BASE .. url
      end
      local account = fyde.html.select(row_html, "td.documents__account")[1]
        or fyde.html.select(row_html, "td.documents__type")[1]
      local date = fyde.html.select(row_html, "td.documents__date")[1]
      date = date and trim(date.text) or ""
      local name = trim(link.text)
      -- ifu's link text repeats the date after the title.
      if date ~= "" and name:sub(-#date) == date then
        name = trim(name:sub(1, -#date - 1))
      end
      table.insert(rows, { name = name, url = url, account = account and trim(account.text) or "", date = date })
    end
  end
  return rows
end

local function lower_has(text, needle)
  return text:lower():find(needle, 1, true) ~= nil
end

-- The sections doc-downloaders/scrapers/boursorama scrapes, in the same order. `next(html,
-- index)` returns the URL of the page after page `index` (nil when there's none); `years`
-- walks the fiscal-year <select> instead; `keep` filters rows; `fields` gives upload metadata.
local SECTIONS = {
  {
    -- Every account's statements, exports, annual fee summaries and contracts; 20 rows per
    -- page, older ones behind a "load more" link (data-documents-next-pagination-url).
    slug = "releves",
    url = BASE .. "/documents/releves",
    next = function(html)
      local next_url = first_attr(html, "[data-documents-next-pagination-url]",
        "data-documents-next-pagination-url")
      return next_url and html_unescape(next_url)
    end,
    fields = function(row)
      return { type = lower_has(row.name, "contrat") and "contract" or "statement" }
    end,
  },
  {
    -- Other banks' statements collected into the coffre-fort; numbered ?page=N pagination.
    slug = "releves_autres_banques",
    url = BASE .. "/documents/coffre-fort/factures/releves-autres-banques?page=1",
    next = function(_, index)
      return BASE .. "/documents/coffre-fort/factures/releves-autres-banques?page=" .. (index + 1)
    end,
    fields = function(row)
      -- Not only statements: subscriptions/contracts and invoices land here too.
      local doc_type = "statement"
      if lower_has(row.name, "souscription") or lower_has(row.name, "contrat") then
        doc_type = "contract"
      elseif lower_has(row.name, "factur") then
        doc_type = "invoice"
      end
      return { type = doc_type }
    end,
  },
  {
    -- Tax documents (IFU, IFI attestations), one fiscal year at a time via the
    -- documents_bank_ifu_type[period] <select> (a GET form); see `years` below.
    slug = "ifu",
    url = BASE .. "/documents/ifu",
    years = true,
    fields = function()
      return { type = "tax_certificate", category = "taxes", subcategory = "tax_certificates" }
    end,
  },
  {
    -- Only the RIBs: the rest of this list is one "certificat de virement" per transfer, which
    -- doc-downloaders' link filter (`/telecharger`) skips too. RIBs are generated on the fly
    -- and dated today, so they're always on the first page.
    slug = "rib",
    url = BASE .. "/documents/compte-bancaire",
    keep = function(row)
      return row.url:find("/telecharger", 1, true) ~= nil
    end,
    fields = function()
      return { type = "rib" }
    end,
  },
}

--- Every page URL a section's documents live on, fetched and parsed into rows (deduplicated by
--- download URL - numbered pagination past the last page just repeats or empties).
local function list_section(section)
  local rows, seen = {}, {}
  -- Only a section's first page is a full page with the logout link; "load more" responses
  -- are bare fragments.
  local function add_page(url, check_login)
    local resp = fyde.http.get(url)
    if check_login and not is_logged_in(resp.body) then
      error(section.slug .. ": page is not logged in (landed on " .. resp.url .. ")")
    end
    local added = 0
    for _, row in ipairs(parse_rows(resp.body)) do
      if not seen[row.url] and (not section.keep or section.keep(row)) then
        seen[row.url] = true
        table.insert(rows, row)
        added = added + 1
      end
    end
    return resp.body, added
  end

  if section.years then
    local first = fyde.http.get(section.url)
    local years = {}
    for _, option in ipairs(fyde.html.select(first.body, 'select[name="documents_bank_ifu_type[period]"] option')) do
      table.insert(years, option.attrs.value)
    end
    for _, year in ipairs(years) do
      local _, added = add_page(section.url .. "?documents_bank_ifu_type%5Bperiod%5D=" .. year, true)
      fyde.log.info(string.format("%s %s: %d document(s)", section.slug, year, added))
    end
    return rows
  end

  local url = section.url
  for index = 1, MAX_PAGES do
    local html, added = add_page(url, index == 1)
    fyde.log.info(string.format("%s page %d: %d new document(s)", section.slug, index, added))
    local next_url = section.next and section.next(html, index)
    if added == 0 or not next_url then
      break
    end
    url = next_url
  end
  return rows
end

local used_filenames = {}

--- `title.pdf`, or `title (2).pdf`, ... when another document already took that name (the
--- coffre-fort has several identically-titled statements).
local function unique_filename(title)
  local base = sanitize(title)
  local count = (used_filenames[base] or 0) + 1
  used_filenames[base] = count
  if count == 1 then
    return base .. ".pdf"
  end
  return string.format("%s (%d).pdf", base, count)
end

local function download_rows(section, rows)
  local saved = 0
  for i, row in ipairs(rows) do
    local title = row.name
    if row.account ~= "" and not row.name:find(row.account, 1, true) then
      title = row.name .. " - " .. row.account
    end
    fyde.progress.update(i, #rows, title)
    local download = fyde.http.download(row.url)
    local content_type = download.content_type or ""
    if download.status == 200 and not content_type:find("html", 1, true) then
      local fields = section.fields(row)
      fields.name = title
      if not fields.category then
        fields.category, fields.subcategory = "money", "banking"
      end
      fyde.save_document(unique_filename(title), download.body, fields)
      saved = saved + 1
    else
      fyde.log.warn(string.format("%s: failed to download '%s' (status %d, content-type %s)",
        section.slug, title, download.status, content_type))
    end
  end
  return saved
end

-- Login error contract shared with every scraper (see
-- README.md): a rejected username/password fails with exactly INVALID_CREDENTIALS, a rejected
-- or unanswered one-time code with exactly MFA_FAILED.
function M.run(params)
  fyde.progress.step("Checking for an existing session")
  set_domain_migration_cookie()
  local home = with_brs_mit(URL_DASHBOARD)
  if is_logged_in(home.body) then
    fyde.log.info("restored session is still valid, skipping login")
    fyde.log.info("ALREADY_LOGGED_IN")
  else
    fyde.progress.step("Logging in")
    local resp = login(params.username, params.password)
    if resp.status >= 400 then
      error("login request failed with HTTP status " .. resp.status)
    end
    home = is_logged_in(resp.body) and resp or fyde.http.get(URL_DASHBOARD)
    if not is_logged_in(home.body) then
      -- No logout link after posting the virtual-keypad password: the credentials were refused.
      fyde.log.warn("login failed: no logout link after submitting credentials (landed on " .. home.url .. ")")
      error("INVALID_CREDENTIALS", 0)
    end
    fyde.log.info("login succeeded")
  end

  for _, section in ipairs(SECTIONS) do
    fyde.progress.step("Section " .. section.slug)
    local rows = list_section(section)
    local saved = download_rows(section, rows)
    fyde.log.info(string.format("%s: %d/%d document(s) saved", section.slug, saved, #rows))
  end

  fyde.progress.step("Done")
end

return M
