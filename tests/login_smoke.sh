#!/usr/bin/env bash
# Login smoke test for the scrapers ported from github.com/konnectors (see README.md).
#
# Without real credentials or HAR captures, the only things that can be checked against the
# live sites are:
#   1. the login page is reachable and recognised  -> the run logs LOGIN_PAGE_FOUND
#   2. a made-up username/password is rejected      -> the run fails with INVALID_CREDENTIALS
#
# Each scraper is run once with fake credentials built from its manifest.json parameter
# placeholders (so e.g. numeric-only logins get a numeric value), with a fresh, throwaway
# storage directory (no restored session) and stdin closed (any OTP prompt gets no answer).
#
# Usage: tests/login_smoke.sh [scraper ...]   (default: every scraper under scrapers/)
# Writes both results into each scraper's manifest.json `status` (`login_page_found` and
# `invalid_credentials_detected`, as "passed"/"failed" - an `invalid_credentials_detected` of
# "not_applicable", i.e. a passwordless login, is left alone), and prints one summary line per
# scraper; full logs go to data/smoke/<name>.log.
set -u
cd "$(dirname "$0")/.."

TIMEOUT="${SMOKE_TIMEOUT:-180}"
OUT=data/smoke
mkdir -p "$OUT"

if [ $# -eq 0 ]; then
  set -- $(ls scrapers)
fi

cargo build -q || exit 1

for name in "$@"; do
  work="$(mktemp -d)"
  python3 - "$name" "$work/secrets.json" <<'PY'
import json, sys
name, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(f"scrapers/{name}/manifest.json"))
params = {}
for key, spec in (manifest.get("parameters") or {"username": {}, "password": {}}).items():
    placeholder = str(spec.get("placeholder", ""))
    if spec.get("secret") or "•" in placeholder:
        params[key] = "fyde-smoke-Wrong-Passw0rd"
    elif placeholder.isdigit():
        params[key] = "1" * len(placeholder)
    elif "@" in placeholder or key in ("username", "login", "email"):
        params[key] = "fyde.smoke.test@example.com"
    else:
        params[key] = placeholder or "fyde-smoke"
json.dump({name: {"parameters": params}}, open(out, "w"))
PY
  log="$OUT/$name.log"
  timeout "$TIMEOUT" target/debug/fyde-scripts run "$name" \
    --secrets "$work/secrets.json" --storage "$work/storage" --documents-dir "$work/documents" \
    </dev/null >"$log" 2>&1
  code=$?
  page=$(grep -q "LOGIN_PAGE_FOUND" "$log" && echo passed || echo failed)
  creds=$(grep -q "INVALID_CREDENTIALS" "$log" && echo passed || echo failed)
  if [ $code -eq 124 ]; then
    result="timeout"
  else
    result=$(grep -m1 -oE "(Error|error)[^\"]{0,120}" "$log" | tr '|' '/' | head -c 120)
  fi
  # Edits only the two fields' values in place, leaving the rest of manifest.json's formatting
  # (e.g. its one-line `allowed_domains` arrays) untouched.
  python3 - "scrapers/$name/manifest.json" "$page" "$creds" <<'PY'
import re, sys
path, page, creds = sys.argv[1:]
text = open(path).read()
def put(text, field, value):
    pattern = rf'("{field}":\s*)"(\w+)"'
    current = re.search(pattern, text)
    if not current:
        sys.exit(f"{path}: no status.{field} to update")
    if current.group(2) == "not_applicable":
        return text
    return re.sub(pattern, rf'\1"{value}"', text, count=1)
text = put(text, "login_page_found", page)
text = put(text, "invalid_credentials_detected", creds)
open(path, "w").write(text)
PY
  echo "$name: login page found: $page, invalid credentials detected: $creds (${result:-exit $code})"
  rm -rf "$work"
done
