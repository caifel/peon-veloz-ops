#!/usr/bin/env sh
set -eu

default_schema_url="http://dev-api:4000/swagger/json"
default_ui_dir="/peonveloz/ui"
generated_types_path="src/api/generated/schema.ts"

usage() {
  cat <<'EOF'
usage: sync-api-types.sh [--check]

Refresh the API-backed ui types from the dev API Swagger schema.

From the host, the script starts dev-api and dev-ui if they are not
already running, waits for dev-api Swagger through the Docker network,
then generates or checks ui/src/api/generated/schema.ts.

  --check  Verify generated types are up to date without overwriting.
EOF
}

fetch_openapi_schema() {
  schema_url="$1"
  spec_out="$2"

  SPEC_URL="$schema_url" SPEC_OUT="$spec_out" bun -e '
const url = process.env.SPEC_URL;
const out = process.env.SPEC_OUT;
console.log("Fetching " + url + " ...");
const response = await fetch(url);
if (!response.ok) {
  console.error("Failed to fetch spec: " + response.status + " " + response.statusText);
  process.exit(1);
}
await Bun.write(out, await response.text());
'
}

render_types() {
  schema_url="$1"
  spec="$2"
  generated="$3"

  {
    printf '%s\n' '// Auto-generated from /swagger/json. Do not edit.'
    printf '%s\n' "// Source: $schema_url"
    printf '%s\n' "// Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n\n'
    bun run openapi-typescript "$spec"
  } >"$generated"
}

normalize_generated_timestamp() {
  input="$1"
  output="$2"

  sed 's/^\/\/ Generated: .*$/\/\/ Generated: <timestamp>/' "$input" >"$output"
}

check_generated_types() {
  current="$1"
  generated="$2"

  if [ ! -f "$current" ]; then
    printf '%s\n' 'Generated types file does not exist. Run make api-types first.' >&2
    exit 1
  fi

  current_norm="/tmp/peonveloz-schema-current-normalized.ts"
  generated_norm="/tmp/peonveloz-schema-generated-normalized.ts"

  normalize_generated_timestamp "$current" "$current_norm"
  normalize_generated_timestamp "$generated" "$generated_norm"

  if cmp -s "$current_norm" "$generated_norm"; then
    printf '%s\n' 'Types are up to date.'
    return 0
  fi

  printf '%s\n' 'Types are stale. Run make api-types to regenerate.' >&2
  exit 1
}

generate_types() {
  mode="$1"
  schema_url="$2"
  ui_dir="$3"

  cd "$ui_dir"
  bun install

  spec="/tmp/peonveloz-openapi.json"
  generated="/tmp/peonveloz-schema.ts"
  out="$ui_dir/$generated_types_path"

  fetch_openapi_schema "$schema_url" "$spec"
  render_types "$schema_url" "$spec" "$generated"

  if [ "$mode" = "check" ]; then
    check_generated_types "$out" "$generated"
    return 0
  fi

  mv "$generated" "$out"
  printf 'Types written to %s\n' "$out"
}

wait_for_http() {
  url="$1"
  attempts="$2"
  delay="$3"
  i=1

  while [ "$i" -le "$attempts" ]; do
    if URL="$url" bun -e 'const r = await fetch(process.env.URL); process.exit(r.ok ? 0 : 1)' >/dev/null 2>&1; then
      printf 'dev-api Swagger is reachable: %s\n' "$url"
      return 0
    fi

    sleep "$delay"
    i=$((i + 1))
  done

  printf 'Timed out waiting for dev-api Swagger: %s\n' "$url" >&2
  exit 1
}

run_in_dev_ui() {
  mode="$1"
  schema_url="$2"

  docker compose --env-file .env.development up -d dev-api dev-ui

  docker compose --env-file .env.development exec -T dev-ui sh -s -- \
    --wait-for-http "$schema_url" "${WAIT_FOR_HTTP_ATTEMPTS:-60}" "${WAIT_FOR_HTTP_DELAY:-1}" <"$0"

  docker compose --env-file .env.development exec -T dev-ui sh -s -- \
    --generate "$mode" "$schema_url" "$default_ui_dir" <"$0"
}

if [ "${1:-}" = "--generate" ]; then
  shift
  generate_types "$1" "$2" "$3"
  exit 0
fi

if [ "${1:-}" = "--wait-for-http" ]; then
  shift
  wait_for_http "$1" "$2" "$3"
  exit 0
fi

check_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
  --check)
    check_only=true
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
ops_dir="$(cd "$script_dir/.." && pwd)"
schema_url="${SCHEMA_URL:-$default_schema_url}"

if [ "$check_only" = true ]; then
  mode="check"
else
  mode="write"
fi

cd "$ops_dir"

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' 'Docker CLI is required. Run this script from the host via make api-types or make api-types-check.' >&2
  exit 1
fi

run_in_dev_ui "$mode" "$schema_url"
