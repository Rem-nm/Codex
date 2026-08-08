#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
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

node=$(jq -nc '{node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo HK",method:"2022-blake3-aes-256-gcm",password:"AB+/==",port:20001,address:"2001:db8::1",address_type:"ipv6",status:"enabled"}')
uri=$(node_sip002_uri "$node")
assert_equal 'ss://2022-blake3-aes-256-gcm:AB%2B%2F%3D%3D@[2001:db8::1]:20001#Tokyo%20HK' "$uri" 'AEAD-2022 SIP002 userinfo must be percent-encoded, not Base64URL encoded'

base64_node=$(node_base64_uri "$node")
decoded_uri=$(printf '%s' "$base64_node" | base64 -d)
assert_equal "$uri" "$decoded_uri" 'Base64 node information must decode to the canonical SIP002 URI'

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
  {protocol:"ip",pref:49123,kind:"flower",options:{ip_proto:"tcp",dst_port:20001,actions:[{kind:"gact",stats:{bytes:100}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{ip_proto:"udp",dst_port:20001,actions:[{kind:"gact",stats:{bytes:200}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{ip_proto:6,dst_port:20001,actions:[{kind:"police",stats:{bytes:300}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{ip_proto:17,dst_port:20001,actions:[{kind:"police",stats:{bytes:400}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{ip_proto:"tcp",src_port:20001,actions:[{kind:"gact",stats:{bytes:500}}]}},
  {protocol:"ipv6",pref:49123,kind:"flower",options:{ip_proto:"udp",src_port:20001,actions:[{kind:"gact",stats:{bytes:600}}]}},
  {protocol:"ip",pref:49100,kind:"flower",options:{ip_proto:"tcp",dst_port:20001,actions:[{kind:"gact",stats:{bytes:99999}}]}},
  {protocol:"ip",pref:49123,kind:"flower",options:{ip_proto:"tcp",dst_port:20002,actions:[{kind:"gact",stats:{bytes:99999}}]}}
]')

upload=$(tc_counter_from_json "$tc_json" 49123 ingress 20001)
download=$(tc_counter_from_json "$tc_json" 49123 egress 20001)
assert_equal 1000 "$upload" 'traffic parser must sum the selected dynamic priority and destination port'
assert_equal 1100 "$download" 'traffic parser must use the source port for client download traffic'

assert_true 'IPv4 TCP gact rule must be detected' tc_rule_json_matches "$tc_json" 49123 ip tcp ingress 20001 gact
assert_true 'IPv6 TCP police rule must accept numeric ip_proto' tc_rule_json_matches "$tc_json" 49123 ipv6 tcp ingress 20001 police
if tc_rule_json_matches "$tc_json" 49123 ip udp ingress 20001 police; then
  printf 'assertion failed: action mismatch should be rejected\n' >&2
  exit 1
fi
duplicate_rule_json=$(jq -c '. += [.[0]]' <<<"$tc_json")
if tc_rule_json_matches "$duplicate_rule_json" 49123 ip tcp ingress 20001 gact; then
  printf 'assertion failed: duplicate tc rules should be rejected\n' >&2
  exit 1
fi

captured_tc=''
tc() { captured_tc=$(printf '%q ' "$@"); }
tc_add_flower_rule eth0 ingress ip tcp 20001 0 49123
[[ "$captured_tc" == *'action gact pass'* ]] || { printf 'assertion failed: unlimited rule lacks gact pass\n' >&2; exit 1; }
tc_add_flower_rule eth0 egress ipv6 udp 20001 20 49123
[[ "$captured_tc" == *'action police rate 20mbit'* && "$captured_tc" == *'conform-exceed drop/pass'* ]] || {
  printf 'assertion failed: limited rule lacks police drop/pass\n' >&2
  exit 1
}

grep -q 'installed_node_count=' "$ROOT/install.sh"
if grep -q '\$(node_count)' "$ROOT/install.sh"; then
  printf 'assertion failed: install.sh still calls an unloaded node_count function\n' >&2
  exit 1
fi
grep -q '"$SCRIPT_DIR/VERSION" "$PROGRAM_DIR/VERSION"' "$ROOT/install.sh"
grep -q 'source "$SCRIPT_DIR/lib/service.sh"' "$ROOT/install.sh"
grep -q 'manager_state_set_json install_completed true' "$ROOT/ss-manager.sh"
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
NODES_FILE="$test_tmp/live-nodes.json"
live_node=$(jq -nc '{node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo",method:"2022-blake3-aes-256-gcm",password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,address:"192.0.2.1",address_type:"ipv4",status:"enabled",status_reason:"",quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z",last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z"}')
jq -n --argjson node "$live_node" '{schema_version:1,nodes:[$node]}' >"$NODES_FILE"
same_port_candidate="$test_tmp/same-port.json"
changed_port_candidate="$test_tmp/changed-port.json"
jq . "$NODES_FILE" >"$same_port_candidate"
jq '.nodes[0].port=20002' "$NODES_FILE" >"$changed_port_candidate"
system_port_in_use() { return 0; }
assert_true 'the running node may retain its own occupied port' validate_candidate_nodes "$same_port_candidate"
assert_true 'the running node may select its unchanged occupied port' port_available 20001 0123456789abcdef0123456789abcdef
if (validate_candidate_nodes "$changed_port_candidate" >/dev/null 2>&1); then
  printf 'assertion failed: changing to an occupied port should be rejected\n' >&2
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

tc_rebuild_log="$test_tmp/tc-rebuild.log"
bandwidth_plan_matches_current_boot() { return 0; }
bandwidth_check_nodes() { return 1; }
bandwidth_apply_and_check() { printf 'apply ' >>"$tc_rebuild_log"; }
traffic_reset_kernel_baselines() { printf 'reset ' >>"$tc_rebuild_log"; }
assert_true 'missing tc rules must be rebuilt before traffic sampling' traffic_ensure_tc_rules_no_lock 2>/dev/null
assert_equal 'apply reset ' "$(cat "$tc_rebuild_log")" 'tc rebuild must reset persisted kernel baselines'

: >"$tc_rebuild_log"
bandwidth_plan_matches_current_boot() { return 1; }
bandwidth_check_nodes() { return 0; }
detect_traffic_interfaces() { printf 'refresh ' >>"$tc_rebuild_log"; }
assert_true 'a new kernel boot must refresh interfaces and rebuild tc rules' traffic_ensure_tc_rules_no_lock 2>/dev/null
assert_equal 'refresh apply reset ' "$(cat "$tc_rebuild_log")" 'reboot recovery must refresh interfaces before rebuilding rules'

runtime_health_log="$test_tmp/runtime-health.log"
singbox_is_active() { return 1; }
singbox_check_config() { printf 'check ' >>"$runtime_health_log"; }
assert_true 'a transaction must accept a valid config while preserving an intentionally stopped service' transaction_runtime_health_check "$NODES_FILE" 0
assert_equal 'check ' "$(cat "$runtime_health_log")" 'stopped-state health must use the official config check'
singbox_is_active() { return 0; }
if (transaction_runtime_health_check "$NODES_FILE" 0 >/dev/null 2>&1); then
  printf 'assertion failed: a stopped-state transaction must reject an unexpectedly running service\n' >&2
  exit 1
fi

grep -q 'run_menu_action node_add_flow' "$ROOT/lib/menu.sh"
grep -q 'MENU_ACTION_STATUS' "$ROOT/ss-manager.sh"
grep -q 'generate_singbox_config "$NODES_FILE" "$candidate"' "$ROOT/install.sh"
grep -q 'backup_create_manual_flow' "$ROOT/lib/backup.sh"

printf 'regression tests passed\n'
