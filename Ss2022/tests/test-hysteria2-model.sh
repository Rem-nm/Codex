#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for command_name in jq openssl base64 python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || { printf '%s is required\n' "$command_name" >&2; exit 77; }
done

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/certs.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/system.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/singbox.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/traffic.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/bandwidth.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/nodes.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/links.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
CONFIG_DIR="$TEST_TMP/config"
DATA_DIR="$TEST_TMP/data"
RUNTIME_DIR="$TEST_TMP/run"
BACKUP_DIR="$CONFIG_DIR/backups"
CERTS_DIR="$CONFIG_DIR/certs"
MANAGER_STATE="$CONFIG_DIR/manager.json"
NODES_FILE="$DATA_DIR/nodes.json"
TRAFFIC_FILE="$DATA_DIR/traffic.json"
HISTORY_FILE="$DATA_DIR/traffic-history.json"
INTERFACES_FILE="$DATA_DIR/interfaces.json"
COUNTERS_FILE="$DATA_DIR/tc-counters.json"
TRANSACTION_LOCK="$RUNTIME_DIR/manager.lock"
STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
SING_BOX_CONFIG="$TEST_TMP/sing-box.json"
mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
printf '%s\n' '{"listen_mode":"ipv4","tfo_config_supported":false,"tfo_kernel_enabled":false}' >"$MANAGER_STATE"
printf '%s\n' '{"schema_version":3,"nodes":[]}' >"$NODES_FILE"
printf '%s\n' '{"schema_version":1,"nodes":{}}' >"$TRAFFIC_FILE"
printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$HISTORY_FILE"
printf '%s\n' '{"schema_version":1,"interfaces":["eth0"]}' >"$INTERFACES_FILE"

fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3"; }

node_id=0123456789abcdef0123456789abcdef
expected_sni=$(hysteria2_server_name_for_node "$node_id") || fail 'could not derive stable Hysteria2 SNI'
[[ "$expected_sni" == "hy2-${node_id}.invalid" ]] || fail 'Hysteria2 SNI is not Node ID-derived'
record="$TEST_TMP/hy2.json"
candidate_certs=$(hysteria2_make_candidate_cert_root) || fail 'could not create certificate candidate root'
password=$(generate_hysteria2_password) || fail 'could not generate Hysteria2 password'
sni="$expected_sni"
pin=$(hysteria2_generate_certificate "$candidate_certs" "$node_id" "$sni") || fail 'could not generate Hysteria2 certificate'
node_new_hysteria2_record 'Tokyo HY2' 24444 192.0.2.10 ipv4 "$node_id" "$password" "$sni" "$pin" >"$record" || fail 'could not build Hysteria2 node record'
jq -e . "$record" >/dev/null || fail 'Hysteria2 record is not JSON'
jq --slurpfile record "$record" '.nodes += [$record[0]]' "$NODES_FILE" >"$NODES_FILE.next" && mv "$NODES_FILE.next" "$NODES_FILE"
validate_nodes_file_semantic "$NODES_FILE" || fail 'valid Hysteria2 node was rejected'
validate_hysteria2_certificate_state "$NODES_FILE" "$candidate_certs" || fail 'generated certificate failed semantic validation'

config="$TEST_TMP/config.json"
generate_singbox_config "$NODES_FILE" "$config" "$candidate_certs" || fail 'Hysteria2 config generation failed'
jq -e --arg id "$node_id" --arg pin "$pin" --arg root "$candidate_certs" --arg sni "$sni" '
  (.inbounds | length) == 1
  and .inbounds[0].type == "hysteria2"
  and .inbounds[0].tag == ("hy2-" + $id)
  and .inbounds[0].listen_port == 24444
  and .inbounds[0].users[0].password != null
  and .inbounds[0].tls.enabled == true
  and .inbounds[0].tls.server_name == $sni
  and .inbounds[0].tls.certificate_path == ($root + "/" + $id + "/cert.pem")
  and .inbounds[0].tls.key_path == ($root + "/" + $id + "/key.pem")
' "$config" >/dev/null || fail 'Hysteria2 inbound structure is wrong'
if [[ -x "$SING_BOX_BINARY" ]]; then
  "$SING_BOX_BINARY" check -c "$config" >/dev/null 2>&1 || fail 'official sing-box rejected Hysteria2 configuration'
fi

node=$(jq -c '.nodes[0]' "$NODES_FILE")
# The model test keeps the generated cert tree as a transaction candidate;
# point the read-only share/detail checks at that candidate just as the live
# manager points them at /etc/ss-manager/certs after publication.
CERTS_DIR="$candidate_certs"
uri=$(node_hysteria2_uri "$node") || fail 'Hysteria2 URI generation failed'
assert_contains "$uri" 'hysteria2://' 'Hysteria2 URI scheme missing'
assert_contains "$uri" "sni=$expected_sni" 'Hysteria2 URI SNI missing'
assert_contains "$uri" "pinSHA256=$pin" 'Hysteria2 URI pin missing'
assert_not_contains "$uri" 'key.pem' 'Hysteria2 URI leaked a private key path'
decoded=$(node_base64_uri "$node" | base64 -d)
[[ "$decoded" == "$uri" ]] || fail 'Hysteria2 Base64 does not decode to URI'

actions="$TEST_TMP/actions.json"
bandwidth_build_actions "$NODES_FILE" "$actions" || fail 'Hysteria2 bandwidth action generation failed'
jq -e 'length == 2 and all(.[]; .protocols == ["udp"])' "$actions" >/dev/null || fail 'Hysteria2 bandwidth transport is not UDP-only'

detail=$(node_show_detail "$node_id") || fail 'Hysteria2 detail display failed'
assert_contains "$detail" 'Hysteria2' 'Hysteria2 detail omitted protocol'
assert_contains "$detail" "$pin" 'Hysteria2 detail omitted certificate pin'
assert_contains "$detail" "$password" 'Hysteria2 detail omitted password'

candidate2=$(hysteria2_make_candidate_cert_root) || fail 'could not create rotation candidate'
pin2=$(hysteria2_generate_certificate "$candidate2" "$node_id" "$sni") || fail 'could not rotate certificate'
[[ "$pin2" != "$pin" ]] || fail 'certificate rotation reused the same leaf certificate'
bad_pin=$(printf '0%.0s' {1..64})
jq --arg pin "$bad_pin" '.nodes[0].certificate_sha256=$pin' "$NODES_FILE" >"$NODES_FILE.bad" || true
if validate_hysteria2_certificate_state "$NODES_FILE.bad" "$candidate2"; then fail 'mismatched certificate pin was accepted'; fi
rm -rf -- "$candidate2" "$candidate_certs"

printf 'Hysteria2 unified-node model tests passed\n'
