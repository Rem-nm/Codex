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

assert_equal() {
  local expected=$1 actual=$2 message=$3
  [[ "$expected" == "$actual" ]] || {
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  }
}

INIT_SYSTEM=systemd
assert_equal '/etc/systemd/system/sing-box.service' "$(service_definition_path sing-box)" 'systemd service path'
assert_equal 'ss-manager-traffic.timer' "$(service_systemd_unit_name ss-manager-traffic.timer)" 'systemd timer suffix must be preserved'
captured_service_call=''
systemctl() { captured_service_call=$(printf '%s ' "$@"); }
# Later test stubs intentionally replace the sourced service_start function.
# shellcheck disable=SC2218
service_start sing-box
assert_equal 'start sing-box.service ' "$captured_service_call" 'systemd start command'
service_enable ss-manager-traffic.timer
assert_equal 'enable ss-manager-traffic.timer ' "$captured_service_call" 'systemd timer enable command'

# systemd queries are tri-state: a confirmed absence/inactive state is 1,
# while an empty response caused by a broken manager/DBus connection is 2.
systemctl() {
  [[ "${1:-}" == show && "${2:-}" == --property=LoadState && "${3:-}" == sing-box.service && $# == 3 ]] || return 64
  printf 'LoadState=loaded\n'
}
service_exists sing-box || {
  printf 'assertion failed: loaded systemd service was not detected\n' >&2
  exit 1
}
systemctl() { [[ "$1" == show ]] && printf 'LoadState=not-found\n'; return 1; }
service_presence_status=0
service_exists sing-box || service_presence_status=$?
assert_equal 1 "$service_presence_status" 'systemd not-found must prove absence'
systemctl() {
  case "$1" in
    is-active) printf 'unknown\n'; return 3 ;;
    show) printf 'LoadState=loaded\n' ;;
  esac
}
service_active_status=0
service_is_active sing-box || service_active_status=$?
assert_equal 2 "$service_active_status" 'unknown active state for a loaded unit must stay unknown'
systemctl() { return 1; }
service_presence_status=0
service_exists sing-box || service_presence_status=$?
assert_equal 2 "$service_presence_status" 'empty failed systemd presence query must stay unknown'
service_enabled_status=0
service_is_enabled sing-box || service_enabled_status=$?
assert_equal 2 "$service_enabled_status" 'empty failed systemd enablement query must stay unknown'

systemctl() {
  case "$1" in
    is-enabled) return 1 ;;
    show) printf 'LoadState=not-found\n'; return 1 ;;
  esac
}
service_enabled_status=0
service_is_enabled sing-box || service_enabled_status=$?
assert_equal 1 "$service_enabled_status" 'empty is-enabled output for an absent unit must prove disabled'
service_active_status=0
service_is_active sing-box || service_active_status=$?
assert_equal 2 "$service_active_status" 'empty failed systemd active query must stay unknown'

INIT_SYSTEM=openrc
assert_equal '/etc/init.d/sing-box' "$(service_definition_path sing-box.service)" 'OpenRC must strip the systemd suffix'
assert_equal 'ss-manager-traffic' "$(service_openrc_name ss-manager-traffic.timer)" 'OpenRC maintenance service name'
rc-service() { captured_service_call=$(printf '%s ' "$@"); }
rc-update() { captured_service_call=$(printf '%s ' "$@"); }
# shellcheck disable=SC2218
service_start sing-box.service
assert_equal 'sing-box start ' "$captured_service_call" 'OpenRC start command'
service_enable ss-manager-traffic
assert_equal 'add ss-manager-traffic default ' "$captured_service_call" 'OpenRC runlevel command'

service_is_active() { return 1; }
service_start() { captured_service_call="start:$1"; }
service_restart() { captured_service_call="restart:$1"; }
singbox_restart
assert_equal 'start:sing-box' "$captured_service_call" 'restart must start an initially stopped OpenRC service'
service_is_active() { return 0; }
singbox_restart
assert_equal 'restart:sing-box' "$captured_service_call" 'restart must restart an active OpenRC service'

PACKAGE_MANAGER=apk
apk_packages=$(package_list)
grep -qx bash <<<"$apk_packages"
grep -qx iproute2 <<<"$apk_packages"
grep -qx openrc <<<"$apk_packages"
grep -q 'apk add --no-cache procps-ng' "$ROOT/lib/system.sh"
grep -q 'apk add --no-cache procps' "$ROOT/lib/system.sh"

(
  HOST_OS_ID=debian
  HOST_OS_VERSION=11
  apt_debian11_sources_stale() { return 0; }
  apt-get() { :; }
  apt_update_or_die
  [[ -s "$APT_SOURCE_OVERRIDE" ]] || {
    printf 'assertion failed: Debian 11 fallback source list was not created\n' >&2
    exit 1
  }
  grep -Fqx 'deb http://security.debian.org/debian-security bullseye-security main' "$APT_SOURCE_OVERRIDE" || {
    printf 'assertion failed: Debian 11 fallback did not use bullseye-security\n' >&2
    exit 1
  }
  apt_source_override_cleanup
  [[ -z "$APT_SOURCE_OVERRIDE" ]] || {
    printf 'assertion failed: Debian 11 fallback source list was not cleaned\n' >&2
    exit 1
  }
)

grep -q 'alpine)' "$ROOT/lib/system.sh"
grep -q 'INIT_SYSTEM=openrc' "$ROOT/lib/system.sh"
grep -q '^# Managed by Ss2022$' "$ROOT/openrc/sing-box"
grep -q 'supervisor="supervise-daemon"' "$ROOT/openrc/sing-box"
grep -q 'rc_ulimit="-n 1048576"' "$ROOT/openrc/sing-box"
grep -q '^# Managed by Ss2022$' "$ROOT/openrc/ss-manager-traffic"

if grep -R -n -E -- '-- "\$[A-Za-z_][A-Za-z0-9_]*" -o ' "$ROOT/lib" "$ROOT/bootstrap.sh"; then
  printf 'assertion failed: curl output option appears after end-of-options marker\n' >&2
  exit 1
fi
grep -q -- '--output "$archive_file" -- "$archive_url"' "$ROOT/lib/singbox.sh"
grep -q -- '--output "$archive" -- "$asset_url"' "$ROOT/lib/update.sh"
grep -q -- '--output "$archive" -- "$archive_url"' "$ROOT/bootstrap.sh"
grep -q '^trap cleanup 0$' "$ROOT/bootstrap.sh"
grep -q 'set +e' "$ROOT/bootstrap.sh"
grep -q '安装脚本退出（退出码' "$ROOT/bootstrap.sh"
grep -q -- '--no-upgrade' "$ROOT/lib/system.sh"

legacy_tc_action_output=$(cat <<'EOF'
[{"total acts":0},{"actions":[{"order":1 police 0x7140cc07 rate 1Mbit burst 64Kb mtu 64Kb ,"control_action":{"type":"drop"} overhead 0b
 ref 1 bind 0
,"stats":{"bytes":17,"packets":2,"drops":1,"overlimits":3,"requeues":0,"backlog":0,"qlen":0},"cookie":"3f6e692761769638d3a502f616972ab0"}]}]
EOF
)
legacy_tc_action=$(tc_action_legacy_json "$legacy_tc_action_output" police 1900071943)
jq -e '.kind == "police" and .index == 1900071943 and .bind == 0 and .stats.bytes == 17' <<<"$legacy_tc_action" >/dev/null
[[ "$(tc_action_counter_from_json "$legacy_tc_action_output" police 1900071943 3f6e692761769638d3a502f616972ab0)" == 17 ]]
[[ "$(tc_action_bind_count_from_json "$legacy_tc_action_output" police 1900071943 3f6e692761769638d3a502f616972ab0)" == 0 ]]

legacy_tc_filter_output=$(cat <<'EOF'
[{"protocol":"ip","pref":65000,"kind":"flower","chain":0},{"protocol":"ip","pref":65000,"kind":"flower","chain":0,"options":{"handle":1,"keys":{"eth_type":"ipv4","ip_proto":"tcp","dst_port":9},"actions":[{"order":1 police 0x7140e4b3 rate 1Mbit burst 64Kb mtu 64Kb ,"control_action":{"type":"drop"} overhead 0b
 ref 3 bind 2,"installed":0,"last_used":0
,"stats":{"bytes":17,"packets":2,"drops":1,"overlimits":3,"requeues":0,"backlog":0,"qlen":0},"cookie":"8578a2a2f5b7633e44fe29abadd5767e"}]}}]
EOF
)
legacy_tc_filter=$(tc_filter_normalize_json "$legacy_tc_filter_output")
jq -e 'length == 2 and .[1].options.actions[0].kind == "police" and .[1].options.actions[0].index == 1900078259 and .[1].options.actions[0].bind == 2' <<<"$legacy_tc_filter" >/dev/null

grep -q 'cp -a -- "$path" "$preparing/$name.present"' "$ROOT/lib/backup.sh"
grep -q 'cp -a -- "$present" "$path"' "$ROOT/lib/backup.sh"

printf 'platform support tests passed\n'
