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
service_start sing-box
assert_equal 'start sing-box.service ' "$captured_service_call" 'systemd start command'
service_enable ss-manager-traffic.timer
assert_equal 'enable ss-manager-traffic.timer ' "$captured_service_call" 'systemd timer enable command'

INIT_SYSTEM=openrc
assert_equal '/etc/init.d/sing-box' "$(service_definition_path sing-box.service)" 'OpenRC must strip the systemd suffix'
assert_equal 'ss-manager-traffic' "$(service_openrc_name ss-manager-traffic.timer)" 'OpenRC maintenance service name'
rc-service() { captured_service_call=$(printf '%s ' "$@"); }
rc-update() { captured_service_call=$(printf '%s ' "$@"); }
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

assert_equal 2 "$(grep -c 'install -m "$install_service_mode"' "$ROOT/install.sh")" 'OpenRC service backup and restore must preserve executable mode'

printf 'platform support tests passed\n'
