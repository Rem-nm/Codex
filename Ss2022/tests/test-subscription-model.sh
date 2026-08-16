#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/certs.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/system.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/singbox.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/nodes.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/links.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/export.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/subscription.sh"

fail() { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }
test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT
CONFIG_DIR="$test_tmp/config"
DATA_DIR="$test_tmp/data"
RUNTIME_DIR="$test_tmp/run"
BACKUP_DIR="$CONFIG_DIR/backups"
CERTS_DIR="$CONFIG_DIR/certs"
SUBSCRIPTION_CONFIG="$CONFIG_DIR/subscription.json"
SUBSCRIPTION_DIR="$DATA_DIR/subscription"
SUBSCRIPTION_EXPORT="$SUBSCRIPTION_DIR/subscription-export.json"
SUBSCRIPTION_RUNTIME="$SUBSCRIPTION_DIR/subscription-runtime.json"
NODES_FILE="$DATA_DIR/nodes.json"
TRAFFIC_FILE="$DATA_DIR/traffic.json"
HISTORY_FILE="$DATA_DIR/traffic-history.json"
SUBSCRIPTION_SERVICE_GROUP="$(id -gn)"
SING_BOX_BINARY="$test_tmp/sing-box"
INIT_SYSTEM=systemd
subscription_service_disable() { :; }
subscription_service_enable() { :; }
mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$CERTS_DIR"
chmod 700 -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$CERTS_DIR"
cat >"$SING_BOX_BINARY" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 -- "$SING_BOX_BINARY"
subscription_ensure_account() { :; }
test_port=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)

now='2026-01-01T00:00:00Z'
jq -n --arg now "$now" '{schema_version:5,nodes:[
  {node_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"Zulu",protocol:"shadowsocks",method:"2022-blake3-aes-128-gcm",password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",port:30001,address:"203.0.113.1",address_type:"ipv4",status:"enabled",status_reason:"",subscription_enabled:true,quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2025-12-31T00:00:00Z",updated_at:$now,last_reset_at:$now,next_reset_at:"2026-02-01T00:00:00Z"},
  {node_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",name:"Alpha",protocol:"vless",uuid:"11111111-1111-4111-8111-111111111111",flow:"xtls-rprx-vision",reality_private_key:("B"*43),reality_public_key:("D"*43),reality_short_id:"aabbccdd",reality_server_name:"example.com",reality_handshake_server:"example.com",reality_handshake_port:443,port:30002,address:"example.net",address_type:"domain",status:"enabled",status_reason:"",subscription_enabled:true,quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2026-01-01T00:00:00Z",updated_at:$now,last_reset_at:$now,next_reset_at:"2026-02-01T00:00:00Z"},
  {node_id:"cccccccccccccccccccccccccccccccc",name:"Disabled",protocol:"shadowsocks",method:"2022-blake3-aes-128-gcm",password:"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",port:30003,address:"203.0.113.3",address_type:"ipv4",status:"disabled_manual",status_reason:"manual",subscription_enabled:true,quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2025-12-30T00:00:00Z",updated_at:$now,last_reset_at:$now,next_reset_at:"2026-02-01T00:00:00Z"}
]}' >"$NODES_FILE"
# Protocol model/schema validation is covered by the dedicated four-protocol
# tests; this fixture intentionally focuses on the derived export contract.
subscription_initialize || fail 'subscription settings initialization failed'
token=$(subscription_generate_token) || fail 'token generation failed'
subscription_update_settings false 'https://sub.example.com' "$test_port" false || fail 'settings update failed'
subscription_publish_export "$NODES_FILE" || fail 'export publication failed'
jq -e '.available == true and .node_count == 2 and (.failed_nodes | length) == 0' "$SUBSCRIPTION_EXPORT" >/dev/null || fail 'qualification/count failed'
jq -j '.raw' "$SUBSCRIPTION_EXPORT" >"$test_tmp/raw.txt"
[[ "$(wc -l <"$test_tmp/raw.txt")" == 2 ]] || fail 'raw export must contain two URI lines'
jq -r '.base64' "$SUBSCRIPTION_EXPORT" | base64 -d >"$test_tmp/decoded.txt"
cmp -s "$test_tmp/raw.txt" "$test_tmp/decoded.txt" || fail 'base64 must decode to exact raw bytes'
if jq -e '.. | strings | select(contains("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))' "$SUBSCRIPTION_EXPORT" >/dev/null 2>&1; then
  fail 'Reality private key leaked into export'
fi
jq -e '.profile_available == true and (.profile.outbounds | map(.tag) | length) == 4' "$SUBSCRIPTION_EXPORT" >/dev/null || fail 'profile export invalid'
jq -e '.profile.dns.servers[0].type == "local" and .profile.dns.final == "rem-dns"' "$SUBSCRIPTION_EXPORT" >/dev/null \
  || fail 'profile uses deprecated legacy DNS server format'
jq -e '[.profile.outbounds[] | select(.type == "vless")][0].tls.utls == {enabled:true,fingerprint:"chrome"}' "$SUBSCRIPTION_EXPORT" >/dev/null \
  || fail 'VLESS Reality outbound is missing uTLS fingerprint'
subscription_validate_token "$token" || fail 'generated token rejected'
if subscription_validate_public_url 'https://sub.example.com/path' >/dev/null 2>&1; then fail 'URL path was accepted'; fi
false_value=$(jq -r '.subscription_enabled | if type == "boolean" then tostring else empty end' <<<'{"subscription_enabled":false}')
[[ "$false_value" == false ]] || fail 'false subscription boolean was not preserved'
if grep -Eq '^(output_log|error_log)=' "$ROOT/openrc/ss-manager-subscription"; then
  fail 'OpenRC subscription service must not write logs as its low-privilege user'
fi
printf 'subscription model tests passed\n'
