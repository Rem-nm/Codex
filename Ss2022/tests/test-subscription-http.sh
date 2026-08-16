#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }
test_tmp=$(mktemp -d)
server_pid=''
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf -- "$test_tmp"; }
trap cleanup EXIT
runtime="$test_tmp/runtime.json"
export_file="$test_tmp/export.json"
token='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
new_token=$(printf 'B%.0s' {1..43})
port=18991
jq -n --arg token "$token" --arg path "$export_file" --argjson port "$port" '{schema_version:1,token:$token,export_path:$path,generated_at:"2026-01-01T00:00:00Z",listen_port:$port}' >"$runtime"
jq -n '{schema_version:1,available:true,generated_at:"2026-01-01T00:00:00Z",node_count:1,failed_nodes:[],raw:"ss://example\n",base64:"c3M6Ly9leGFtcGxlCg==",profile:{log:{disabled:true},inbounds:[],outbounds:[{type:"direct",tag:"rem-direct"}],route:{final:"rem-direct"}},profile_available:true}' >"$export_file"
SS_MANAGER_SUBSCRIPTION_RUNTIME="$runtime" SS_MANAGER_SUBSCRIPTION_EXPORT="$export_file" \
  SS_MANAGER_SUBSCRIPTION_PORT="$port" python3 "$ROOT/subscription/ss-manager-subscription.py" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 20); do curl -sS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
status=$(curl -sS -o "$test_tmp/body" -w '%{http_code}' "http://127.0.0.1:$port/sub/$token/raw")
[[ "$status" == 200 ]] || fail 'valid raw request was not accepted'
grep -Fqx 'ss://example' "$test_tmp/body" || fail 'raw body mismatch'
headers=$(curl -sS -D - -o /dev/null "http://127.0.0.1:$port/sub/$token")
grep -Fqi 'Cache-Control: no-store' <<<"$headers" || fail 'no-store header missing'
grep -Fqi 'X-Content-Type-Options: nosniff' <<<"$headers" || fail 'nosniff header missing'
grep -Fqi 'Referrer-Policy: no-referrer' <<<"$headers" || fail 'referrer policy header missing'
status=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/sub/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/raw")
[[ "$status" == 404 ]] || fail 'wrong token did not return 404'
status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/sub/$token/raw")
[[ "$status" == 405 ]] || fail 'unsupported method did not return 405'
python3 - "$port" "$token" <<'PY' || fail 'HEAD returned a body or wrong status'
import http.client
import sys
conn = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=3)
conn.request("HEAD", "/sub/" + sys.argv[2] + "/raw")
response = conn.getresponse()
body = response.read()
if response.status != 200 or body:
    raise SystemExit(1)
PY
jq --arg token "$new_token" '.token=$token' "$runtime" >"$runtime.next" && mv -f -- "$runtime.next" "$runtime"
status=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/sub/$token/raw")
[[ "$status" == 404 ]] || fail 'old token remained valid after rotation'
status=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/sub/$new_token/raw")
[[ "$status" == 200 ]] || fail 'new token was not accepted after rotation'
printf 'subscription HTTP tests passed\n'
