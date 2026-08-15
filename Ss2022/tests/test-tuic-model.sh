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
source "$ROOT/lib/backup.sh"
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
printf '%s\n' '{"schema_version":4,"nodes":[]}' >"$NODES_FILE"
printf '%s\n' '{"schema_version":1,"nodes":{}}' >"$TRAFFIC_FILE"
printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$HISTORY_FILE"
printf '%s\n' '{"schema_version":1,"interfaces":["eth0"]}' >"$INTERFACES_FILE"

fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3"; }

node_id=abcdef0123456789abcdef0123456789
uuid=01890f2e-7c6a-7d65-9f31-7d7e6b8f0123
password=$(generate_tuic_password) || fail 'could not generate TUIC password'
sni=$(tuic_server_name_for_node "$node_id") || fail 'could not derive stable TUIC SNI'
[[ "$sni" == "tuic-${node_id}.invalid" ]] || fail 'TUIC SNI is not Node ID-derived'
candidate_certs=$(tls_make_candidate_cert_root) || fail 'could not create shared TLS candidate root'
pin=$(tls_generate_certificate "$candidate_certs" "$node_id" "$sni") || fail 'could not generate TUIC certificate'
record="$TEST_TMP/tuic.json"
node_new_tuic_record 'Tokyo TUIC' 25444 192.0.2.20 ipv4 "$node_id" "$uuid" "$password" "$sni" "$pin" >"$record" \
  || fail 'could not build TUIC node record'
jq --slurpfile record "$record" '.nodes += [$record[0]]' "$NODES_FILE" >"$NODES_FILE.next" \
  && mv "$NODES_FILE.next" "$NODES_FILE"
validate_nodes_file_semantic "$NODES_FILE" || fail 'valid TUIC node was rejected'
validate_tls_certificate_state "$NODES_FILE" "$candidate_certs" || fail 'TUIC certificate state was rejected'

legacy_tuic="$TEST_TMP/legacy-tuic.json"
jq '.schema_version=3' "$NODES_FILE" >"$legacy_tuic"
if validate_nodes_file_semantic "$legacy_tuic"; then fail 'schema 3 incorrectly accepted a TUIC node'; fi
jq '.nodes[0].zero_rtt_handshake=true' "$NODES_FILE" >"$TEST_TMP/tuic-zero-rtt-invalid.json"
if validate_nodes_file_semantic "$TEST_TMP/tuic-zero-rtt-invalid.json"; then
  fail 'TUIC schema accepted enabled 0-RTT'
fi
jq '.nodes[0].private_key_path="/tmp/key.pem"' "$NODES_FILE" >"$TEST_TMP/tuic-path-field-invalid.json"
if validate_nodes_file_semantic "$TEST_TMP/tuic-path-field-invalid.json"; then
  fail 'TUIC schema accepted an injected private-key path'
fi

config="$TEST_TMP/config.json"
generate_singbox_config "$NODES_FILE" "$config" "$candidate_certs" || fail 'TUIC config generation failed'
jq -e --arg id "$node_id" --arg root "$candidate_certs" --arg sni "$sni" --arg uuid "$uuid" '
  (.inbounds | length) == 1
  and .inbounds[0].type == "tuic"
  and .inbounds[0].tag == ("tuic-" + $id)
  and .inbounds[0].listen_port == 25444
  and .inbounds[0].users[0].uuid == $uuid
  and (.inbounds[0].users[0].password | type == "string" and length >= 8)
  and .inbounds[0].congestion_control == "bbr"
  and .inbounds[0].auth_timeout == "3s"
  and .inbounds[0].zero_rtt_handshake == false
  and .inbounds[0].heartbeat == "10s"
  and .inbounds[0].tls.enabled == true
  and .inbounds[0].tls.server_name == $sni
  and .inbounds[0].tls.alpn == ["h3"]
  and .inbounds[0].tls.certificate_path == ($root + "/" + $id + "/cert.pem")
  and .inbounds[0].tls.key_path == ($root + "/" + $id + "/key.pem")
' "$config" >/dev/null || fail 'TUIC inbound structure is wrong'
if [[ -x "$SING_BOX_BINARY" ]]; then
  "$SING_BOX_BINARY" check -c "$config" >/dev/null 2>&1 || fail 'official sing-box rejected TUIC configuration'
fi

node=$(jq -c '.nodes[0]' "$NODES_FILE")
CERTS_DIR="$candidate_certs"
uri=$(node_tuic_uri "$node") || fail 'TUIC URI generation failed'
assert_contains "$uri" "tuic://$uuid:" 'TUIC URI credentials are missing'
assert_contains "$uri" 'congestion_control=bbr' 'TUIC URI congestion control is missing'
assert_contains "$uri" 'alpn=h3' 'TUIC URI ALPN is missing'
assert_contains "$uri" "sni=$sni" 'TUIC URI SNI is missing'
assert_contains "$uri" 'allow_insecure=1' 'TUIC URI self-signed verification mode is missing'
assert_contains "$uri" 'udp_relay_mode=native' 'TUIC URI UDP relay mode is missing'
assert_not_contains "$uri" 'pinSHA256=' 'TUIC URI invented a non-portable pin parameter'
assert_not_contains "$uri" 'key.pem' 'TUIC URI leaked a private key path'
decoded=$(node_base64_uri "$node" | base64 -d)
[[ "$decoded" == "$uri" ]] || fail 'TUIC Base64 does not decode to URI'

# Prove all four protocol unions produce one valid sing-box configuration and
# retain their real transport filters. This block runs when the official binary
# is available; pure model checks above remain portable without it.
if [[ -x "$SING_BOX_BINARY" ]]; then
  ss_id=11111111111111111111111111111111
  vless_id=22222222222222222222222222222222
  hy2_id=33333333333333333333333333333333
  ss_record="$TEST_TMP/ss.json"
  vless_record="$TEST_TMP/vless.json"
  hy2_record="$TEST_TMP/hy2.json"
  ss_password=$(generate_random_key 32) || fail 'could not generate mixed SS2022 key'
  node_new_record 'Mixed SS' '2022-blake3-aes-256-gcm' 25441 192.0.2.21 ipv4 "$ss_id" "$ss_password" >"$ss_record" \
    || fail 'could not build mixed SS2022 record'
  vless_uuid=$(generate_unique_vless_uuid) || fail 'could not generate mixed VLESS UUID'
  keypair=$(generate_unique_reality_keypair) || fail 'could not generate mixed Reality keypair'
  private_key=${keypair%$'\t'*}
  public_key=${keypair##*$'\t'}
  short_id=$(generate_unique_reality_short_id) || fail 'could not generate mixed Reality Short ID'
  node_new_vless_record 'Mixed VLESS' 25442 192.0.2.22 ipv4 "$vless_id" "$vless_uuid" \
    "$private_key" "$public_key" "$short_id" example.com example.com 443 >"$vless_record" \
    || fail 'could not build mixed VLESS record'
  mixed_certs=$(tls_make_candidate_cert_root) || fail 'could not create mixed TLS candidate root'
  hy2_sni=$(tls_server_name_for_node hysteria2 "$hy2_id") || fail 'could not derive mixed Hysteria2 SNI'
  hy2_password=$(generate_hysteria2_password) || fail 'could not generate mixed Hysteria2 password'
  hy2_pin=$(tls_generate_certificate "$mixed_certs" "$hy2_id" "$hy2_sni") \
    || fail 'could not generate mixed Hysteria2 certificate'
  node_new_hysteria2_record 'Mixed HY2' 25443 192.0.2.23 ipv4 "$hy2_id" "$hy2_password" "$hy2_sni" "$hy2_pin" >"$hy2_record" \
    || fail 'could not build mixed Hysteria2 record'
  mixed_nodes="$TEST_TMP/mixed-four-protocols.json"
  jq --slurpfile ss "$ss_record" --slurpfile vless "$vless_record" --slurpfile hy2 "$hy2_record" \
    '.nodes = [$ss[0], $vless[0], $hy2[0], .nodes[0]]' "$NODES_FILE" >"$mixed_nodes" \
    || fail 'could not assemble four-protocol node state'
  validate_nodes_file_semantic "$mixed_nodes" || fail 'valid four-protocol node state was rejected'
  validate_tls_certificate_state "$mixed_nodes" "$mixed_certs" || fail 'mixed HY2/TUIC TLS state was rejected'
  mixed_config="$TEST_TMP/mixed-four-protocols-config.json"
  generate_singbox_config "$mixed_nodes" "$mixed_config" "$mixed_certs" \
    || fail 'four-protocol config generation failed'
  jq -e '
    (.inbounds | length) == 4
    and ([.inbounds[].type] | sort) == (["shadowsocks","vless","hysteria2","tuic"] | sort)
  ' "$mixed_config" >/dev/null || fail 'four-protocol config lost or duplicated an inbound'
  "$SING_BOX_BINARY" check -c "$mixed_config" >/dev/null 2>&1 \
    || fail 'official sing-box rejected the four-protocol configuration'
  mixed_actions="$TEST_TMP/mixed-four-protocols-actions.json"
  bandwidth_build_actions "$mixed_nodes" "$mixed_actions" || fail 'four-protocol bandwidth plan generation failed'
  jq -e --arg ss "$ss_id" --arg vless "$vless_id" --arg hy2 "$hy2_id" --arg tuic "$node_id" '
    length == 8
    and all(.[] | select(.node_id == $ss); .protocols == ["tcp","udp"])
    and all(.[] | select(.node_id == $vless); .protocols == ["tcp"])
    and all(.[] | select(.node_id == $hy2 or .node_id == $tuic); .protocols == ["udp"])
  ' "$mixed_actions" >/dev/null || fail 'four-protocol bandwidth transports are wrong'
  jq --arg id "$node_id" --argjson port 25441 \
    '.nodes[] |= if .node_id == $id then .port=$port else . end' "$mixed_nodes" >"$TEST_TMP/mixed-duplicate-port.json"
  if validate_nodes_file_semantic "$TEST_TMP/mixed-duplicate-port.json"; then
    fail 'cross-protocol duplicate port was accepted'
  fi
  jq --arg id "$node_id" --arg uuid "$vless_uuid" \
    '.nodes[] |= if .node_id == $id then .uuid=$uuid else . end' "$mixed_nodes" >"$TEST_TMP/mixed-duplicate-uuid.json"
  if validate_nodes_file_semantic "$TEST_TMP/mixed-duplicate-uuid.json"; then
    fail 'VLESS/TUIC duplicate UUID was accepted'
  fi
  rm -rf -- "$mixed_certs"
fi

actions="$TEST_TMP/actions.json"
bandwidth_build_actions "$NODES_FILE" "$actions" || fail 'TUIC bandwidth action generation failed'
jq -e 'length == 2 and all(.[]; .protocols == ["udp"])' "$actions" >/dev/null \
  || fail 'TUIC bandwidth transport is not UDP-only'

detail=$(node_show_detail "$node_id") || fail 'TUIC detail display failed'
assert_contains "$detail" 'TUIC' 'TUIC detail omitted protocol'
assert_contains "$detail" "$uuid" 'TUIC detail omitted UUID'
assert_contains "$detail" "$password" 'TUIC detail omitted password'
assert_contains "$detail" "$pin" 'TUIC detail omitted certificate pin'
assert_contains "$detail" 'TLS：Self-Signed' 'TUIC detail omitted self-signed TLS mode'
assert_contains "$detail" '0-RTT：关闭' 'TUIC detail did not report disabled 0-RTT'
assert_not_contains "$detail" 'key.pem' 'TUIC detail leaked a private key path'

singbox_is_active() { return 1; }
qrencode() { cat >/dev/null; }
credential_output=$(show_node_credentials "$node_id" 2>&1) || fail 'TUIC credential display failed'
assert_contains "$credential_output" "$uri" 'TUIC credential display omitted the standard URI'
assert_contains "$credential_output" "$uuid" 'TUIC credential display omitted UUID'
assert_contains "$credential_output" "$password" 'TUIC credential display omitted Password'
assert_contains "$credential_output" "$pin" 'TUIC credential display omitted certificate pin'
assert_contains "$credential_output" 'TLS：Self-Signed' 'TUIC credential display omitted TLS mode'
assert_contains "$credential_output" '放行 UDP 端口' 'TUIC credential display gave the wrong firewall transport'
assert_not_contains "$credential_output" 'key.pem' 'TUIC credentials or QR output leaked a private key path'

# Editing ordinary public fields must not rotate identity or TLS material.
jq '.nodes[0].port=25445 | .nodes[0].name="Tokyo TUIC Renamed"' "$NODES_FILE" >"$NODES_FILE.edited"
validate_nodes_file_semantic "$NODES_FILE.edited" || fail 'ordinary TUIC edit was rejected'
validate_tls_certificate_state "$NODES_FILE.edited" "$candidate_certs" || fail 'ordinary TUIC edit invalidated TLS state'
[[ "$(jq -r '.nodes[0].uuid' "$NODES_FILE.edited")" == "$uuid" ]] || fail 'ordinary edit changed TUIC UUID'
[[ "$(jq -r '.nodes[0].password' "$NODES_FILE.edited")" == "$password" ]] || fail 'ordinary edit changed TUIC password'

candidate2=$(tls_make_candidate_cert_root) || fail 'could not create TUIC rotation candidate'
pin2=$(tls_generate_certificate "$candidate2" "$node_id" "$sni") || fail 'could not rotate TUIC certificate'
[[ "$pin2" != "$pin" ]] || fail 'TUIC certificate rotation reused the same leaf certificate'
jq --arg pin "$pin2" '.nodes[0].certificate_sha256=$pin' "$NODES_FILE" >"$NODES_FILE.rotated"
validate_tls_certificate_state "$NODES_FILE.rotated" "$candidate2" || fail 'rotated TUIC certificate was rejected'
wrong_san_certs=$(tls_make_candidate_cert_root) || fail 'could not create wrong-SAN certificate candidate'
wrong_san_pin=$(tls_generate_certificate "$wrong_san_certs" "$node_id" "$sni.evil") \
  || fail 'could not generate wrong-SAN certificate fixture'
if tls_validate_certificate_files "$wrong_san_certs" "$node_id" "$sni" "$wrong_san_pin"; then
  fail 'certificate SAN prefix was accepted as an exact TUIC SNI match'
fi
rm -rf -- "$wrong_san_certs"
jq '.nodes[0].certificate_sha256=("0" * 64)' "$NODES_FILE" >"$NODES_FILE.bad"
if validate_tls_certificate_state "$NODES_FILE.bad" "$candidate_certs"; then fail 'mismatched TUIC pin was accepted'; fi

# Restoring a snapshot with no managed-TLS nodes over a live TUIC node must
# publish an empty certificate tree; otherwise the live key becomes an orphan
# and the restore cannot pass candidate validation.
(
  backup_name=20260815-000000-pre-tls
  selected="$BACKUP_DIR/$backup_name"
  mkdir -p -- "$selected"
  jq -n --arg version "$MANAGER_VERSION" \
    '{schema_version:1,artifact:"ss2022-state-snapshot",reason:"pre-tls",created_at:"2026-08-15T00:00:00Z",manager_version:$version,sing_box_version:""}' \
    >"$selected/metadata.json"
  printf '%s\n' '{"schema_version":4,"nodes":[]}' >"$selected/nodes.json"
  printf '%s\n' '{"schema_version":1,"nodes":{}}' >"$selected/traffic.json"
  printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$selected/traffic-history.json"
  backup_list() { printf '%s\n' "$backup_name"; }
  acquire_manager_lock() { return 0; }
  prompt_yes_no() { return 0; }
  traffic_collect_no_lock() { return 0; }
  apply_state_transaction() {
    local restored_certs=$6
    [[ -d "$restored_certs" && ! -L "$restored_certs" ]] || return 1
    [[ -z "$(find "$restored_certs" -mindepth 1 -print -quit)" ]] || return 1
    rm -rf -- "$restored_certs" || return 1
    : >"$TEST_TMP/empty-tls-restore-observed"
  }
  backup_restore_flow <<<'1' >/dev/null
)
[[ -f "$TEST_TMP/empty-tls-restore-observed" ]] || fail 'pre-TLS backup restore did not publish an empty certificate candidate'

printf 'TUIC unified-node model tests passed\n'
