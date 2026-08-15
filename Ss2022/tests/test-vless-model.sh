#!/usr/bin/env bash
# Test fixtures intentionally override globals consumed by separately sourced
# modules; ShellCheck cannot see those cross-file reads.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_SING_BOX_CHECK_BINARY=${SS_MANAGER_TEST_SING_BOX_BINARY:-}
for command_name in jq python3 openssl base64; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 77
  }
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

# Defaults are intentionally loaded before the isolated paths are assigned:
# defaults.conf contains production locations and must never be allowed to
# overwrite this test fixture's temporary state directories.
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
COUNTERS_FILE="$DATA_DIR/tc-counters.json"
INTERFACES_FILE="$DATA_DIR/interfaces.json"
TRANSACTION_LOCK="$RUNTIME_DIR/manager.lock"
STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
SING_BOX_CONFIG="$TEST_TMP/sing-box-config.json"
SING_BOX_BINARY=/bin/true

mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
printf '%s\n' '{"listen_mode":"ipv4","tfo_config_supported":false,"tfo_kernel_enabled":false}' >"$MANAGER_STATE"

fail_test() {
  printf 'assertion failed: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected=$1 actual=$2 message=$3
  [[ "$expected" == "$actual" ]] || {
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2 message=$3
  [[ "$haystack" == *"$needle"* ]] || fail_test "$message"
}

assert_not_contains() {
  local haystack=$1 needle=$2 message=$3
  [[ "$haystack" != *"$needle"* ]] || fail_test "$message"
}

node_id_ss=0123456789abcdef0123456789abcdef
node_id_vless=fedcba9876543210fedcba9876543210
# Build two synthetic X25519 pairs at test runtime so no server-shaped private
# key literal is stored in the repository fixture.  The second pair is used to
# prove that identity rotation retries a collision instead of retaining it.
synthetic_keypairs=$(python3 <<'PY'
import base64
import hashlib

p = 2**255 - 19
def public_for(private):
    scalar = int.from_bytes(private, "little")
    scalar &= (1 << 255) - 8
    scalar |= 1 << 254
    x1 = 9
    x2, z2 = 1, 0
    x3, z3 = 9, 1
    swap = 0
    for bit_index in range(254, -1, -1):
        bit = (scalar >> bit_index) & 1
        swap ^= bit
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = bit
        a = (x2 + z2) % p
        aa = (a * a) % p
        b = (x2 - z2) % p
        bb = (b * b) % p
        e = (aa - bb) % p
        c = (x3 + z3) % p
        d = (x3 - z3) % p
        da = (d * a) % p
        cb = (c * b) % p
        x3 = ((da + cb) ** 2) % p
        z3 = (x1 * ((da - cb) ** 2)) % p
        x2 = (aa * bb) % p
        z2 = (e * (aa + 121665 * e)) % p
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")

encode = lambda value: base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")
for seed in (
    b"Ss2022 disposable VLESS model fixture",
    b"Ss2022 disposable VLESS rotation fixture",
):
    private = hashlib.sha256(seed).digest()
    print(f"{encode(private)}\t{encode(public_for(private))}")
PY
) || fail_test 'could not build the synthetic Reality keypair fixture'
synthetic_keypair=${synthetic_keypairs%$'\n'*}
alternate_keypair=${synthetic_keypairs##*$'\n'}
private_key=${synthetic_keypair%$'\t'*}
public_key=${synthetic_keypair##*$'\t'}
alternate_private_key=${alternate_keypair%$'\t'*}
alternate_public_key=${alternate_keypair##*$'\t'}
uuid=bf000d23-0752-40b4-affe-68f7707a9661
short_id=0123456789abcdef

validate_reality_keypair "$private_key" "$public_key" || fail_test 'synthetic Reality fixture is not a valid keypair'
validate_reality_keypair "$alternate_private_key" "$alternate_public_key" \
  || fail_test 'synthetic Reality rotation fixture is not a valid keypair'
generated_short_id=$(generate_reality_short_id) || fail_test 'OpenSSL Reality Short ID generation failed'
[[ "$generated_short_id" =~ ^[a-f0-9]{16}$ ]] || fail_test 'generated Reality Short ID is not eight lowercase hexadecimal bytes'
validate_uuid '01890f47-bd4c-7abc-8def-0123456789ab' || fail_test 'standard UUIDv7 identity was rejected'

legacy_nodes="$TEST_TMP/nodes-schema1.json"
jq -n --arg id "$node_id_ss" '{schema_version:1,nodes:[{
  node_id:$id,name:"Tokyo SS",method:"2022-blake3-aes-256-gcm",
  password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,
  address:"192.0.2.10",address_type:"ipv4",status:"enabled",status_reason:"",
  quota_bytes:500000000000,reset_day:7,upload_limit_mbps:12.5,download_limit_mbps:34.5,
  created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-02T00:00:00Z",
  last_reset_at:"2026-01-07T00:00:00Z",next_reset_at:"2026-02-07T00:00:00Z"
}]}' >"$legacy_nodes"
validate_nodes_file_semantic "$legacy_nodes" || fail_test 'valid schema-1 SS2022 data was rejected'

upgraded_nodes="$TEST_TMP/nodes-schema2-ss.json"
nodes_schema_upgrade_copy "$legacy_nodes" "$upgraded_nodes" || fail_test 'schema-1 SS2022 upgrade failed'
assert_equal 4 "$(jq -r '.schema_version' "$upgraded_nodes")" 'node schema was not upgraded to version 4'
assert_equal shadowsocks "$(jq -r '.nodes[0].protocol' "$upgraded_nodes")" 'legacy node protocol discriminator was not added'
jq -e --slurpfile old "$legacy_nodes" '
  .nodes[0] as $new
  | $old[0].nodes[0] as $previous
  | ($new | del(.protocol)) == $previous
' "$upgraded_nodes" >/dev/null || fail_test 'schema migration changed legacy identity, credentials, limits or schedule'

install -m 600 -- "$legacy_nodes" "$NODES_FILE"
jq -n --arg id "$node_id_ss" '{schema_version:1,nodes:{($id):{
  current_upload_bytes:10,current_download_bytes:20,total_upload_bytes:30,total_download_bytes:40,
  upload_kernel_bytes:0,download_kernel_bytes:0,quota_bytes:500000000000,reset_day:7,
  last_reset_at:"2026-01-07T00:00:00Z",next_reset_at:"2026-02-07T00:00:00Z",updated_at:"2026-01-02T00:00:00Z"
}}}' >"$TRAFFIC_FILE"
printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$HISTORY_FILE"
migration_backup_reason=''
backup_create_snapshot() {
  migration_backup_reason=$1
  printf '%s' "$BACKUP_DIR/fake-migration-snapshot"
}
INSTALL_TRANSACTION_ACTIVE=1
migrate_nodes_schema_if_needed || fail_test 'automatic schema migration failed'
assert_equal schema-1-to-4-migration "$migration_backup_reason" 'automatic migration did not request its pre-migration snapshot'
assert_equal 4 "$(jq -r '.schema_version' "$NODES_FILE")" 'automatic migration did not publish schema 4'
jq -e --slurpfile old "$legacy_nodes" '(.nodes[0] | del(.protocol)) == $old[0].nodes[0]' "$NODES_FILE" >/dev/null \
  || fail_test 'automatic migration changed an existing SS2022 node'

# Simulate a durability failure reported immediately after the schema-2 file
# was atomically published. The migration must put the schema-1 source back.
(
  install -m 600 -- "$legacy_nodes" "$NODES_FILE"
  eval "$(declare -f atomic_json_write | sed '1s/^atomic_json_write/real_atomic_json_write/')"
  atomic_write_count=0
  atomic_json_write() {
    atomic_write_count=$((atomic_write_count + 1))
    real_atomic_json_write "$@" || return 1
    (( atomic_write_count != 1 ))
  }
  if migrate_nodes_schema_if_needed >/dev/null 2>&1; then
    fail_test 'migration unexpectedly succeeded after a simulated publish failure'
  fi
  assert_equal 1 "$(jq -r '.schema_version' "$NODES_FILE")" 'failed migration did not restore the schema-1 source'
  jq -e --slurpfile old "$legacy_nodes" '. == $old[0]' "$NODES_FILE" >/dev/null \
    || fail_test 'failed migration did not restore the exact legacy node document'
)
unset INSTALL_TRANSACTION_ACTIVE

vless_record="$TEST_TMP/vless-record.json"
node_new_vless_record \
  'Osaka VLESS' 24444 '198.51.100.20' ipv4 "$node_id_vless" "$uuid" \
  "$private_key" "$public_key" "$short_id" 'www.example.com' 'www.example.com' 443 \
  >"$vless_record" || fail_test 'VLESS node record generation failed'
chmod 600 -- "$vless_record"

mixed_nodes="$TEST_TMP/nodes-mixed.json"
jq --slurpfile record "$vless_record" '.nodes += [$record[0]]' "$upgraded_nodes" >"$mixed_nodes"
validate_nodes_file_semantic "$mixed_nodes" || fail_test 'valid mixed SS2022/VLESS schema was rejected'
assert_equal 2 "$(jq '.nodes | length' "$mixed_nodes")" 'mixed node database lost a node'
assert_equal "$node_id_ss" "$(jq -r '.nodes[0].node_id' "$mixed_nodes")" 'SS2022 Node ID changed'
assert_equal "$node_id_vless" "$(jq -r '.nodes[1].node_id' "$mixed_nodes")" 'VLESS Node ID changed'

legacy_schema2="$TEST_TMP/nodes-schema2-mixed.json"
upgraded_schema4="$TEST_TMP/nodes-schema4-from-2.json"
jq '.schema_version=2' "$mixed_nodes" >"$legacy_schema2"
validate_nodes_file_semantic "$legacy_schema2" || fail_test 'valid schema-2 SS2022/VLESS data was rejected'
nodes_schema_upgrade_copy "$legacy_schema2" "$upgraded_schema4" || fail_test 'schema-2 to schema-4 migration failed'
jq -e --slurpfile old "$legacy_schema2" '
  .schema_version == 4 and (.nodes == $old[0].nodes)
' "$upgraded_schema4" >/dev/null || fail_test 'schema-2 migration changed SS2022/VLESS identity data'

bad_pair="$TEST_TMP/nodes-bad-pair.json"
jq '.nodes[1].reality_public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$mixed_nodes" >"$bad_pair"
if validate_nodes_file_semantic "$bad_pair"; then
  fail_test 'a mismatched Reality private/public key pair was accepted'
fi

bad_union="$TEST_TMP/nodes-bad-union.json"
jq '.nodes[1].method="2022-blake3-aes-256-gcm"' "$mixed_nodes" >"$bad_union"
if validate_nodes_file_semantic "$bad_union"; then
  fail_test 'VLESS data containing Shadowsocks-only fields was accepted'
fi

duplicate_port="$TEST_TMP/nodes-duplicate-port.json"
jq '.nodes[1].port=.nodes[0].port' "$mixed_nodes" >"$duplicate_port"
if validate_nodes_file_semantic "$duplicate_port"; then
  fail_test 'a cross-protocol duplicate node port was accepted'
fi

duplicate_vless_identity="$TEST_TMP/nodes-duplicate-vless-identity.json"
jq '.nodes += [(.nodes[1] | .node_id="11111111111111111111111111111111" | .name="Duplicate VLESS" | .port=24445)]' \
  "$mixed_nodes" >"$duplicate_vless_identity"
if validate_nodes_file_semantic "$duplicate_vless_identity"; then
  fail_test 'shared VLESS UUID, Reality KeyPair or Short ID was accepted'
fi

install -m 600 -- "$upgraded_nodes" "$NODES_FILE"
protocol_conversion="$TEST_TMP/nodes-protocol-conversion.json"
jq --slurpfile record "$vless_record" --arg id "$node_id_ss" '
  .nodes = [($record[0] | .node_id=$id | .name="Tokyo SS")]
' "$upgraded_nodes" >"$protocol_conversion"
if (validate_candidate_nodes "$protocol_conversion" >/dev/null 2>&1); then
  fail_test 'an existing permanent Node ID was allowed to change protocol'
fi

assert_equal $'www.example.com\t443' "$(parse_reality_handshake_target 'WWW.Example.COM')" 'default Reality handshake port or domain normalization is wrong'
assert_equal $'2001:db8::1\t8443' "$(parse_reality_handshake_target '[2001:db8::1]:8443')" 'bracketed IPv6 Reality target parsing is wrong'
if parse_reality_handshake_target '2001:db8::1:443' >/dev/null 2>&1; then
  fail_test 'ambiguous unbracketed IPv6 Reality target was accepted'
fi
if normalize_domain_name 'https://example.com' >/dev/null 2>&1; then
  fail_test 'a URL was accepted as Reality SNI'
fi
if normalize_domain_name 'example.com;touch' >/dev/null 2>&1; then
  fail_test 'shell metacharacters were accepted in Reality SNI'
fi
if parse_reality_handshake_target 'https://example.com:443' >/dev/null 2>&1; then
  fail_test 'a URL was accepted as a Reality handshake target'
fi
if validate_short_id 'abc' >/dev/null 2>&1; then
  fail_test 'an odd-length Reality Short ID was accepted'
fi

config_output="$TEST_TMP/config-mixed.json"
generate_singbox_config "$mixed_nodes" "$config_output" || fail_test 'mixed sing-box config generation failed'
jq -e --slurpfile nodes "$mixed_nodes" '
  (.inbounds | length) == 2
  and any(.inbounds[]; .type == "shadowsocks" and .tag == "ss-0123456789abcdef0123456789abcdef"
    and .listen_port == 20001 and .method == "2022-blake3-aes-256-gcm")
  and any(.inbounds[]; .type == "vless" and .tag == "vless-fedcba9876543210fedcba9876543210"
    and .listen_port == 24444
    and .users == [{uuid:"bf000d23-0752-40b4-affe-68f7707a9661",flow:"xtls-rprx-vision"}]
    and .tls.enabled == true
    and .tls.server_name == "www.example.com"
    and .tls.reality.enabled == true
    and .tls.reality.handshake == {server:"www.example.com",server_port:443}
    and .tls.reality.private_key == $nodes[0].nodes[1].reality_private_key
    and .tls.reality.short_id == ["0123456789abcdef"])
  and ([.. | objects | .reality_public_key? // empty] | length) == 0
' "$config_output" >/dev/null || fail_test 'generated mixed sing-box inbound structure is wrong'
if [[ -n "$REAL_SING_BOX_CHECK_BINARY" ]]; then
  [[ -x "$REAL_SING_BOX_CHECK_BINARY" ]] || fail_test 'requested sing-box check binary is not executable'
  "$REAL_SING_BOX_CHECK_BINARY" check -c "$config_output" >/dev/null 2>&1 \
    || fail_test 'official sing-box rejected the generated mixed configuration'
fi

vless_node=$(jq -c --arg id "$node_id_vless" '.nodes[] | select(.node_id == $id)' "$mixed_nodes")
vless_uri=$(node_vless_uri "$vless_node") || fail_test 'VLESS URI generation failed'
assert_contains "$vless_uri" 'type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision' 'VLESS URI is missing its fixed transport/security/flow fields'
assert_contains "$vless_uri" "sni=www.example.com&fp=chrome&pbk=$public_key&sid=0123456789abcdef" 'VLESS URI is missing Reality client parameters'
assert_contains "$vless_uri" '#Osaka%20VLESS' 'VLESS URI node name was not encoded'
assert_not_contains "$vless_uri" "$private_key" 'Reality Private Key leaked into the VLESS URI'
decoded_uri=$(node_base64_uri "$vless_node" | base64 -d)
assert_equal "$vless_uri" "$decoded_uri" 'VLESS Base64 output does not decode to the standard URI'

vless_ipv6_node=$(jq -c '.address="2001:db8::20" | .address_type="ipv6"' <<<"$vless_node")
vless_ipv6_uri=$(node_vless_uri "$vless_ipv6_node") || fail_test 'IPv6 VLESS URI generation failed'
assert_contains "$vless_ipv6_uri" '@[2001:db8::20]:24444?' 'IPv6 VLESS URI host was not bracketed'
vless_domain_node=$(jq -c '.address="edge.example.net" | .address_type="domain"' <<<"$vless_node")
vless_domain_uri=$(node_vless_uri "$vless_domain_node") || fail_test 'domain VLESS URI generation failed'
assert_contains "$vless_domain_uri" '@edge.example.net:24444?' 'domain VLESS URI host was changed or malformed'

family_nodes="$TEST_TMP/nodes-family-specific.json"
jq '.nodes[1].address="edge.example.net" | .nodes[1].address_type="domain"' "$mixed_nodes" >"$family_nodes"
jq '.listen_mode="family-specific"' "$MANAGER_STATE" >"$MANAGER_STATE.next"
mv -f -- "$MANAGER_STATE.next" "$MANAGER_STATE"
family_config="$TEST_TMP/config-family-specific.json"
generate_singbox_config "$family_nodes" "$family_config" || fail_test 'family-specific mixed config generation failed'
jq -e --arg id "$node_id_vless" --slurpfile nodes "$family_nodes" '
  ([.inbounds[] | select(.tag == ("vless-" + $id + "-ipv4") and .listen == "0.0.0.0")] | length) == 1
  and ([.inbounds[] | select(.tag == ("vless-" + $id + "-ipv6") and .listen == "::")] | length) == 1
  and all(.inbounds[] | select(.tag | startswith("vless-" + $id));
    .users[0].uuid == "bf000d23-0752-40b4-affe-68f7707a9661"
    and .tls.reality.private_key == $nodes[0].nodes[1].reality_private_key)
' "$family_config" >/dev/null || fail_test 'family-specific VLESS inbounds did not preserve one Node ID and credential set'
jq '.listen_mode="ipv4"' "$MANAGER_STATE" >"$MANAGER_STATE.next"
mv -f -- "$MANAGER_STATE.next" "$MANAGER_STATE"

install -m 600 -- "$mixed_nodes" "$NODES_FILE"
jq -n --arg ss "$node_id_ss" --arg vless "$node_id_vless" '{schema_version:1,nodes:{
  ($ss):{current_upload_bytes:10,current_download_bytes:20,total_upload_bytes:30,total_download_bytes:40,upload_kernel_bytes:0,download_kernel_bytes:0,quota_bytes:500000000000,reset_day:7,last_reset_at:"2026-01-07T00:00:00Z",next_reset_at:"2026-02-07T00:00:00Z",updated_at:"2026-01-02T00:00:00Z"},
  ($vless):{current_upload_bytes:50,current_download_bytes:60,total_upload_bytes:70,total_download_bytes:80,upload_kernel_bytes:0,download_kernel_bytes:0,quota_bytes:0,reset_day:1,last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}
}}' >"$TRAFFIC_FILE"

# Identity rotation must retry a collision with the current node as well as a
# collision with another node; "regenerate" may never silently keep an old
# client identity.  File markers survive the command-substitution subshells.
(
  uuid_marker="$TEST_TMP/uuid-collision-seen"
  generate_vless_uuid() {
    if [[ ! -e "$uuid_marker" ]]; then
      : >"$uuid_marker"
      printf '%s' "$uuid"
    else
      printf '%s' '01890f47-bd4c-7abc-8def-0123456789ab'
    fi
  }
  assert_equal '01890f47-bd4c-7abc-8def-0123456789ab' "$(generate_unique_vless_uuid)" \
    'UUID regeneration did not retry an existing VLESS identity'

  short_marker="$TEST_TMP/short-id-collision-seen"
  generate_reality_short_id() {
    if [[ ! -e "$short_marker" ]]; then
      : >"$short_marker"
      printf '%s' "$short_id"
    else
      printf '%s' '0011223344556677'
    fi
  }
  assert_equal '0011223344556677' "$(generate_unique_reality_short_id)" \
    'Short ID regeneration did not retry an existing VLESS identity'

  keypair_marker="$TEST_TMP/keypair-collision-seen"
  generate_reality_keypair() {
    if [[ ! -e "$keypair_marker" ]]; then
      : >"$keypair_marker"
      printf '%s' "$synthetic_keypair"
    else
      printf '%s' "$alternate_keypair"
    fi
  }
  assert_equal "$alternate_keypair" "$(generate_unique_reality_keypair)" \
    'Reality KeyPair regeneration did not retry an existing effective X25519 identity'
)

detail_output=$(node_show_detail "$node_id_vless") || fail_test 'VLESS detail display failed'
assert_contains "$detail_output" "$public_key" 'VLESS detail omitted the Reality Public Key'
assert_contains "$detail_output" 'Reality 握手目标：www.example.com:443' 'VLESS detail omitted the Reality handshake target'
assert_not_contains "$detail_output" "$private_key" 'Reality Private Key leaked into node detail'

singbox_is_active() { return 1; }
qrencode() { cat >/dev/null; }
credential_output=$(show_node_credentials "$node_id_vless" 2>&1) || fail_test 'VLESS credential display failed'
assert_contains "$credential_output" "$public_key" 'VLESS credential display omitted the Reality Public Key'
assert_contains "$credential_output" "$vless_uri" 'VLESS credential display omitted the standard URI'
assert_not_contains "$credential_output" "$private_key" 'Reality Private Key leaked into credentials or QR output'

actions_file="$TEST_TMP/actions.json"
bandwidth_build_actions "$mixed_nodes" "$actions_file" || fail_test 'mixed bandwidth action generation failed'
jq -e --arg ss "$node_id_ss" --arg vless "$node_id_vless" '
  length == 4
  and all(.[] | select(.node_id == $ss); .protocols == ["tcp","udp"])
  and all(.[] | select(.node_id == $vless); .protocols == ["tcp"])
' "$actions_file" >/dev/null || fail_test 'bandwidth transport filters do not match node protocols'

interfaces_file="$TEST_TMP/interfaces.json"
printf '%s\n' '{"schema_version":1,"interfaces":["eth0"]}' >"$interfaces_file"
plan_file="$TEST_TMP/bandwidth-plan.json"
jq -n --slurpfile actions "$actions_file" '{schema_version:2,pref:49100,boot_id:"unknown",interfaces:["eth0"],families:["ip"],actions:$actions[0],updated_at:"2026-01-01T00:00:00Z"}' >"$plan_file"
validate_bandwidth_plan_semantic "$plan_file" || fail_test 'valid mixed bandwidth plan was rejected'
validate_bandwidth_plan_against_state "$plan_file" "$mixed_nodes" "$interfaces_file" || fail_test 'mixed bandwidth plan failed node protocol cross-check'

assert_equal 60 "$(quota_billable_bytes 50 60)" 'default global quota policy did not use download-only bytes'
jq '.quota_include_unauthenticated_upload=true' "$MANAGER_STATE" >"$MANAGER_STATE.next"
mv -f -- "$MANAGER_STATE.next" "$MANAGER_STATE"
assert_equal 110 "$(quota_billable_bytes 50 60)" 'global upload+download quota switch did not apply uniformly'

printf 'VLESS unified-node model tests passed\n'
