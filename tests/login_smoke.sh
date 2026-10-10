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
# Prints one markdown table row per scraper; full logs go to data/smoke/<name>.log.
set -u
cd "$(dirname "$0")/.."

TIMEOUT="${SMOKE_TIMEOUT:-180}"
OUT=data/smoke
mkdir -p "$OUT"

if [ $# -eq 0 ]; then
  set -- $(ls scrapers)
fi

cargo build -q || exit 1

echo "| Scraper | Login page found | Invalid credentials detected | Result |"
echo "|---|---|---|---|"
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
  page=$(grep -q "LOGIN_PAGE_FOUND" "$log" && echo "✅" || echo "❌")
  creds=$(grep -q "INVALID_CREDENTIALS" "$log" && echo "✅" || echo "❌")
  if [ $code -eq 124 ]; then
    result="timeout"
  else
    result=$(grep -m1 -oE "(Error|error)[^\"]{0,120}" "$log" | tr '|' '/' | head -c 120)
  fi
  echo "| $name | $page | $creds | ${result:-exit $code} |"
  rm -rf "$work"
done
