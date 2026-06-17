#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
usage: smoke-test.sh [--api-url URL]

Runs a quick smoke test against the API to verify the stack is healthy.

Checks:
  1. API root endpoint (metadata)
  2. Database connectivity (/health)
  3. Swagger JSON (/swagger/json)
  4. Authentication (login, session cookie, /auth/me)

  5. Logout

Exit code 0 on success, 1 on any failure.
EOF
}

api_url="http://localhost:4000"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-url)
      api_url="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

COOKIE_JAR="$(mktemp /tmp/smoke-cookies.XXXXXX)"

PASS=0
FAIL=0

check() {
  local label="$1"
  local status="$2"
  local detail="${3:-}"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s (HTTP %s)\n' "$label" "$status"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s (HTTP %s)\n' "$label" "$status"
    if [ -n "$detail" ]; then
      printf '    %s\n' "$detail" | head -5
    fi
  fi
}

http_get_status() {
  local path="$1"
  curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$api_url$path" 2>/dev/null || true
}

http_get_body() {
  local path="$1"
  curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$api_url$path" 2>/dev/null || true
}

http_post_json_status() {
  local path="$1"
  local body="$2"
  curl -sS -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$api_url$path" 2>/dev/null || true
}

http_post_json_body() {
  local path="$1"
  local body="$2"
  curl -sS \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$api_url$path" 2>/dev/null || true
}

printf '\nSmoke-testing API at %s...\n\n' "$api_url"

printf 'Waiting for API readiness'
i=0
while [ "$i" -lt 30 ]; do
  if [ "$(http_get_status "/health")" = "200" ]; then
    printf '\n\n'
    break
  fi

  i=$((i + 1))
  printf '.'
  sleep 1
done

if [ "$i" -ge 30 ]; then
  printf '\n\nAPI did not become ready within 30 seconds.\n\n'
fi

# 1. Root
check "GET /" "$(http_get_status "/")"

# 2. Health (DB connectivity)
status=$(http_get_status "/health")
body=$(http_get_body "/health")
check "GET /health" "$status" "$body"

# 3. Swagger JSON
check "GET /swagger/json" "$(http_get_status "/swagger/json")"

# 4. Login
login_body='{"email":"admin@peonveloz.com","password":"admin123"}'
status=$(http_post_json_status "/auth/login" "$login_body")
if [ "$status" = "200" ]; then
  check "POST /auth/login" "$status"
else
  body=$(http_post_json_body "/auth/login" "$login_body")
  check "POST /auth/login" "$status" "$body"
fi

# 5. Get current user (requires session cookie from login)
body=$(http_get_body "/auth/me")
status=$(http_get_status "/auth/me")
if [ "$status" = "200" ]; then
  user_name=$(printf '%s' "$body" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
  check "GET /auth/me" "$status" "user=$user_name"
else
  check "GET /auth/me" "$status" "$body"
fi

# 6. Logout
check "POST /auth/logout" "$(http_post_json_status "/auth/logout" "{}")"

rm -f "$COOKIE_JAR"

printf '\n═══════════════════════════════════════\n'
printf '  Smoke test results: %s pass, %s fail\n' "$PASS" "$FAIL"
printf '═══════════════════════════════════════\n\n'

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
