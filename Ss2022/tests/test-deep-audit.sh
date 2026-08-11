#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/system.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/service.sh"
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
# shellcheck disable=SC1091
source "$ROOT/lib/menu.sh"

fail_test() { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }
assert_equal() {
  local expected=$1 actual=$2 message=$3
  [[ "$expected" == "$actual" ]] || fail_test "$message (expected=$expected actual=$actual)"
}

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

make_fixture() {
  local base=$1 node_id=0123456789abcdef0123456789abcdef
  mkdir -p -- "$base/config" "$base/data" "$base/run" "$base/backups" "$base/sing-box"
  jq -n '{schema_version:1,manager_version:"1.0.5",init_system:"systemd",install_completed:true,
    sing_box_version:"1.13.16",sing_box_binary_managed:true,sing_box_version_lock:null,
    created_at:"2026-01-01T00:00:00Z",listen_mode:"family-specific",listen_address:"::",
    tfo_kernel_supported:true,tfo_kernel_enabled:false,tfo_config_supported:true,
    bbr_supported:false,bbr_enabled:false,quota_include_unauthenticated_upload:false,
    tc_capabilities_verified:true,tc_capability_signature:"test"}' >"$base/config/manager.json"
  jq -n --arg id "$node_id" '{schema_version:1,nodes:[{
    node_id:$id,name:"Tokyo",method:"2022-blake3-aes-256-gcm",
    password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,
    address:"example.com",address_type:"domain",status:"enabled",status_reason:"",
    quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,
    created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z",
    last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z"}]}' >"$base/data/nodes.json"
  jq -n --arg id "$node_id" '{schema_version:1,nodes:{($id):{
    current_upload_bytes:10,current_download_bytes:20,total_upload_bytes:100,total_download_bytes:200,
    upload_kernel_bytes:0,download_kernel_bytes:0,quota_bytes:0,reset_day:1,
    last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z",
    updated_at:"2026-01-01T00:00:00Z"}}}' >"$base/data/traffic.json"
  printf '%s\n' '{"schema_version":1,"cycles":{}}' >"$base/data/traffic-history.json"
  printf '%s\n' '{"schema_version":1,"interfaces":["eth0"]}' >"$base/data/interfaces.json"
  printf '%s\n' '{"inbounds":[]}' >"$base/sing-box/config.json"
}

fixture="$test_tmp/fixture"
make_fixture "$fixture"
MANAGER_STATE="$fixture/config/manager.json"
NODES_FILE="$fixture/data/nodes.json"
TRAFFIC_FILE="$fixture/data/traffic.json"
HISTORY_FILE="$fixture/data/traffic-history.json"
INTERFACES_FILE="$fixture/data/interfaces.json"
CONFIG_DIR="$fixture/config"
DATA_DIR="$fixture/data"
RUNTIME_DIR="$fixture/run"
BACKUP_DIR="$fixture/backups"
STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
SING_BOX_CONFIG="$fixture/sing-box/config.json"

validate_manager_state_semantic "$MANAGER_STATE" || fail_test 'valid manager state rejected'
validate_nodes_file_semantic "$NODES_FILE" || fail_test 'valid node state rejected'
validate_traffic_file_semantic "$TRAFFIC_FILE" "$NODES_FILE" || fail_test 'valid traffic state rejected'
validate_history_file_semantic "$HISTORY_FILE" || fail_test 'valid history state rejected'
validate_interfaces_file_semantic "$INTERFACES_FILE" || fail_test 'valid interface state rejected'

# BusyBox mv has no -T flag, so every durable file publisher goes through a
# portable guard that must reject directories instead of moving a temp file
# inside the destination path.
atomic_source="$test_tmp/atomic-source"
atomic_destination="$test_tmp/atomic-destination"
printf '%s\n' payload >"$atomic_source"
mkdir -p -- "$atomic_destination"
if atomic_replace_regular_file "$atomic_source" "$atomic_destination"; then
  fail_test 'atomic replacement accepted a directory destination'
fi
[[ -f "$atomic_source" ]] || fail_test 'rejected atomic replacement consumed its source'
[[ ! -e "$atomic_destination/atomic-source" ]] || fail_test 'atomic replacement moved a temp file inside a directory'
replace_call_count=$(grep -Fc 'atomic_replace_regular_file "$temporary" "$destination"' "$ROOT/lib/common.sh")
assert_equal 4 "$replace_call_count" 'not every durable file publisher uses the directory-safe replacement helper'
directory_source="$test_tmp/directory-source"
directory_destination="$test_tmp/directory-destination"
mkdir -p -- "$directory_source" "$directory_destination"
if atomic_move_directory_to_absent_path "$directory_source" "$directory_destination"; then
  fail_test 'atomic directory move accepted an existing destination'
fi
[[ -d "$directory_source" ]] || fail_test 'rejected directory move consumed its source'

# Managed directory creation and durability helpers must never follow a direct
# directory symlink into an operator-owned tree.
directory_target="$test_tmp/directory-target"
directory_link="$test_tmp/directory-link"
mkdir -p -- "$directory_target"
ln -s -- "$directory_target" "$directory_link"
if [[ -L "$directory_link" ]]; then
  if ensure_dir "$directory_link" 700 >/dev/null 2>&1; then
    fail_test 'managed directory creation followed a directory symlink'
  fi
  if durable_sync_path "$directory_link" >/dev/null 2>&1; then
    fail_test 'durability sync followed a directory symlink'
  fi
else
  # Some Windows-hosted Bash test environments emulate ln -s by copying.
  grep -q '\[\[ -d "$path" && ! -L "$path" \]\]' "$ROOT/lib/common.sh" \
    || fail_test 'managed directory helper lacks an explicit symlink guard'
fi

# Kernel state reads are transaction inputs and must not turn query failures
# into empty-but-successful snapshot values.
(
  sysctl() { return 1; }
  if sysctl_read net.ipv4.tcp_congestion_control >/dev/null 2>&1; then
    fail_test 'sysctl_read swallowed a kernel query failure'
  fi
)

# Snapshots are published by directory rename only after every file is durable.
# Retention must delete only complete, semantically valid Ss2022 snapshots and
# preserve unrelated or interrupted directories under backups/.
(
  backup_case="$test_tmp/backup-case"
  make_fixture "$backup_case"
  MANAGER_STATE="$backup_case/config/manager.json"
  NODES_FILE="$backup_case/data/nodes.json"
  TRAFFIC_FILE="$backup_case/data/traffic.json"
  HISTORY_FILE="$backup_case/data/traffic-history.json"
  CONFIG_DIR="$backup_case/config"
  DATA_DIR="$backup_case/data"
  RUNTIME_DIR="$backup_case/run"
  BACKUP_DIR="$backup_case/backups"
  SING_BOX_CONFIG="$backup_case/sing-box/config.json"
  SING_BOX_BINARY="$backup_case/missing-sing-box"
  snapshot=$(backup_create_snapshot manual) || fail_test 'atomic backup snapshot creation failed'
  backup_snapshot_is_managed "$snapshot" || fail_test 'new snapshot was not recognized as managed'
  restore_reason=$(backup_restore_reason "${snapshot##*/}") || fail_test 'safe restore reason generation failed'
  [[ "$restore_reason" =~ ^restore-[a-f0-9]{20}$ ]] || fail_test 'restore reason can grow with nested backup names'
  mkdir -p -- "$BACKUP_DIR/operator-notes" "$BACKUP_DIR/20260101-000000-interrupted"
  printf '%s\n' keep >"$BACKUP_DIR/operator-notes/sentinel"
  assert_equal "${snapshot##*/}" "$(backup_list)" 'backup list exposed foreign or partial directories'
  DEFAULT_CONFIG_BACKUP_RETENTION=0
  backup_prune || fail_test 'managed backup pruning failed'
  [[ ! -e "$snapshot" ]] || fail_test 'managed snapshot was not pruned at zero retention'
  [[ -f "$BACKUP_DIR/operator-notes/sentinel" ]] || fail_test 'backup pruning deleted an unrelated directory'
  [[ -d "$BACKUP_DIR/20260101-000000-interrupted" ]] || fail_test 'backup pruning deleted an incomplete snapshot'

  (
    find() { return 1; }
    if backup_managed_names >/dev/null 2>&1; then
      fail_test 'backup enumeration hid a find failure'
    fi
  )

  durable_sync_tree() { return 1; }
  if backup_create_snapshot forced-fsync-failure >/dev/null 2>&1; then
    fail_test 'snapshot was published after durability failure'
  fi
  if find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -name '.snapshot.prepare.*' -print -quit | grep -q .; then
    fail_test 'failed snapshot left a preparation directory'
  fi
)

valid_plan="$test_tmp/valid-plan.json"
jq -n '{schema_version:2,pref:49100,boot_id:"unknown",interfaces:["eth0"],families:["ip"],updated_at:"2026-01-01T00:00:00Z",actions:[
  {node_id:"0123456789abcdef0123456789abcdef",direction:"ingress",port:20001,kind:"gact",index:1000000001,cookie:"0123456789abcdef0123456789abcdef",limit_mbps:0},
  {node_id:"0123456789abcdef0123456789abcdef",direction:"egress",port:20001,kind:"gact",index:1000000002,cookie:"fedcba9876543210fedcba9876543210",limit_mbps:0}
]}' >"$valid_plan"
validate_bandwidth_plan_semantic "$valid_plan" || fail_test 'valid bandwidth plan rejected'
validate_bandwidth_plan_against_state "$valid_plan" "$NODES_FILE" "$INTERFACES_FILE" || fail_test 'state-linked bandwidth plan rejected'
jq '.families=["ipv6"]' "$valid_plan" >"$test_tmp/ipv6-only-plan.json"
validate_bandwidth_plan_semantic "$test_tmp/ipv6-only-plan.json" || fail_test 'IPv6-only bandwidth plan rejected'
jq '.actions[0].port=29999' "$valid_plan" >"$test_tmp/stale-plan.json"
if validate_bandwidth_plan_against_state "$test_tmp/stale-plan.json" "$NODES_FILE" "$INTERFACES_FILE"; then
  fail_test 'bandwidth plan with stale node port was accepted'
fi

jq '.nodes[0].port="not-a-port"' "$NODES_FILE" >"$test_tmp/bad-nodes.json"
if validate_nodes_file_semantic "$test_tmp/bad-nodes.json"; then fail_test 'semantic node corruption was accepted'; fi
jq '.nodes[].current_upload_bytes="NaN"' "$TRAFFIC_FILE" >"$test_tmp/bad-traffic.json"
if validate_traffic_file_semantic "$test_tmp/bad-traffic.json" "$NODES_FILE"; then fail_test 'semantic traffic corruption was accepted'; fi
printf '%s\n' '{"schema_version":1,"interfaces":"eth0"}' >"$test_tmp/bad-interfaces.json"
if validate_interfaces_file_semantic "$test_tmp/bad-interfaces.json"; then fail_test 'semantic interface corruption was accepted'; fi

# A failed JSON-line producer must propagate instead of looking like an empty
# node set through Bash process-substitution semantics.
if (
  jq() {
    local argument
    for argument in "$@"; do [[ "$argument" != '.nodes[]' ]] || return 1; done
    command jq "$@"
  }
  validate_nodes_file_semantic "$NODES_FILE"
); then
  fail_test 'node semantic validation ignored a failed node enumerator'
fi
if (
  jq() {
    local argument
    for argument in "$@"; do [[ "$argument" != '.nodes[] | select(.status == "enabled")' ]] || return 1; done
    command jq "$@"
  }
  bandwidth_build_actions "$NODES_FILE" "$test_tmp/producer-failure-actions.json"
); then
  fail_test 'bandwidth action builder treated failed node enumeration as empty'
fi

assert_equal 9007199254740991 "$(bytes_from_gb 9007199.254740991)" 'maximum exact GB conversion'
if bytes_from_gb 9007199.254740992 >/dev/null 2>&1; then fail_test 'unsafe quota was accepted'; fi
if bytes_from_gb 10000000000 >/dev/null 2>&1; then fail_test 'overflowing quota was accepted'; fi
assert_equal 20 "$(quota_billable_bytes 999999 20)" 'the default quota must exclude ingress bytes'

quota_nodes="$test_tmp/quota-nodes.json"
quota_traffic="$test_tmp/quota-traffic.json"
jq '.nodes[0].status="disabled_quota" | .nodes[0].status_reason="月流量已达到限额" | .nodes[0].quota_bytes=0' "$NODES_FILE" >"$quota_nodes"
jq '.nodes["0123456789abcdef0123456789abcdef"].quota_bytes=0' "$TRAFFIC_FILE" >"$quota_traffic"
traffic_sync_quota_status "$quota_nodes" "$quota_traffic" 0123456789abcdef0123456789abcdef 0 "$quota_nodes.next"
assert_equal enabled "$(jq -r '.nodes[0].status' "$quota_nodes.next")" 'removing a quota must re-enable a quota-disabled node'
mv -f -- "$quota_nodes.next" "$quota_nodes"
jq '.nodes[0].quota_bytes=10' "$quota_nodes" >"$quota_nodes.next" && mv -f -- "$quota_nodes.next" "$quota_nodes"
jq '.nodes["0123456789abcdef0123456789abcdef"].quota_bytes=10 | .nodes["0123456789abcdef0123456789abcdef"].current_download_bytes=20' "$quota_traffic" >"$quota_traffic.next" && mv -f -- "$quota_traffic.next" "$quota_traffic"
traffic_sync_quota_status "$quota_nodes" "$quota_traffic" 0123456789abcdef0123456789abcdef 10 "$quota_nodes.next"
assert_equal disabled_quota "$(jq -r '.nodes[0].status' "$quota_nodes.next")" 'lowering a quota below usage must disable the node immediately'

config_output="$test_tmp/generated.json"
generate_singbox_config "$NODES_FILE" "$config_output"
assert_equal 2 "$(jq '.inbounds | length' "$config_output")" 'domain node must bind both families when bindv6only=1'
assert_equal '["0.0.0.0","::"]' "$(jq -c '[.inbounds[].listen] | sort' "$config_output")" 'domain listener addresses'
if jq -e 'any(.inbounds[]; has("tcp_fast_open"))' "$config_output" >/dev/null; then
  fail_test 'TFO was emitted while kernel support was disabled'
fi
manager_state_set_json tfo_kernel_enabled true
generate_singbox_config "$NODES_FILE" "$config_output"
jq -e 'all(.inbounds[]; .tcp_fast_open == true)' "$config_output" >/dev/null || fail_test 'TFO missing when both capabilities are enabled'

# Credentials must reach JSON/URI consumers through stdin or protected files,
# never through an external command's observable argument vector.
assert_equal 'a%20b%2Bc%2F' "$(url_encode 'a b+c/')" 'stdin-based URL encoding changed output'
record_secret='BBBBBBBBBBBBBBBBBBBBBB=='
record_json=$(node_new_record 'Secret test' '2022-blake3-aes-128-gcm' 20002 '192.0.2.1' ipv4 \
  fedcba9876543210fedcba9876543210 "$record_secret")
assert_equal "$record_secret" "$(jq -r '.password' <<<"$record_json")" 'stdin-based node record lost its key'
expected_uri=$(node_sip002_uri "$(node_by_id 0123456789abcdef0123456789abcdef)")
(
  qrencode() {
    printf '%s\n' "$@" >"$test_tmp/qr-argv"
    cat >"$test_tmp/qr-stdin"
  }
  singbox_is_active() { return 0; }
  show_node_credentials 0123456789abcdef0123456789abcdef >/dev/null
)
assert_equal $'-t\nUTF8\n-m\n1' "$(cat "$test_tmp/qr-argv")" 'QR encoder received credential-bearing argv'
assert_equal "$expected_uri" "$(cat "$test_tmp/qr-stdin")" 'QR encoder did not receive the URI on stdin'

ss() { printf '%s\n' 'LISTEN 0 128 0.0.0.0:20001 0.0.0.0:* users:(("sing-box",pid=123,fd=7))'; }
port_listener_owned_by_pid tcp 20001 123 any || fail_test 'owned listener was rejected'
if port_listener_owned_by_pid tcp 20001 999 any; then fail_test 'foreign listener was accepted'; fi
ss() {
  printf '%s\n' \
    'LISTEN 0 128 0.0.0.0:20001 0.0.0.0:* users:(("sing-box",pid=123,fd=7))' \
    'LISTEN 0 128 0.0.0.0:20001 0.0.0.0:* users:(("foreign",pid=456,fd=8))'
}
if port_listener_owned_by_pid tcp 20001 123 any; then fail_test 'mixed listener ownership was accepted'; fi

system_port_in_use() { return 0; }
singbox_is_active() { return 0; }
singbox_owns_node_port() { return 1; }
if port_available 20001 0123456789abcdef0123456789abcdef; then fail_test 'unchanged port owned by another process was accepted'; fi
singbox_owns_node_port() { return 0; }
port_available 20001 0123456789abcdef0123456789abcdef || fail_test 'unchanged port owned by sing-box was rejected'

long_name=$(printf 'x%.0s' {1..64})
jq -n --arg name "$long_name" '{schema_version:1,nodes:[{node_id:"0123456789abcdef0123456789abcdef",name:$name,port:20001}]}' >"$test_tmp/names.json"
NODES_FILE="$test_tmp/names.json"
unique_name=$(unique_node_name "$long_name")
[[ ${#unique_name} -le 64 && "$unique_name" == *-2 ]] || fail_test 'duplicate 64-character name exceeded schema limit'
NODES_FILE="$fixture/data/nodes.json"

# Blank address input prefers IPv4 but must fall back to a usable public IPv6.
address_fallback=$(
  discover_public_ip() { [[ "$1" == ipv6 ]] && printf '%s' '2001:db8::10'; }
  choose_address <<<''
)
assert_equal $'2001:db8::10\tipv6' "$address_fallback" 'blank address did not fall back from IPv4 to IPv6'

# Port discovery must inspect listeners only and fail closed if ss itself
# cannot provide a trustworthy snapshot.
(
  # Restore the production implementation after the earlier listener-ownership
  # test replaced this helper with a controlled stub.
  # shellcheck disable=SC1091
  source "$ROOT/lib/nodes.sh"
  ss_log="$test_tmp/port-ss.log"
  ss() {
    printf '%s\n' "$*" >>"$ss_log"
    if [[ "$*" == *-ltn* ]]; then
      printf '%s\n' 'LISTEN 0 128 0.0.0.0:20001 0.0.0.0:*'
    fi
  }
  system_port_in_use 20001 || fail_test 'TCP listener was reported as free'
  grep -q -- '-ltn' "$ss_log" || fail_test 'TCP port probe included non-listening sockets'
  grep -q -- '-lun' "$ss_log" || fail_test 'UDP listener snapshot was not queried'
)
if (
  # shellcheck disable=SC1091
  source "$ROOT/lib/nodes.sh"
  ss() { return 1; }
  system_port_in_use 20001
); then
  fail_test 'failed ss query was reported as a free or occupied port'
else
  port_query_status=$?
  assert_equal 2 "$port_query_status" 'failed ss query did not return the fail-closed status'
fi

# A filter that invokes our action plus any additional action is ambiguous and
# must never be accepted as, or deleted as, an exact Ss2022 rule.
mixed_actions='[{"pref":49100,"protocol":"ip","options":{"keys":{"ip_proto":"tcp","dst_port":20001},"actions":[{"kind":"gact","index":1000000001},{"kind":"mirred","index":77}]}}]'
assert_equal 0 "$(tc_rule_json_match_count "$mixed_actions" 49100 ip tcp ingress 20001 gact 1000000001)" \
  'tc rule with an extra action was accepted as exact ownership'
action_with_bind='[{"kind":"gact","index":1000000001,"cookie":"0123456789abcdef0123456789abcdef","bind":2}]'
assert_equal 2 "$(tc_action_bind_count_from_json "$action_with_bind" gact 1000000001 0123456789abcdef0123456789abcdef)" \
  'tc action bind count could not be verified'
if tc_action_bind_count_from_json '[{"kind":"gact","index":1000000001,"cookie":"0123456789abcdef0123456789abcdef"}]' \
  gact 1000000001 0123456789abcdef0123456789abcdef >/dev/null 2>&1; then
  fail_test 'tc action without a bind count passed capability verification'
fi

# Service paths treat broken symlinks as occupied, and uninstall helpers stop
# before removing definitions when a managed service cannot be stopped.
grep -A5 '^service_definition_path_present()' "$ROOT/lib/service.sh" | grep -Fq -- '-L "$path"' \
  || fail_test 'service path presence check ignores broken symlinks'
grep -Fq 'service_definition_path_present "$name" && ! service_definition_is_managed' "$ROOT/install.sh" \
  || fail_test 'installer preflight can overlook a broken service-definition symlink'
grep -Fq "是否明确接管该 sing-box 服务并替换其服务定义" "$ROOT/install.sh" \
  || fail_test 'installer does not request explicit approval before replacing a foreign sing-box unit'
grep -Fq 'SS_MANAGER_SERVICE_TAKEOVER_APPROVED=0' "$ROOT/install.sh" \
  || fail_test 'installer trusts an inherited service-takeover approval'
grep -Fq '[[ "${SS_MANAGER_SERVICE_TAKEOVER_APPROVED:-0}" == 1 ]]' "$ROOT/lib/singbox.sh" \
  || fail_test 'sing-box unit replacement does not require the preflight takeover approval'
grep -Fq 'for name in "${service_names[@]}"; do' "$ROOT/install.sh" \
  || fail_test 'service takeover prompts still run with stdin redirected to the service-name producer'
(
  INIT_SYSTEM=systemd
  service_active=1
  service_enabled=1
  removed=0
  service_definition_path_present() { return 0; }
  service_definition_is_managed() { return 0; }
  service_is_active() { (( service_active == 1 )); }
  service_stop() { service_active=0; }
  service_is_enabled() { (( service_enabled == 1 )); }
  service_disable() { service_enabled=0; }
  service_remove_managed_definition() { removed=$((removed + 1)); }
  service_manager_reload() { return 0; }
  remove_manager_maintenance_service_files || fail_test 'verified maintenance-service removal failed'
  assert_equal 2 "$removed" 'not all maintenance service definitions were removed after stop verification'
)
if (
  INIT_SYSTEM=openrc
  service_definition_path_present() { return 0; }
  service_definition_is_managed() { return 0; }
  service_is_active() { return 0; }
  service_stop() { return 1; }
  service_is_enabled() { return 0; }
  service_disable() { return 0; }
  service_remove_managed_definition() { fail_test 'definition removed after service stop failure'; }
  service_manager_reload() { return 0; }
  remove_manager_maintenance_service_files
); then
  fail_test 'maintenance-service stop failure did not abort removal'
fi
if (
  INIT_SYSTEM=systemd
  service_definition_path_present() { return 0; }
  service_definition_is_managed() { return 0; }
  service_is_active() { return 2; }
  service_stop() { fail_test 'service stop ran after an ambiguous active-state query'; }
  service_is_enabled() { return 1; }
  service_remove_managed_definition() { fail_test 'definition removed after an ambiguous state query'; }
  remove_manager_maintenance_service_files
); then
  fail_test 'maintenance removal treated a failed active-state query as stopped'
fi
if (
  INIT_SYSTEM=systemd
  service_definition_path_present() { return 0; }
  service_definition_is_managed() { return 1; }
  service_stop() { fail_test 'foreign service was stopped'; }
  remove_manager_maintenance_service_files
); then
  fail_test 'maintenance removal accepted a foreign service definition'
fi

# A previous uninstall attempt may already have removed the verified managed
# binary before a later sysctl/filesystem step failed. Absence is resumable;
# any present replacement is still checked by the strict identity path.
(
  SING_BOX_CONFIG="$test_tmp/already-removed-config.json"
  SING_BOX_BINARY="$test_tmp/already-removed-sing-box"
  manager_state_get() { printf '%s' true; }
  uninstall_validate_managed_runtime
) || fail_test 'uninstall could not resume after its managed binary was already absent'
if (
  SING_BOX_CONFIG="$test_tmp/already-removed-config.json"
  SING_BOX_BINARY="$test_tmp/foreign-sing-box"
  : >"$SING_BOX_BINARY"
  manager_state_get() { printf '%s' true; }
  uninstall_validate_managed_runtime >/dev/null 2>&1
); then
  fail_test 'uninstall accepted a present binary whose type/identity was not verified'
fi

# Route changes during the same boot must be distinguishable from a failed
# route query, so maintenance can refresh the former and fail closed on the latter.
(
  ip() {
    if [[ "${1:-}" == -o && "${2:-}" == route ]]; then
      printf '%s\n' 'default via 192.0.2.254 dev eth0'
    elif [[ "${1:-}" == -o && "${2:-}" == -6 && "${3:-}" == route ]]; then
      return 0
    fi
  }
  assert_equal 'ip' "$(current_default_route_families)" 'IPv4-only default routes incorrectly enabled IPv6 tc rules'
)
(
  ip() {
    if [[ "${1:-}" == -o && "${2:-}" == route ]]; then
      return 0
    elif [[ "${1:-}" == -o && "${2:-}" == -6 && "${3:-}" == route ]]; then
      printf '%s\n' 'default via 2001:db8::1 dev eth0'
    fi
  }
  assert_equal 'ipv6' "$(current_default_route_families)" 'IPv6-only default route was not represented'
)
(
  ip() {
    if [[ "${2:-}" == route ]]; then
      printf '%s\n' 'default via 192.0.2.254 dev eth1'
    fi
    return 0
  }
  route_status=0
  traffic_interfaces_match_current_routes || route_status=$?
  assert_equal 1 "$route_status" 'same-boot route mismatch did not request a refresh'
)
if (
  ip() { return 1; }
  traffic_interfaces_match_current_routes
); then
  fail_test 'failed route query matched persisted interfaces'
else
  route_query_status=$?
  assert_equal 2 "$route_query_status" 'failed route query did not return the fail-closed status'
fi

printf '%s\n' '{"schema_version":1,"manager_version":"1.0.5","init_system":"systemd","install_completed":true,"sing_box_version":"","sing_box_binary_managed":false,"sing_box_version_lock":null,"created_at":"2026-01-01T00:00:00Z","listen_mode":"ipv4","listen_address":"0.0.0.0","tfo_kernel_supported":false,"tfo_kernel_enabled":false,"tfo_config_supported":false,"bbr_supported":false,"bbr_enabled":false,"tc_clsact_interfaces":["eth0"]}' >"$MANAGER_STATE"
tc_interface_exists() { return 0; }
tc_log="$test_tmp/tc.log"
tc() {
  if [[ "${1:-}" == -j && "${2:-}" == filter && "${3:-}" == show ]]; then return 1; fi
  printf '%s\n' "$*" >>"$tc_log"
}
bandwidth_remove_manager_clsact || fail_test 'clsact preservation should be a successful non-destructive outcome'
[[ ! -s "$tc_log" ]] || fail_test 'failed tc query caused clsact deletion'
assert_equal '["eth0"]' "$(jq -c '.tc_clsact_interfaces' "$MANAGER_STATE")" 'clsact ownership record must be retained after query failure'

(
  tc_interface_exists() { return 0; }
  tc() { return 1; }
  if tc_filter_scoped_json eth0 ingress ip 49100 >/dev/null 2>&1; then
    fail_test 'failed qdisc query was converted into an empty filter set'
  fi
)

# A matching cookie alone is insufficient: every filter binding must be gone
# before a shared action can be deleted.
if (
  tc_action_lookup() { jq -nc '{kind:"gact",index:1000000001,cookie:"0123456789abcdef0123456789abcdef",bind:1}'; }
  tc() { fail_test 'bound tc action reached the delete command'; }
  tc_delete_owned_action gact 1000000001 0123456789abcdef0123456789abcdef >/dev/null 2>&1
); then
  fail_test 'bound tc action was deleted despite a live filter reference'
fi

# IPv4-only kernels must probe and install IPv4 rules without issuing the
# unsupported IPv6 flower commands that caused the original first-node error.
(
  probe_log="$test_tmp/ipv4-probe.log"
  tc_active_families() { printf '%s\n' ip; }
  tc_action_counter_from_json() { return 0; }
  tc_action_bind_count_from_json() { printf '%s' 2; }
  tc_rule_json_match_count() { printf '%s' 1; }
  tc_rule_json_handles() { printf '%s\n' 0x1; }
  manager_state_set_json() { return 0; }
  success() { :; }
  ip() {
    if [[ "${1:-}" == link && "${2:-}" == show && "${3:-}" == dev ]]; then return 1; fi
    return 0
  }
  tc() {
    printf '%q ' "$@" >>"$probe_log"
    printf '\n' >>"$probe_log"
    if [[ "${1:-}" == -V ]]; then printf '%s\n' 'tc utility, iproute2-test'; return 0; fi
    if [[ "${1:-}" == -j && "${2:-}" == actions ]]; then printf '%s\n' '[]'; return 0; fi
    if [[ "${1:-}" == -s && "${2:-}" == -j && "${3:-}" == filter ]]; then printf '%s\n' '[{"options":{}},{"options":{}}]'; return 0; fi
    if [[ "${1:-}" == -s && "${2:-}" == -j && "${3:-}" == actions ]]; then printf '%s\n' '{}'; return 0; fi
    return 0
  }
  probe_tc_capabilities || fail_test 'IPv4-only tc capability probe failed'
  grep -q 'protocol ip ' "$probe_log" || fail_test 'IPv4 capability rules were not tested'
  if grep -q 'protocol ipv6 ' "$probe_log"; then fail_test 'IPv4-only probe attempted an IPv6 rule'; fi
)

repair_log=''
bandwidth_plan_matches_current_boot() { return 0; }
bandwidth_plan_matches_current_families() { return 0; }
bandwidth_check_nodes() { return 1; }
traffic_interfaces_match_current_routes() { return 0; }
traffic_collect_actions_no_rule_check() { repair_log+='collect '; }
bandwidth_apply_and_check() { repair_log+='apply '; }
traffic_reset_kernel_baselines() { repair_log+='reset '; }
traffic_ensure_tc_rules_no_lock
assert_equal 'collect apply reset ' "$repair_log" 'action counters must be collected before same-boot rule repair'

# A failed atomic write must propagate even when the function is used by an if statement.
(
  source "$ROOT/lib/traffic.sh"
  RUNTIME_DIR="$fixture/run"
  atomic_json_write() { return 1; }
  if traffic_reset_kernel_baselines "$fixture/data/nodes.json" "$fixture/data/traffic.json"; then
    fail_test 'baseline write failure was reported as success'
  fi
)

# Persisted state journal must recover a simulated power-loss state on next startup.
recovery="$test_tmp/recovery"
make_fixture "$recovery"
(
  MANAGER_STATE="$recovery/config/manager.json"
  NODES_FILE="$recovery/data/nodes.json"
  TRAFFIC_FILE="$recovery/data/traffic.json"
  HISTORY_FILE="$recovery/data/traffic-history.json"
  INTERFACES_FILE="$recovery/data/interfaces.json"
  CONFIG_DIR="$recovery/config"
  DATA_DIR="$recovery/data"
  RUNTIME_DIR="$recovery/run"
  BACKUP_DIR="$recovery/backups"
  STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
  SING_BOX_CONFIG="$recovery/sing-box/config.json"
  before=$(sha256sum "$NODES_FILE" | awk '{print $1}')
  singbox_is_active() { return 1; }
  singbox_confirm_inactive() { return 0; }
  singbox_stop() { :; }
  singbox_check_config() { :; }
  bandwidth_apply_and_check() { :; }
  traffic_reset_kernel_baselines() { :; }
  state_transaction_begin test-power-loss 0
  jq '.nodes[0].name="corrupted-after-switch"' "$NODES_FILE" >"$NODES_FILE.next"
  mv -f -- "$NODES_FILE.next" "$NODES_FILE"
  recover_incomplete_state_transaction
  after=$(sha256sum "$NODES_FILE" | awk '{print $1}')
  assert_equal "$before" "$after" 'persistent journal did not restore pre-transaction state'
  [[ ! -e "$STATE_TRANSACTION_DIR" ]] || fail_test 'recovered transaction journal was not cleared'
)

# A durable committed marker is the transaction commit point.  If cleanup was
# interrupted, startup must remove the journal without reverting valid state.
committed="$test_tmp/committed"
make_fixture "$committed"
(
  CONFIG_DIR="$committed/config"
  STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
  NODES_FILE="$committed/data/nodes.json"
  mkdir -p -- "$STATE_TRANSACTION_DIR"
  printf '%s\n' '{"schema_version":1,"phase":"committed"}' >"$STATE_TRANSACTION_DIR/journal.json"
  jq '.nodes[0].name="committed-state"' "$NODES_FILE" >"$NODES_FILE.next"
  mv -f -- "$NODES_FILE.next" "$NODES_FILE"
  state_transaction_restore() { fail_test 'committed state transaction was rolled back'; }
  recover_incomplete_state_transaction
  assert_equal committed-state "$(jq -r '.nodes[0].name' "$NODES_FILE")" 'committed state was changed during cleanup recovery'
  [[ ! -e "$STATE_TRANSACTION_DIR" ]] || fail_test 'committed state journal was not cleared'
)

(
  CONFIG_DIR="$committed/config"
  INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
  mkdir -p -- "$INSTALL_TRANSACTION_DIR"
  printf '%s\n' '{"schema_version":1,"phase":"committed"}' >"$INSTALL_TRANSACTION_DIR/journal.json"
  install_transaction_restore() { fail_test 'committed install transaction was rolled back'; }
  recover_incomplete_install_transaction
  [[ ! -e "$INSTALL_TRANSACTION_DIR" ]] || fail_test 'committed install journal was not cleared'
)

(
  INSTALL_TRANSACTION_DIR="$test_tmp/restore-target-transaction"
  mkdir -p -- "$INSTALL_TRANSACTION_DIR"
  printf '%s\n' restored >"$INSTALL_TRANSACTION_DIR/nodes.present"
  target="$test_tmp/restore-target.json"
  printf '%s\n' changed >"$target"
  install_transaction_restore_target nodes "$target"
  assert_equal restored "$(tr -d '\r\n' <"$target")" 'install snapshot target name expanded before local assignment'
)

# Before the durable commit marker is written, every current transaction
# target must be flushed. This ordering is what makes committed recovery safe.
(
  CONFIG_DIR="$test_tmp/commit-sync/config"
  RUNTIME_DIR="$test_tmp/commit-sync/run"
  INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
  mkdir -p -- "$INSTALL_TRANSACTION_DIR" "$RUNTIME_DIR"
  printf '%s\n' '{"schema_version":1,"phase":"installing"}' >"$INSTALL_TRANSACTION_DIR/journal.json"
  commit_log="$test_tmp/commit-sync.log"
  install_transaction_sync_current_targets() { printf '%s\n' sync >>"$commit_log"; }
  atomic_json_write() { printf '%s\n' write >>"$commit_log"; return 0; }
  install_transaction_set_phase committed
  assert_equal $'sync\nwrite' "$(cat "$commit_log")" 'commit marker write ran before target durability sync'
)

# A standalone reboot/interface refresh owns a persistent transaction and must
# restore it on any tc rebuild failure.
(
  INSTALL_TRANSACTION_DIR="$test_tmp/interface-refresh-transaction"
  INSTALL_TRANSACTION_RUNTIME_ACTIVE=0
  refresh_log="$test_tmp/interface-refresh.log"
  install_transaction_begin() { mkdir -p -- "$INSTALL_TRANSACTION_DIR"; INSTALL_TRANSACTION_RUNTIME_ACTIVE=1; printf '%s\n' begin >>"$refresh_log"; }
  install_transaction_set_phase() { printf 'phase:%s\n' "$1" >>"$refresh_log"; }
  detect_traffic_interfaces() { printf '%s\n' detect >>"$refresh_log"; }
  bandwidth_apply_and_check() { printf '%s\n' apply >>"$refresh_log"; return 1; }
  traffic_reset_kernel_baselines() { printf '%s\n' reset >>"$refresh_log"; }
  install_transaction_restore() { printf '%s\n' restore >>"$refresh_log"; }
  install_transaction_clear() { printf '%s\n' clear >>"$refresh_log"; rm -rf -- "$INSTALL_TRANSACTION_DIR"; INSTALL_TRANSACTION_RUNTIME_ACTIVE=0; }
  if traffic_refresh_interfaces_transactionally; then fail_test 'failed interface rebuild committed'; fi
  assert_equal $'begin\nphase:traffic_interfaces\ndetect\napply\nphase:rolling_back\nrestore\nclear' "$(cat "$refresh_log")" \
    'failed interface refresh did not execute its durable rollback sequence'
  [[ ! -e "$INSTALL_TRANSACTION_DIR" ]] || fail_test 'rolled-back interface transaction journal remains'
)

# Install rollback restores enabled and active state independently for every
# managed unit, rather than only remembering sing-box.
(
  restore_case="$test_tmp/install-service-restore"
  INSTALL_TRANSACTION_DIR="$restore_case/transaction"
  CONFIG_DIR="$restore_case/config"
  STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
  RUNTIME_DIR="$restore_case/run"
  MANAGER_STATE="$restore_case/no-manager.json"
  INIT_SYSTEM=systemd
  mkdir -p -- "$INSTALL_TRANSACTION_DIR" "$STATE_TRANSACTION_DIR" "$CONFIG_DIR" "$RUNTIME_DIR" "$restore_case/definitions"
  printf '%s\n' '{"schema_version":1,"phase":"installing","created_at":"2026-01-01T00:00:00Z","init_system":"systemd","service_was_active":true,"bbr_previous":"cubic","tfo_previous":"3","transient_paths":[]}' \
    >"$INSTALL_TRANSACTION_DIR/journal.json"
  : >"$INSTALL_TRANSACTION_DIR/service-0.absent"
  : >"$INSTALL_TRANSACTION_DIR/service-1.absent"
  : >"$INSTALL_TRANSACTION_DIR/service-0.enabled"
  : >"$INSTALL_TRANSACTION_DIR/service-0.active"
  restore_log="$restore_case/restore.log"
  service_one_active=1
  service_one_enabled=1
  assert_standard_destructive_paths() { :; }
  install_transaction_target_names() { :; }
  install_transaction_service_names() { printf '%s\n' one two; }
  service_definition_path() { printf '%s/definitions/%s' "$restore_case" "$1"; }
  service_is_active() { [[ "$1" == one && "$service_one_active" == 1 ]]; }
  service_is_enabled() { [[ "$1" == one && "$service_one_enabled" == 1 ]]; }
  service_stop() { printf 'stop %s\n' "$1" >>"$restore_log"; [[ "$1" != one ]] || service_one_active=0; }
  service_disable() { printf 'disable %s\n' "$1" >>"$restore_log"; [[ "$1" != one ]] || service_one_enabled=0; }
  service_enable() { printf 'enable %s\n' "$1" >>"$restore_log"; [[ "$1" != one ]] || service_one_enabled=1; }
  service_start() { printf 'start %s\n' "$1" >>"$restore_log"; [[ "$1" != one ]] || service_one_active=1; }
  service_manager_reload() { printf '%s\n' reload >>"$restore_log"; }
  sysctl() { :; }
  bandwidth_plan_path() { printf '%s/no-plan.json' "$restore_case"; }
  install_transaction_cleanup_transient_paths() { printf '%s\n' cleanup >>"$restore_log"; }
  install_transaction_restore
  grep -Fxq 'stop one' "$restore_log" || fail_test 'active service was not stopped before definition restore'
  grep -Fxq 'disable one' "$restore_log" || fail_test 'enabled service state was not reset before restore'
  grep -Fxq 'enable one' "$restore_log" || fail_test 'enabled service state was not restored'
  grep -Fxq 'start one' "$restore_log" || fail_test 'active service state was not restored'
  if grep -Fxq 'start two' "$restore_log"; then fail_test 'previously inactive service was started'; fi
  [[ ! -e "$STATE_TRANSACTION_DIR" ]] || fail_test 'outer install rollback left a nested state transaction behind'
)

# A failed isolated menu action cannot return to the menu while a durable
# journal is still pending.
(
  menu_case="$test_tmp/menu-recovery"
  INSTALL_TRANSACTION_DIR="$menu_case/install-transaction"
  STATE_TRANSACTION_DIR="$menu_case/state-transaction"
  PROGRAM_DIR="$menu_case/program"
  mkdir -p -- "$INSTALL_TRANSACTION_DIR" "$PROGRAM_DIR"
  printf '%s\n' "$MANAGER_VERSION" >"$PROGRAM_DIR/VERSION"
  recovery_log="$menu_case/recovery.log"
  acquire_manager_lock() { :; }
  recover_incomplete_install_transaction() { printf '%s\n' install >>"$recovery_log"; rm -rf -- "$INSTALL_TRANSACTION_DIR"; }
  recover_incomplete_state_transaction() { printf '%s\n' state >>"$recovery_log"; }
  run_menu_action false
  assert_equal $'install\nstate' "$(cat "$recovery_log")" 'parent menu did not recover a failed action journal'
  [[ ! -e "$INSTALL_TRANSACTION_DIR" ]] || fail_test 'menu returned with a pending install journal'
)

MANAGED_SYSCTL_FILE="$test_tmp/sysctl/99-ss-manager.conf"
RUNTIME_DIR="$test_tmp/runtime"
mkdir -p -- "$RUNTIME_DIR"
update_managed_sysctl_setting net.ipv4.tcp_congestion_control bbr
update_managed_sysctl_setting net.ipv4.tcp_fastopen 3
grep -Fxq 'net.ipv4.tcp_congestion_control=bbr' "$MANAGED_SYSCTL_FILE" || fail_test 'TFO update removed BBR setting'
grep -Fxq 'net.ipv4.tcp_fastopen=3' "$MANAGED_SYSCTL_FILE" || fail_test 'TFO setting missing'
printf '%s\n' 'vm.swappiness=10' >>"$MANAGED_SYSCTL_FILE"
(
  manager_state_get() { printf '%s' ''; }
  sysctl() { :; }
  restore_kernel_settings_on_uninstall
)
grep -Fxq 'vm.swappiness=10' "$MANAGED_SYSCTL_FILE" || fail_test 'uninstall removed an unrelated setting from the project sysctl file'
if grep -Eq '^(# Managed by Ss2022|net\.ipv4\.tcp_(congestion_control|fastopen)=)' "$MANAGED_SYSCTL_FILE"; then
  fail_test 'uninstall left Ss2022-owned sysctl entries behind'
fi

grep -q 'install_transaction_begin' "$ROOT/install.sh" || fail_test 'installer lacks persistent rollback transaction'
grep -q 'program_stage="${PROGRAM_DIR}.install-new.$$"' "$ROOT/install.sh" || fail_test 'installer does not stage program atomically'
grep -q 'service-\$index.active' "$ROOT/lib/backup.sh" \
  || fail_test 'install transaction does not preserve every managed service active state'
grep -q '^install_transaction_cleanup_transient_paths()' "$ROOT/lib/backup.sh" \
  || fail_test 'install transaction cannot clean interrupted program directory switches'
grep -q 'ensure_dir "$destination_dir" "$parent_mode"' "$ROOT/lib/common.sh" \
  || fail_test 'generic atomic file writes force system directories to private mode'
grep -Fq '[[ -f "$TRANSACTION_LOCK" && ! -L "$TRANSACTION_LOCK" && -O "$TRANSACTION_LOCK" ]]' "$ROOT/lib/common.sh" \
  || fail_test 'manager lock path can follow a symlink or foreign file'
if grep -E 'mapfile .*< <\(find' "$ROOT/lib/singbox.sh" "$ROOT/lib/update.sh"; then
  fail_test 'archive entry enumeration still hides find producer failures'
fi
if grep -E 'mapfile[[:space:]]+-d' "$ROOT/install.sh" "$ROOT/lib/"*.sh; then
  fail_test 'production code requires mapfile -d despite declaring Bash 4 compatibility'
fi
if grep -E '^[^#]*systemctl[^#]*--value' "$ROOT/lib/service.sh"; then
  fail_test 'service queries require systemctl --value, which systemd 219 does not provide'
fi
grep -Fq 'atomic_move_directory_to_absent_path "$program_stage" "$PROGRAM_DIR"' "$ROOT/install.sh" \
  || fail_test 'installer program directory publication can target an existing path'
grep -Fq 'atomic_move_directory_to_absent_path "$new_program" "$PROGRAM_DIR"' "$ROOT/lib/update.sh" \
  || fail_test 'manager update directory publication can target an existing path'
plan_write_line=$(grep -n 'atomic_json_write "$plan_candidate" "$live_plan_path"' "$ROOT/lib/bandwidth.sh" | cut -d: -f1)
action_create_line=$(grep -n 'if ! tc_create_shared_action' "$ROOT/lib/bandwidth.sh" | cut -d: -f1)
[[ -n "$plan_write_line" && -n "$action_create_line" && "$plan_write_line" -lt "$action_create_line" ]] \
  || fail_test 'tc ownership plan is not durable before kernel mutation'
grep -q -- '--self-test' "$ROOT/lib/update.sh" || fail_test 'manager update self-test still contends on the manager lock'
grep -q 'manager_update_transaction_begin' "$ROOT/lib/update.sh" || fail_test 'manager update lacks a persistent rollback transaction'
grep -q 'ss-manager.update-old' "$ROOT/lib/common.sh" || fail_test 'rem wrapper lacks interrupted directory-switch recovery'
grep -Fq '# Managed by Ss2022' "$ROOT/lib/common.sh" || fail_test 'rem wrapper lacks an explicit ownership marker'
grep -Fq 'grep -Fqx "  exec $PROGRAM_DIR/ss-manager.sh \"\$@\""' "$ROOT/lib/common.sh" \
  || fail_test 'rem ownership detection does not verify the recovery wrapper entry'
grep -q 'SS_MANAGER_COMMIT' "$ROOT/bootstrap.sh" || fail_test 'bootstrap does not require an immutable commit'
grep -q 'SS_MANAGER_ARCHIVE_SHA256' "$ROOT/bootstrap.sh" || fail_test 'bootstrap does not require an archive digest'
if grep -q 'archive/refs/heads' "$ROOT/bootstrap.sh"; then fail_test 'bootstrap still executes mutable branch archives'; fi
if grep -q '^Persistent=true$' "$ROOT/systemd/ss-manager-traffic.timer"; then fail_test 'monotonic timer still claims calendar persistence'; fi
grep -q '^UMask=0077$' "$ROOT/systemd/sing-box.service" || fail_test 'sing-box service does not protect newly created files'
if grep -R -E -- '--arg password "\$password"|--argjson record "\$record"|qrencode[^|]*"\$uri"|--arg value "\$1"' "$ROOT/lib"; then
  fail_test 'a credential-bearing value is still passed in an external process argument'
fi

printf 'deep audit regression tests passed\n'
