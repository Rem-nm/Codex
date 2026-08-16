#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for command_name in jq python3 date; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command_name" >&2
    exit 77
  }
done

source "$ROOT/lib/common.sh"
source "$ROOT/lib/system.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/lib/time_sync.sh"
source "$ROOT/lib/singbox.sh"

fail_test() { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT
CONFIG_DIR="$test_tmp/config"
DATA_DIR="$test_tmp/data"
RUNTIME_DIR="$test_tmp/run"
BACKUP_DIR="$CONFIG_DIR/backups"
CERTS_DIR="$CONFIG_DIR/certs"
MANAGER_STATE="$CONFIG_DIR/manager.json"
NODES_FILE="$DATA_DIR/nodes.json"
SING_BOX_CONFIG="$test_tmp/sing-box-config.json"
SING_BOX_BINARY=/bin/true
INIT_SYSTEM=systemd
HOST_OS_ID=debian
PACKAGE_MANAGER=apt-get
mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$CERTS_DIR"
chmod 700 -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$CERTS_DIR"

now='2026-01-01T00:00:00Z'
jq -n --arg now "$now" '{schema_version:1,manager_version:"1.3.0-dev.1",init_system:"systemd",install_completed:true,
  sing_box_version:"1.13.18",sing_box_binary_managed:true,sing_box_binary_sha256:"",sing_box_version_lock:null,
  created_at:$now,listen_mode:"ipv4",listen_address:"0.0.0.0",tfo_kernel_supported:false,tfo_kernel_enabled:false,
  tfo_config_supported:false,bbr_supported:false,bbr_enabled:false,tc_capabilities_verified:true,
  tc_capability_signature:"test",quota_include_unauthenticated_upload:false}' >"$MANAGER_STATE"
jq -n --arg now "$now" '{schema_version:5,nodes:[{
  node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo",protocol:"shadowsocks",
  method:"2022-blake3-aes-256-gcm",password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,
  address:"203.0.113.1",address_type:"ipv4",status:"enabled",status_reason:"",subscription_enabled:true,
  quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:$now,updated_at:$now,
  last_reset_at:$now,next_reset_at:"2026-02-01T00:00:00Z"}]}' >"$NODES_FILE"

time_sync_migrate_manager_state || fail_test 'old manager state migration failed'
[[ "$(jq -r '.time_sync.singbox_ntp_enabled' "$MANAGER_STATE")" == true ]] || fail_test 'migration did not enable sing-box NTP'
[[ "$(jq -r '.time_sync.ntp_server' "$MANAGER_STATE")" == 'time.apple.com' ]] || fail_test 'migration default server mismatch'
validate_manager_state_semantic "$MANAGER_STATE" || fail_test 'migrated manager state rejected'

if time_sync_validate_server 'https://example.com'; then fail_test 'URL accepted as NTP server'; fi
if time_sync_validate_server 'bad/server'; then fail_test 'path accepted as NTP server'; fi
if time_sync_validate_settings_json "$(jq -c '.time_sync.ntp_port=0' "$MANAGER_STATE")"; then fail_test 'invalid NTP port accepted'; fi
invalid_interval_json=$(jq -c '.time_sync.ntp_interval = "1h"' "$MANAGER_STATE")
if time_sync_validate_settings_json "$invalid_interval_json"; then fail_test 'invalid NTP interval accepted'; fi

service_exists() { [[ "$1" == chrony || "$1" == systemd-timesyncd ]]; }
service_is_active() {
  if [[ "${TIME_SYNC_TEST_TIMESYNCD:-0}" == 1 ]]; then
    [[ "$1" == systemd-timesyncd ]]
    return
  fi
  [[ "$1" == chrony && "${TIME_SYNC_TEST_BOTH_ACTIVE:-0}" != 1 ]] \
    || [[ "${TIME_SYNC_TEST_BOTH_ACTIVE:-0}" == 1 && ( "$1" == chrony || "$1" == systemd-timesyncd ) ]]
}
chronyc() {
  [[ "${TIME_SYNC_TEST_TIMESYNCD:-0}" != 1 ]] || return 1
  if [[ "${1:-}" == tracking || "${2:-}" == tracking ]]; then
    printf '%s\n' 'Leap status     : Normal'
    return 0
  fi
  return 0
}
timedatectl() {
  [[ "${1:-}" == show ]] || return 0
  if [[ "${3:-}" == NTPSynchronized ]]; then
    [[ "${TIME_SYNC_TEST_TIMESYNCD:-0}" == 1 ]] && printf 'yes\n' || printf 'no\n'
  else
    printf 'Asia/Tokyo\n'
  fi
}

TIME_SYNC_TEST_BOTH_ACTIVE=0
time_sync_detect_provider || fail_test 'provider detection failed'
[[ "$TIME_SYNC_PROVIDER" == chrony && "$TIME_SYNC_STATUS" == synchronized ]] || fail_test 'chrony provider was not selected'
TIME_SYNC_TEST_TIMESYNCD=1
time_sync_detect_provider || fail_test 'timesyncd provider detection failed'
[[ "$TIME_SYNC_PROVIDER" == systemd-timesyncd && "$TIME_SYNC_STATUS" == synchronized ]] || fail_test 'timesyncd provider was not selected'
TIME_SYNC_TEST_TIMESYNCD=0
TIME_SYNC_TEST_BOTH_ACTIVE=1
time_sync_detect_provider || fail_test 'provider conflict detection failed'
[[ "$TIME_SYNC_CONFLICT" == 1 && "$TIME_SYNC_PROVIDER" == unknown ]] || fail_test 'multiple active providers were not rejected'
time_sync_prepare_provider || fail_test 'provider conflict must not abort installation'
TIME_SYNC_TEST_BOTH_ACTIVE=0

# A host/container that lacks CAP_SYS_TIME must not make installation abort;
# provider start failure is warning-only while sing-box NTP remains enabled.
service_enable() { return 1; }
service_start() { return 1; }
time_sync_prepare_provider || fail_test 'provider start failure must remain non-fatal with NTP fallback'

# SS2022 creation also continues when the host status query is unavailable and
# the generated manager state keeps sing-box NTP enabled.
time_sync_collect_status() { return 1; }
time_sync_ss_creation_check || fail_test 'unknown system time status must allow SS2022 creation with fallback'

candidate="$test_tmp/ntp-config.json"
generate_singbox_config "$NODES_FILE" "$candidate" || fail_test 'NTP config generation failed'
jq -e '.ntp.enabled == true and .ntp.server == "time.apple.com" and .ntp.server_port == 123 and .ntp.interval == "30m"' "$candidate" >/dev/null \
  || fail_test 'generated NTP module does not match defaults'

printf 'time sync model test passed\n'
