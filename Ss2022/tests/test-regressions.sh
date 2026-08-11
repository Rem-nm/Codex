#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
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
# shellcheck disable=SC1091
source "$ROOT/lib/backup.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/update.sh"

# MSYS test runners on Windows cannot always chmod an existing temporary
# directory. Production code still uses ensure_dir's strict install modes;
# these unit tests only need isolated directory creation.
ensure_dir() { mkdir -p -- "$1"; }

assert_equal() {
  local expected=$1 actual=$2 message=$3
  [[ "$expected" == "$actual" ]] || {
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  }
}

assert_true() {
  local message=$1
  shift
  "$@" || { printf 'assertion failed: %s\n' "$message" >&2; exit 1; }
}

(
  MANAGER_STATE=$(mktemp)
  printf '%s\n' '{}' >"$MANAGER_STATE"
  assert_equal '' "$(manager_state_get missing '')" 'an explicit empty manager-state fallback must remain empty'
  assert_equal 'null' "$(manager_state_get missing)" 'an omitted manager-state fallback must remain JSON null text'
  rm -f -- "$MANAGER_STATE"
)

node=$(jq -nc '{node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo HK",method:"2022-blake3-aes-256-gcm",password:"AB+/==",port:20001,address:"2001:db8::1",address_type:"ipv6",status:"enabled"}')
uri=$(node_sip002_uri "$node")
assert_equal 'ss://2022-blake3-aes-256-gcm:AB%2B%2F%3D%3D@[2001:db8::1]:20001#Tokyo%20HK' "$uri" 'AEAD-2022 SIP002 userinfo must be percent-encoded, not Base64URL encoded'

base64_node=$(node_base64_uri "$node")
decoded_uri=$(printf '%s' "$base64_node" | base64 -d)
assert_equal "$uri" "$decoded_uri" 'Base64 node information must decode to the canonical SIP002 URI'

single_asset_release=$(jq -nc '{assets:[{name:"package.tar.gz",browser_download_url:"https://github.com/example/project/releases/download/v1/package.tar.gz",digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}')
assert_equal 'https://github.com/example/project/releases/download/v1/package.tar.gz' "$(release_asset_url "$single_asset_release" package.tar.gz)" 'release asset lookup must accept exactly one matching asset'
duplicate_asset_release=$(jq -c '.assets += [.assets[0]]' <<<"$single_asset_release")
if release_asset_url "$duplicate_asset_release" package.tar.gz >/dev/null 2>&1; then
  printf 'assertion failed: release asset lookup must reject duplicate names\n' >&2
  exit 1
fi
checksum_release=$(jq -nc '{assets:[{name:"SHA256SUMS"},{name:"package.tar.gz"}]}')
assert_equal 'SHA256SUMS' "$(release_checksum_asset_name "$checksum_release")" 'checksum fallback must require one unambiguous checksum asset'
ambiguous_checksum_release=$(jq -c '.assets += [{name:"checksums.txt"}]' <<<"$checksum_release")
if release_checksum_asset_name "$ambiguous_checksum_release" >/dev/null 2>&1; then
  printf 'assertion failed: ambiguous checksum assets must be rejected\n' >&2
  exit 1
fi
checksum_fixture=$(mktemp)
printf '%s  %s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'package.tar.gz' >"$checksum_fixture"
assert_equal 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$(checksum_file_digest_for_asset "$checksum_fixture" package.tar.gz)" 'one exact checksum entry must be accepted'
printf '%s  %s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'package.tar.gz' >>"$checksum_fixture"
if checksum_file_digest_for_asset "$checksum_fixture" package.tar.gz >/dev/null 2>&1; then
  printf 'assertion failed: duplicate checksum entries must be rejected\n' >&2
  exit 1
fi
rm -f -- "$checksum_fixture"

manager_package_fixture=$(mktemp -d)
for required_file in \
  ss-manager.sh VERSION config/defaults.conf \
  lib/common.sh lib/system.sh lib/service.sh lib/singbox.sh lib/traffic.sh \
  lib/bandwidth.sh lib/backup.sh lib/nodes.sh lib/links.sh lib/update.sh lib/menu.sh \
  systemd/sing-box.service systemd/ss-manager-traffic.service systemd/ss-manager-traffic.timer \
  openrc/sing-box openrc/ss-manager-traffic openrc/ss-manager-traffic-loop.sh; do
  mkdir -p -- "$manager_package_fixture/$(dirname -- "$required_file")"
  : >"$manager_package_fixture/$required_file"
done
assert_true 'a complete manager runtime package must pass structure validation' manager_update_validate_package_structure "$manager_package_fixture"
rm -f -- "$manager_package_fixture/lib/menu.sh"
if manager_update_validate_package_structure "$manager_package_fixture" >/dev/null 2>&1; then
  printf 'assertion failed: a manager package missing a runtime module must be rejected\n' >&2
  exit 1
fi
rm -rf -- "$manager_package_fixture"

(
  binary_identity_fixture=$(mktemp -d)
  SING_BOX_BINARY="$binary_identity_fixture/sing-box"
  MANAGER_STATE="$binary_identity_fixture/manager.json"
  printf '%s\n' '#!/bin/sh' "printf 'sing-box version 1.2.3\\n'" >"$SING_BOX_BINARY"
  chmod 755 -- "$SING_BOX_BINARY"
  binary_digest=$(singbox_binary_digest)
  jq -n '{sing_box_binary_managed:true,sing_box_version:"1.2.3"}' >"$MANAGER_STATE"
  assert_true 'legacy managed binary state must migrate after its version is verified' ensure_managed_singbox_binary_identity
  assert_equal "$binary_digest" "$(jq -r '.sing_box_binary_sha256' "$MANAGER_STATE")" 'binary identity migration stored the wrong digest'
  assert_true 'matching sing-box version and digest must prove managed binary identity' validate_managed_singbox_binary_identity
  printf '%s\n' '# externally replaced content' >>"$SING_BOX_BINARY"
  if validate_managed_singbox_binary_identity >/dev/null 2>&1; then
    printf 'assertion failed: same-version sing-box content replacement must fail identity validation\n' >&2
    exit 1
  fi
  rm -rf -- "$binary_identity_fixture"
)

(
  legacy_fixture=$(mktemp -d)
  mkdir -p -- "$legacy_fixture/data" "$legacy_fixture/run"
  node_id=0123456789abcdef0123456789abcdef
  NODES_FILE="$legacy_fixture/data/nodes.json"
  TRAFFIC_FILE="$legacy_fixture/data/traffic.json"
  COUNTERS_FILE="$legacy_fixture/data/tc-counters.json"
  RUNTIME_DIR="$legacy_fixture/run"
  jq -n --arg id "$node_id" '{schema_version:1,nodes:[{
    node_id:$id,name:"Legacy",method:"2022-blake3-aes-256-gcm",
    password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,
    address:"192.0.2.1",address_type:"ipv4",status:"enabled",status_reason:"",
    quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,
    created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z",
    last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z"}]}' >"$NODES_FILE"
  jq -n --arg id "$node_id" '{schema_version:1,nodes:{($id):{
    current_upload_bytes:10,current_download_bytes:20,total_upload_bytes:100,total_download_bytes:200,
    quota_bytes:0,reset_day:1,last_reset_at:"2026-01-01T00:00:00Z",
    next_reset_at:"2026-02-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}}}' >"$TRAFFIC_FILE"
  jq -n --arg id "$node_id" '{schema_version:1,nodes:{($id):{upload_kernel_bytes:77,download_kernel_bytes:88}}}' >"$COUNTERS_FILE"
  LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION=1
  assert_true 'pre-1.0.4 traffic state must migrate during the install transaction' traffic_migrate_legacy_state
  validate_traffic_file_semantic "$TRAFFIC_FILE" "$NODES_FILE"
  assert_equal 77 "$(jq -r --arg id "$node_id" '.nodes[$id].upload_kernel_bytes' "$TRAFFIC_FILE")" 'legacy upload baseline was not preserved'
  assert_equal 88 "$(jq -r --arg id "$node_id" '.nodes[$id].download_kernel_bytes' "$TRAFFIC_FILE")" 'legacy download baseline was not preserved'
  assert_equal 300 "$(jq -r --arg id "$node_id" '.nodes[$id].total_upload_bytes + .nodes[$id].total_download_bytes' "$TRAFFIC_FILE")" 'legacy totals changed during migration'
  rm -rf -- "$legacy_fixture"
)

assert_equal '2026-07' "$(settlement_period_label '2026-08-01T00:00:00Z')" 'a reset on day 1 must label the month whose traffic just closed'
assert_equal '2026-08' "$(settlement_period_label '2026-08-15T00:00:00Z')" 'an initial partial reset-day cycle must keep its closing month'
assert_equal '2026-09' "$(settlement_period_label '2026-09-15T00:00:00Z')" 'the next reset-day cycle must have a distinct month label'

history_test=$(mktemp)
printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$history_test"
traffic_append_history "$history_test" node-a Tokyo 2026-08 10 20 '2026-08-15T00:01:00Z' '2026-08-07T00:00:00Z' '2026-08-15T00:00:00Z'
traffic_append_history "$history_test" node-a Tokyo 2026-09 30 40 '2026-09-15T00:01:00Z' '2026-08-15T00:00:00Z' '2026-09-15T00:00:00Z'
assert_equal 2 "$(jq '.cycles["node-a"].entries | length' "$history_test")" 'adjacent non-day-1 settlement cycles must not overwrite each other'
assert_equal '2026-08-15T00:00:00Z' "$(jq -r '.cycles["node-a"].entries[0].period_end_at' "$history_test")" 'history must retain the scheduled settlement boundary'
purged_history=$(traffic_candidate_purge_deleted_node "$history_test" node-a)
assert_equal false "$(jq 'has("cycles") and (.cycles | has("node-a"))' <<<"$purged_history")" 'declining deleted-node history retention must purge completed cycles'
rm -f -- "$history_test"

tc_json=$(jq -nc '[
  {protocol:"ip",pref:49123,kind:"flower",options:{keys:{ip_proto:"tcp",dst_port:20001},actions:[{kind:"gact",stats:{bytes:100}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{keys:{ip_proto:"udp",dst_port:20001},actions:[{kind:"gact",stats:{bytes:200}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{keys:{ip_proto:6,dst_port:20001},actions:[{kind:"police",stats:{bytes:300}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{keys:{ip_proto:17,dst_port:20001},actions:[{kind:"police",stats:{bytes:400}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{keys:{ip_proto:"tcp",src_port:20001},actions:[{kind:"gact",stats:{bytes:500}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{keys:{ip_proto:"udp",src_port:20001},actions:[{kind:"gact",stats:{bytes:600}}]}},
  {protocol:"ip",pref:49100,kind:"flower",options:{keys:{ip_proto:"tcp",dst_port:20001},actions:[{kind:"gact",stats:{bytes:99999}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{keys:{ip_proto:"tcp",dst_port:20002},actions:[{kind:"gact",stats:{bytes:99999}}]}}
]')

upload=$(tc_counter_from_json "$tc_json" 49123 ingress 20001)
download=$(tc_counter_from_json "$tc_json" 49123 egress 20001)
assert_equal 1000 "$upload" 'traffic parser must sum the selected dynamic priority and destination port'
assert_equal 1100 "$download" 'traffic parser must use the source port for client download traffic'

assert_true 'IPv4 TCP gact rule must be detected' tc_rule_json_matches "$tc_json" 49123 ip tcp ingress 20001 gact
assert_true 'IPv6 TCP police rule must accept numeric ip_proto' tc_rule_json_matches "$tc_json" 49123 ipv6 tcp ingress 20001 police
scoped_tc_json=$(jq -nc '[
  {kind:"flower",options:{keys:{ip_proto:"tcp",dst_port:20001},actions:[{kind:"gact",stats:{bytes:100}}]}},
  {kind:"flower",options:{keys:{ip_proto:"udp",dst_port:20001},actions:[{kind:"gact",stats:{bytes:200}}]}}
]')
assert_true 'a protocol/pref-scoped iproute2 6.1 response may omit both top-level fields' tc_rule_json_matches "$scoped_tc_json" 49123 ip tcp ingress 20001 gact
assert_equal 1 "$(tc_rule_json_match_count "$scoped_tc_json" 49123 ip tcp ingress 20001 gact)" 'scoped tc validation must report the actual match count'
if tc_rule_json_matches "$tc_json" 49123 ip udp ingress 20001 police; then
  printf 'assertion failed: action mismatch should be rejected\n' >&2
  exit 1
fi
duplicate_rule_json=$(jq -c '. += [.[0]]' <<<"$tc_json")
if tc_rule_json_matches "$duplicate_rule_json" 49123 ip tcp ingress 20001 gact; then
  printf 'assertion failed: duplicate tc rules should be rejected\n' >&2
  exit 1
fi

captured_tc=$(
  tc() { printf '%q ' "$@"; }
  tc_add_flower_rule eth0 ingress ip tcp 20001 49123 gact 1000000001
)
[[ "$captured_tc" == *'pref 49123 protocol ip flower skip_hw ip_proto tcp dst_port 20001 action gact index 1000000001'* ]] || {
  printf 'assertion failed: flower rule must bind the owned shared action by index\n' >&2
  exit 1
}
captured_tc=$(
  tc_action_lookup() { return 1; }
  tc() { printf '%q ' "$@"; }
  tc_create_shared_action gact 1000000001 0123456789abcdef0123456789abcdef 0
)
[[ "$captured_tc" == *'actions add action gact pass index 1000000001 cookie 0123456789abcdef0123456789abcdef'* ]] || {
  printf 'assertion failed: unlimited aggregate action lacks identity/cookie\n' >&2
  exit 1
}
captured_tc=$(
  tc_action_lookup() { return 1; }
  tc() { printf '%q ' "$@"; }
  tc_create_shared_action police 1000000002 fedcba9876543210fedcba9876543210 20
)
[[ "$captured_tc" == *'actions add action police rate 20mbit burst 64kb mtu 64kb conform-exceed drop/pass index 1000000002 cookie fedcba9876543210fedcba9876543210'* ]] || {
  printf 'assertion failed: limited aggregate action lacks police drop/pass or ownership cookie\n' >&2
  exit 1
}
(
  TC_INLINE_ACTIONS=0
  tc_action_lookup() { return 1; }
  tc() {
    [[ "$1" == actions && "$2" == add ]] && return 1
    printf '%q ' "$@"
  }
  tc_create_shared_action gact 1000000003 00112233445566778899aabbccddeeff 0
  [[ "${TC_INLINE_ACTIONS:-0}" == 1 ]] || {
    printf 'assertion failed: standalone action failure did not select inline compatibility mode\n' >&2
    exit 1
  }
  captured_tc=$(tc_add_flower_rule eth0 ingress ip tcp 20001 49123 gact 1000000003 00112233445566778899aabbccddeeff)
  [[ "$captured_tc" == *'filter add dev eth0 ingress pref 49123 protocol ip flower skip_hw ip_proto tcp dst_port 20001 action gact index 1000000003 cookie 00112233445566778899aabbccddeeff'* ]] || {
    printf 'assertion failed: inline action fallback did not carry its ownership cookie\n' >&2
    exit 1
  }
)
assert_equal 49123 "$(tc_family_pref 49123 ip)" 'IPv4 tc rules must retain the base priority'
assert_equal 49124 "$(tc_family_pref 49123 ipv6)" 'IPv6 tc rules must use a distinct priority'

action_json=$(jq -nc '[{actions:[{kind:"gact",index:1000000001,cookie:"0123456789abcdef0123456789abcdef",bind:4,stats:{bytes:12345}}]}]')
assert_equal 12345 "$(tc_action_counter_from_json "$action_json" gact 1000000001 0123456789abcdef0123456789abcdef)" 'traffic must read one owned aggregate action counter'
if tc_action_counter_from_json "$action_json" gact 1000000001 fedcba9876543210fedcba9876543210 >/dev/null 2>&1; then
  printf 'assertion failed: an action with the wrong ownership cookie must be rejected\n' >&2
  exit 1
fi
identity_ingress=$(bandwidth_action_identity 0123456789abcdef0123456789abcdef ingress)
identity_ingress_again=$(bandwidth_action_identity 0123456789abcdef0123456789abcdef ingress)
identity_egress=$(bandwidth_action_identity 0123456789abcdef0123456789abcdef egress)
assert_equal "$identity_ingress" "$identity_ingress_again" 'tc action identity must be stable across rule rebuilds'
[[ "$identity_ingress" != "$identity_egress" ]] || { printf 'assertion failed: upload and download actions need distinct identities\n' >&2; exit 1; }

split_tc_json=$(jq -nc '[
  {protocol:"ip",pref:49123,kind:"flower",options:{keys:{dst_port:20001},actions:[{kind:"gact",stats:{bytes:100}}]}},
  {protocol:"ipv6",pref:49124,kind:"flower",options:{keys:{dst_port:20001},actions:[{kind:"gact",stats:{bytes:300}}]}}
]')
tc() { printf '%s' "$split_tc_json"; }
assert_equal 400 "$(tc_counter_json eth0 ingress 20001 49123)" 'traffic sampling must merge IPv4 and IPv6 tc priorities'
if (tc() { return 1; }; tc_counter_json eth0 ingress 20001 49123 >/dev/null 2>&1); then
  printf 'assertion failed: a failed tc query must not be converted into a zero counter\n' >&2
  exit 1
fi

grep -q 'installed_node_count=' "$ROOT/install.sh"
if grep -q '\$(node_count)' "$ROOT/install.sh"; then
  printf 'assertion failed: install.sh still calls an unloaded node_count function\n' >&2
  exit 1
fi
grep -q '"$SCRIPT_DIR/VERSION" "$target/VERSION"' "$ROOT/install.sh"
grep -q 'source "$SCRIPT_DIR/lib/service.sh"' "$ROOT/install.sh"
grep -q 'manager_state_set_json install_completed true' "$ROOT/ss-manager.sh"
grep -q '已补齐首节点提交后中断的流量维护服务启用步骤' "$ROOT/ss-manager.sh"
grep -q 'enable_manager_maintenance_service' "$ROOT/install.sh"
grep -q 'candidate_dir=$(dirname -- "$SING_BOX_BINARY")' "$ROOT/lib/singbox.sh"
if grep -q 'local candidate="$RUNTIME_DIR/sing-box-${version}-${HOST_ARCH}.candidate"' "$ROOT/lib/singbox.sh"; then
  printf 'assertion failed: sing-box candidate must not execute from the runtime directory\n' >&2
  exit 1
fi

for service_aware_file in install.sh lib/backup.sh lib/menu.sh lib/singbox.sh lib/update.sh; do
  if grep -q 'systemctl' "$ROOT/$service_aware_file"; then
    printf 'assertion failed: %s bypasses the init-system abstraction\n' "$service_aware_file" >&2
    exit 1
  fi
done

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

owned_plan="$test_tmp/bandwidth-plan.json"
owned_delete_log="$test_tmp/owned-delete.log"
jq -n '{schema_version:2,pref:49123,boot_id:"00000000-0000-0000-0000-000000000001",interfaces:["eth0"],updated_at:"2026-01-01T00:00:00Z",actions:[{node_id:"0123456789abcdef0123456789abcdef",direction:"ingress",port:20001,kind:"gact",index:1000000001,cookie:"0123456789abcdef0123456789abcdef",limit_mbps:0}]}' >"$owned_plan"
(
  tc_action_lookup() {
    jq -nc '{kind:"gact",index:1000000001,cookie:"0123456789abcdef0123456789abcdef",bind:4,stats:{bytes:0}}'
  }
  tc_filter_scoped_json() {
    local _interface=$1 direction=$2 family=$3 _pref=$4
    : "$_interface" "$_pref"
    if [[ "$direction" != ingress ]]; then printf '[]'; return 0; fi
    if [[ "$family" == ip ]]; then
      jq -nc '[
        {handle:"0x1",options:{keys:{ip_proto:"tcp",dst_port:20001},actions:[{kind:"gact",index:1000000001}]}},
        {handle:"0x2",options:{keys:{ip_proto:"udp",dst_port:20001},actions:[{kind:"gact",index:1000000001}]}},
        {handle:"0xff",options:{keys:{ip_proto:"tcp",dst_port:29999},actions:[{kind:"mirred",index:99}]}}
      ]'
    else
      jq -nc '[
        {handle:"0x3",options:{keys:{ip_proto:6,dst_port:20001},actions:[{kind:"gact",index:1000000001}]}},
        {handle:"0x4",options:{keys:{ip_proto:17,dst_port:20001},actions:[{kind:"gact",index:1000000001}]}}
      ]'
    fi
  }
  tc_delete_owned_action() { printf 'owned-action %s %s %s\n' "$1" "$2" "$3" >>"$owned_delete_log"; }
  tc() { printf '%q ' "$@" >>"$owned_delete_log"; printf '\n' >>"$owned_delete_log"; }
  bandwidth_remove_plan "$owned_plan"
)
assert_equal 4 "$(grep -c '^filter del ' "$owned_delete_log")" 'owned cleanup must delete exactly the four manager filters'
if grep '^filter del ' "$owned_delete_log" | grep -vq ' handle '; then
  printf 'assertion failed: owned cleanup must address every filter by exact handle\n' >&2
  exit 1
fi
if grep -q '0xff' "$owned_delete_log"; then
  printf 'assertion failed: a foreign filter sharing the manager priority was deleted\n' >&2
  exit 1
fi
grep -q '^owned-action gact 1000000001 0123456789abcdef0123456789abcdef$' "$owned_delete_log"
if (
  tc_action_lookup() { jq -nc '{kind:"gact",index:1000000001,cookie:"ffffffffffffffffffffffffffffffff",bind:4}'; }
  bandwidth_remove_plan "$owned_plan" >/dev/null 2>&1
); then
  printf 'assertion failed: cleanup must stop when the action cookie does not prove ownership\n' >&2
  exit 1
fi
corrupt_plan="$test_tmp/corrupt-bandwidth-plan.json"
printf '%s\n' '{"schema_version":2,"actions":' >"$corrupt_plan"
if (
  bandwidth_plan_path() { printf '%s' "$corrupt_plan"; }
  delete_manager_tc_filters 49123 "$test_tmp/unused-nodes.json" >/dev/null 2>&1
); then
  printf 'assertion failed: a corrupt tc ownership plan must stop cleanup\n' >&2
  exit 1
fi
[[ -f "$corrupt_plan" ]] || { printf 'assertion failed: corrupt ownership evidence must be preserved for recovery\n' >&2; exit 1; }

NODES_FILE="$test_tmp/live-nodes.json"
TRAFFIC_FILE="$test_tmp/live-traffic.json"
live_node=$(jq -nc '{node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo",method:"2022-blake3-aes-256-gcm",password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,address:"192.0.2.1",address_type:"ipv4",status:"enabled",status_reason:"",quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z",last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z"}')
jq -n --argjson node "$live_node" '{schema_version:1,nodes:[$node]}' >"$NODES_FILE"
jq -n '{schema_version:1,nodes:{"0123456789abcdef0123456789abcdef":{current_upload_bytes:0,current_download_bytes:0,total_upload_bytes:0,total_download_bytes:0}}}' >"$TRAFFIC_FILE"
captured_name=$(printf 'ss\n' | read_nonempty '请输入节点名称' 2>"$test_tmp/name-prompt.log")
assert_equal 'ss' "$captured_name" 'interactive name prompts must not contaminate command-substitution results'
captured_method=$(printf '2\n' | choose_method 2>"$test_tmp/method-prompt.log")
assert_equal '2022-blake3-aes-256-gcm' "$captured_method" 'interactive method prompts must not contaminate command-substitution results'
selected_id=$(printf '1\n' | select_node_id '请选择节点' 2>"$test_tmp/select-prompt.log")
assert_equal '0123456789abcdef0123456789abcdef' "$selected_id" 'node selection must return only the selected Node ID'
cp -- "$NODES_FILE" "$NODES_FILE.valid"
printf '{invalid\n' >"$NODES_FILE"
selection_status=0
select_node_id '请选择节点' >/dev/null 2>&1 || selection_status=$?
assert_equal 2 "$selection_status" 'node selection must distinguish a database error from user cancellation'
port_status=0
port_available 20002 >/dev/null 2>&1 || port_status=$?
assert_equal 2 "$port_status" 'port selection must fail closed when the node database cannot be queried'
if unique_node_name Tokyo >/dev/null 2>&1; then
  printf 'assertion failed: unique-name generation must not treat a database error as an available name\n' >&2
  exit 1
fi
mv -f -- "$NODES_FILE.valid" "$NODES_FILE"
saved_port_available=$(declare -f port_available)
port_available() { return 0; }
captured_port=$(printf '20002\n' | choose_port 2>"$test_tmp/port-prompt.log")
eval "$saved_port_available"
assert_equal '20002' "$captured_port" 'port entry must accept a direct port without a menu choice'
captured_address=$(printf '198.51.100.10\n' | choose_address 2>"$test_tmp/address-prompt.log")
assert_equal $'198.51.100.10\tipv4' "$captured_address" 'direct node addresses must not require a menu choice'
same_port_candidate="$test_tmp/same-port.json"
changed_port_candidate="$test_tmp/changed-port.json"
jq . "$NODES_FILE" >"$same_port_candidate"
jq '.nodes[0].port=20002' "$NODES_FILE" >"$changed_port_candidate"
system_port_in_use() { return 0; }
singbox_is_active() { return 0; }
singbox_owns_node_port() { return 0; }
assert_true 'the running node may retain its own occupied port' validate_candidate_nodes "$same_port_candidate"
assert_true 'the running node may select its unchanged occupied port' port_available 20001 0123456789abcdef0123456789abcdef
if (validate_candidate_nodes "$changed_port_candidate" >/dev/null 2>&1); then
  printf 'assertion failed: changing to an occupied port should be rejected\n' >&2
  exit 1
fi
wrong_address_type_candidate="$test_tmp/wrong-address-type.json"
jq '.nodes[0].address_type="ipv6"' "$same_port_candidate" >"$wrong_address_type_candidate"
if (validate_candidate_nodes "$wrong_address_type_candidate" >/dev/null 2>&1); then
  printf 'assertion failed: candidate address_type must match the actual address value\n' >&2
  exit 1
fi

disabled_candidate="$test_tmp/disabled.json"
enabling_candidate="$test_tmp/enabling.json"
jq '.nodes[0].status="disabled_manual"' "$NODES_FILE" >"$disabled_candidate"
install -m 600 -- "$disabled_candidate" "$NODES_FILE"
assert_true 'an occupied port reserved by a disabled node must not block unrelated transactions' validate_candidate_nodes "$disabled_candidate"
jq '.nodes[0].status="enabled"' "$disabled_candidate" >"$enabling_candidate"
if (validate_candidate_nodes "$enabling_candidate" >/dev/null 2>&1); then
  printf 'assertion failed: enabling a node whose port was taken while disabled should be rejected\n' >&2
  exit 1
fi
install -m 600 -- "$same_port_candidate" "$NODES_FILE"

traffic_case="$test_tmp/traffic-atomic"
mkdir -p -- "$traffic_case/runtime"
install -m 600 -- "$NODES_FILE" "$traffic_case/nodes.json"
jq -n '{schema_version:1,nodes:{"0123456789abcdef0123456789abcdef":{
  current_upload_bytes:10,current_download_bytes:20,total_upload_bytes:100,total_download_bytes:200,
  upload_kernel_bytes:100,download_kernel_bytes:200,quota_bytes:0,reset_day:1,
  last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}}}' >"$traffic_case/traffic.json"
install -m 600 -- "$traffic_case/traffic.json" "$traffic_case/traffic.before.json"
(
  RUNTIME_DIR="$traffic_case/runtime"
  NODES_FILE="$traffic_case/nodes.json"
  TRAFFIC_FILE="$traffic_case/traffic.json"
  COUNTERS_FILE="$traffic_case/legacy-counters.json"
  traffic_interfaces() { printf 'eth0\n'; }
  traffic_ensure_tc_rules_no_lock() { return 0; }
  tc_node_counter() {
    if [[ "$3" == ingress ]]; then printf '150'; else return 1; fi
  }
  if traffic_collect_no_lock >/dev/null 2>&1; then
    printf 'assertion failed: traffic collection must fail if either tc action counter cannot be read\n' >&2
    exit 1
  fi
  cmp -s -- "$TRAFFIC_FILE" "$traffic_case/traffic.before.json" || {
    printf 'assertion failed: a partial traffic sample changed the persisted totals/baselines\n' >&2
    exit 1
  }
)
printf '%s\n' '{"schema_version":1,"nodes":{}}' >"$traffic_case/legacy-counters.json"
(
  RUNTIME_DIR="$traffic_case/runtime"
  NODES_FILE="$traffic_case/nodes.json"
  TRAFFIC_FILE="$traffic_case/traffic.json"
  COUNTERS_FILE="$traffic_case/legacy-counters.json"
  traffic_interfaces() { printf 'eth0\n'; }
  traffic_ensure_tc_rules_no_lock() { return 0; }
  tc_node_counter() { if [[ "$3" == ingress ]]; then printf '150'; else printf '260'; fi; }
  traffic_collect_no_lock
  assert_equal 60 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].current_upload_bytes' "$TRAFFIC_FILE")" 'upload delta and baseline must commit together'
  assert_equal 80 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].current_download_bytes' "$TRAFFIC_FILE")" 'download delta and baseline must commit together'
  assert_equal 150 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].upload_kernel_bytes' "$TRAFFIC_FILE")" 'new upload baseline must share traffic.json atomic commit'
  assert_equal 260 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].download_kernel_bytes' "$TRAFFIC_FILE")" 'new download baseline must share traffic.json atomic commit'
  [[ ! -e "$COUNTERS_FILE" ]] || { printf 'assertion failed: successful migration must remove legacy tc-counters.json\n' >&2; exit 1; }
)
baseline_live="$traffic_case/baseline-live.json"
baseline_candidate="$traffic_case/baseline-candidate.json"
install -m 600 -- "$traffic_case/traffic.json" "$baseline_live"
install -m 600 -- "$traffic_case/traffic.json" "$baseline_candidate"
# A later stub deliberately replaces this sourced function for a separate test.
# shellcheck disable=SC2218
RUNTIME_DIR="$traffic_case/runtime" traffic_reset_kernel_baselines "$NODES_FILE" "$baseline_candidate"
assert_equal 150 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].upload_kernel_bytes' "$baseline_live")" 'resetting a transaction candidate must not mutate the live/backup source'
assert_equal 0 "$(jq -r '.nodes["0123456789abcdef0123456789abcdef"].upload_kernel_bytes' "$baseline_candidate")" 'transaction candidate baselines must reset before commit'

(
  RUNTIME_DIR="$traffic_case/runtime"
  NODES_FILE="$traffic_case/nodes.json"
  TRAFFIC_FILE="$traffic_case/traffic.json"
  COUNTERS_FILE="$traffic_case/legacy-counters.json"
  traffic_interfaces() { return 0; }
  traffic_ensure_tc_rules_no_lock() { printf 'unexpected rebuild\n' >&2; return 1; }
  before=$(sha256sum -- "$TRAFFIC_FILE" | awk '{print $1}')
  traffic_collect_no_lock >/dev/null 2>&1
  after=$(sha256sum -- "$TRAFFIC_FILE" | awk '{print $1}')
  assert_equal "$before" "$after" 'sampling without a default interface must leave traffic data untouched'
)

tc_rebuild_log="$test_tmp/tc-rebuild.log"
bandwidth_plan_matches_current_boot() { return 0; }
bandwidth_plan_matches_current_families() { return 0; }
bandwidth_check_nodes() { return 1; }
traffic_interfaces_match_current_routes() { return 0; }
traffic_collect_actions_no_rule_check() { printf 'collect ' >>"$tc_rebuild_log"; }
bandwidth_apply_and_check() { printf 'apply ' >>"$tc_rebuild_log"; }
traffic_reset_kernel_baselines() { printf 'reset ' >>"$tc_rebuild_log"; }
assert_true 'missing tc rules must be rebuilt before traffic sampling' traffic_ensure_tc_rules_no_lock 2>/dev/null
assert_equal 'collect apply reset ' "$(cat "$tc_rebuild_log")" 'tc rebuild must save action counters before resetting baselines'

: >"$tc_rebuild_log"
bandwidth_plan_matches_current_boot() { return 0; }
traffic_interfaces_match_current_routes() { return 1; }
detect_traffic_interfaces() { printf 'refresh ' >>"$tc_rebuild_log"; }
INSTALL_TRANSACTION_RUNTIME_ACTIVE=1
assert_true 'a same-boot route change must preserve readable action counters before refresh' traffic_ensure_tc_rules_no_lock 2>/dev/null
INSTALL_TRANSACTION_RUNTIME_ACTIVE=0
assert_equal 'collect refresh apply reset ' "$(cat "$tc_rebuild_log")" 'route refresh discarded readable pre-refresh action counters'

: >"$tc_rebuild_log"
traffic_interfaces_match_current_routes() { return 0; }
bandwidth_plan_matches_current_families() { return 1; }
INSTALL_TRANSACTION_RUNTIME_ACTIVE=1
assert_true 'a same-boot route-family change must preserve counters and use the refresh transaction' traffic_ensure_tc_rules_no_lock 2>/dev/null
INSTALL_TRANSACTION_RUNTIME_ACTIVE=0
assert_equal 'collect refresh apply reset ' "$(cat "$tc_rebuild_log")" 'route-family refresh bypassed the transactional counter-preserving path'

: >"$tc_rebuild_log"
bandwidth_plan_matches_current_boot() { return 1; }
bandwidth_check_nodes() { return 0; }
INSTALL_TRANSACTION_RUNTIME_ACTIVE=1
assert_true 'a new kernel boot must refresh interfaces and rebuild tc rules' traffic_ensure_tc_rules_no_lock 2>/dev/null
INSTALL_TRANSACTION_RUNTIME_ACTIVE=0
assert_equal 'refresh apply reset ' "$(cat "$tc_rebuild_log")" 'reboot recovery must refresh interfaces before rebuilding rules'

runtime_health_log="$test_tmp/runtime-health.log"
singbox_is_active() { return 1; }
singbox_confirm_inactive() { ! singbox_is_active; }
singbox_check_config() { printf 'check ' >>"$runtime_health_log"; }
assert_true 'a transaction must accept a valid config while preserving an intentionally stopped service' transaction_runtime_health_check "$NODES_FILE" 0
assert_equal 'check ' "$(cat "$runtime_health_log")" 'stopped-state health must use the official config check'
singbox_is_active() { return 0; }
if (transaction_runtime_health_check "$NODES_FILE" 0 >/dev/null 2>&1); then
  printf 'assertion failed: a stopped-state transaction must reject an unexpectedly running service\n' >&2
  exit 1
fi

state_guard="$test_tmp/state-guard"
mkdir -p -- "$state_guard/backups"
printf '%s\n' '{"schema_version":1}' >"$state_guard/manager.json"
printf '%s\n' '{"schema_version":1,"nodes":[]}' >"$state_guard/nodes.json"
printf '%s\n' '{"schema_version":1,"nodes":{}}' >"$state_guard/traffic.json"
if (
  MANAGER_STATE="$state_guard/manager.json"
  NODES_FILE="$state_guard/nodes.json"
  TRAFFIC_FILE="$state_guard/traffic.json"
  HISTORY_FILE="$state_guard/missing-history.json"
  BACKUP_DIR="$state_guard/backups"
  validate_installed_state_files >/dev/null 2>&1
); then
  printf 'assertion failed: repair must stop instead of recreating a missing authoritative state file\n' >&2
  exit 1
fi
printf '%s\n' '{"schema_version":1,"cycles":[]}' >"$state_guard/bad-history.json"
if (
  MANAGER_STATE="$state_guard/manager.json"
  NODES_FILE="$state_guard/nodes.json"
  TRAFFIC_FILE="$state_guard/traffic.json"
  HISTORY_FILE="$state_guard/bad-history.json"
  BACKUP_DIR="$state_guard/backups"
  validate_installed_state_files >/dev/null 2>&1
); then
  printf 'assertion failed: repair must reject structurally invalid authoritative state\n' >&2
  exit 1
fi

service_case="$test_tmp/service-backup"
mkdir -p -- "$service_case/definitions"
printf 'old unit\n' >"$service_case/definitions/one"
(
  manager_update_service_names() { printf 'one\ntwo\n'; }
  service_definition_path() { printf '%s/definitions/%s' "$service_case" "$1"; }
  service_manager_reload() { :; }
  manager_update_backup_service_files "$service_case/snapshot"
  printf 'new unit\n' >"$service_case/definitions/one"
  printf 'unexpected unit\n' >"$service_case/definitions/two"
  manager_update_restore_service_files "$service_case/snapshot"
)
assert_equal 'old unit' "$(cat "$service_case/definitions/one")" 'manager rollback must restore the previous service definition'
[[ ! -e "$service_case/definitions/two" ]] || { printf 'assertion failed: manager rollback must remove a service definition that was previously absent\n' >&2; exit 1; }

grep -q 'run_menu_action node_add_flow' "$ROOT/lib/menu.sh"
grep -q 'MENU_ACTION_STATUS' "$ROOT/ss-manager.sh"
grep -q 'generate_singbox_config "$NODES_FILE" "$candidate"' "$ROOT/install.sh"
grep -q 'backup_create_manual_flow' "$ROOT/lib/backup.sh"
grep -q 'validate_installed_state_files' "$ROOT/install.sh"
grep -Fq 'bash "$tmp_dir/Ss2022/install.sh" <&3' "$ROOT/bootstrap.sh"
grep -q 'traffic_migrate_legacy_state' "$ROOT/install.sh"
grep -q 'release_manager_lock' "$ROOT/install.sh"
if grep -q 'load_json_or_default "$COUNTERS_FILE"' "$ROOT/lib/common.sh"; then
  printf 'assertion failed: new installations must not recreate the legacy two-file traffic baseline\n' >&2
  exit 1
fi
singbox_commit_line=$(grep -n 'singbox_update_transaction_commit' "$ROOT/lib/update.sh" | tail -n 1 | cut -d: -f1)
singbox_prune_line=$(grep -n "backup_prune || warn 'sing-box 更新已经提交" "$ROOT/lib/update.sh" | cut -d: -f1)
[[ -n "$singbox_commit_line" && -n "$singbox_prune_line" && "$singbox_prune_line" -gt "$singbox_commit_line" ]] || {
  printf 'assertion failed: sing-box backup pruning must run only after the update transaction commits\n' >&2
  exit 1
}
grep -q 'manager_update_finalize_switched_program' "$ROOT/lib/update.sh"
grep -q 'manager_update_restore_service_files' "$ROOT/lib/update.sh"
grep -q 'exit 75' "$ROOT/lib/update.sh"
grep -q 'status == 75' "$ROOT/lib/menu.sh"
grep -q 'exec "$PROGRAM_DIR/ss-manager.sh" menu' "$ROOT/lib/menu.sh"
restore_line=$(grep -n 'restore_kernel_settings_on_uninstall' "$ROOT/lib/menu.sh" | tail -n 1 | cut -d: -f1)
mode_two_line=$(grep -n 'if \[\[ "$mode" == 2 \]\]' "$ROOT/lib/menu.sh" | tail -n 1 | cut -d: -f1)
(( restore_line < mode_two_line )) || { printf 'assertion failed: uninstall mode 2 deletes manager state before restoring kernel settings\n' >&2; exit 1; }

printf 'regression tests passed\n'
