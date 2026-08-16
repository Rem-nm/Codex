#!/usr/bin/env bash
# Installed entry point for rem and scheduled maintenance operations.

set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/certs.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/system.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/service.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/singbox.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/traffic.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/bandwidth.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/port_hopping.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/nodes.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/links.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/export.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/subscription.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/update.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/menu.sh"

manager_update_preflight() {
  # This child is invoked by the still-running old manager while its persistent
  # update transaction is active.  It must be read-only apart from protected
  # /run candidates: do not initialize/migrate state or acquire the inherited
  # manager lock here.
  require_root
  detect_host
  assert_standard_destructive_paths
  validate_installed_state_files
  # The pre-1.0.4 traffic layout requires the wider install transaction so its
  # former file can be restored byte-for-byte.  A manager-only update is not
  # allowed to strand that migration outside its intended recovery boundary.
  [[ "${LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION:-0}" == 0 ]] || return 1
  local binary_managed candidate_nodes candidate_config
  binary_managed=$(manager_state_get sing_box_binary_managed false) || return 1
  [[ "$binary_managed" == true ]] || return 1
  validate_managed_singbox_binary_identity || return 1
  # Preflight candidates belong only in the volatile runtime directory.  Do
  # not call ensure_runtime_dirs here: that helper also creates/chmods
  # permanent config, data, backup and sing-box paths, which would violate the
  # read-only contract of a not-yet-committed manager update.
  ensure_dir "$RUNTIME_DIR" 700 || return 1
  candidate_nodes=$(runtime_temp_file nodes.update-preflight) || return 1
  candidate_config=$(runtime_temp_file config.update-preflight) || {
    rm -f -- "$candidate_nodes"
    return 1
  }
  if ! nodes_schema_upgrade_copy "$NODES_FILE" "$candidate_nodes" \
    || ! generate_singbox_config "$candidate_nodes" "$candidate_config" \
    || ! singbox_check_config "$candidate_config" >/dev/null 2>&1; then
    rm -f -- "$candidate_nodes" "$candidate_config"
    return 1
  fi
  local vless_status=0 tuic_status=0
  nodes_file_has_vless "$candidate_nodes" || vless_status=$?
  if (( vless_status > 1 )); then
    rm -f -- "$candidate_nodes" "$candidate_config"
    return 1
  fi
  if (( vless_status == 0 )) && ! vless_generation_capabilities_available; then
    rm -f -- "$candidate_nodes" "$candidate_config"
    return 1
  fi
  nodes_file_has_tuic "$candidate_nodes" || tuic_status=$?
  if (( tuic_status > 1 )); then
    rm -f -- "$candidate_nodes" "$candidate_config"
    return 1
  fi
  if (( tuic_status == 0 )) && ! tuic_generation_capabilities_available; then
    rm -f -- "$candidate_nodes" "$candidate_config"
    return 1
  fi
  rm -f -- "$candidate_nodes" "$candidate_config" || return 1
  printf 'Ss2022 update preflight %s\n' "$MANAGER_VERSION"
}

if [[ "${1:-}" == --self-test ]]; then
  # Managers before the VLESS-capable release only invoke --self-test after
  # switching the new program into /opt.  Detect that exact persistent update
  # phase so an upgrade from those versions still receives the new read-only
  # state/configuration preflight before the old updater can commit and delete
  # its rollback copy.  Ordinary package/install self-tests remain lightweight.
  if [[ "$SCRIPT_DIR" == "$PROGRAM_DIR" \
    && -f "$INSTALL_TRANSACTION_DIR/journal.json" \
    && ! -L "$INSTALL_TRANSACTION_DIR/journal.json" ]] \
    && jq -e '.phase == "manager_update"' "$INSTALL_TRANSACTION_DIR/journal.json" >/dev/null 2>&1; then
    manager_update_preflight >/dev/null || exit 1
  fi
  printf 'Ss2022 manager %s\n' "$MANAGER_VERSION"
  exit 0
fi

if [[ "${1:-}" == --update-preflight ]]; then
  manager_update_preflight
  exit 0
fi

require_root
detect_host
assert_standard_destructive_paths
ensure_runtime_dirs
acquire_manager_lock
recover_incomplete_install_transaction
recover_incomplete_state_transaction
validate_installed_state_files
ensure_managed_singbox_binary_identity || die 'sing-box 二进制所有权校验失败；请重新运行固定版本 install.sh 修复。'
initialize_state_files
subscription_initialize || die '订阅设置初始化失败；请先使用备份恢复。'
subscription_publish_export "$NODES_FILE" || warn '订阅派生输出暂未更新；订阅服务将保持明确的不可用状态。'
ensure_tc_capabilities
port_hopping_check "$NODES_FILE" || warn 'Hysteria2 端口跳跃规则缺失或不一致；可稍后执行 rem --port-hop-restore 修复。'
startup_install_completed=$(manager_state_get install_completed false) || die '无法读取安装完成状态。'
startup_node_count=$(jq -er '.nodes | length' "$NODES_FILE") || die '无法读取节点数量。'
if [[ "$startup_install_completed" != true ]] && (( startup_node_count > 0 )); then
  enable_manager_maintenance_service
  manager_state_set_json install_completed true
  success '已补齐首节点提交后中断的流量维护服务启用步骤。'
fi
release_manager_lock

case "${1:-menu}" in
  --maintenance)
    traffic_maintenance_flow
    ;;
  --collect)
    traffic_collect_flow
    ;;
  --health)
    singbox_health_check "$NODES_FILE" && port_hopping_check "$NODES_FILE"
    ;;
  --port-hop-restore)
    port_hopping_restore "$NODES_FILE"
    ;;
  --version)
    printf 'Ss2022 manager %s\n' "$MANAGER_VERSION"
    printf 'sing-box %s\n' "$(singbox_binary_version 2>/dev/null || printf '未安装')"
    ;;
  --first-run)
    first_run_node_count=$(node_count) || die '无法读取首节点状态。'
    if (( first_run_node_count == 0 )); then
      run_menu_action node_add_flow
      (( ${MENU_ACTION_STATUS:-1} == 0 )) || die '首个节点创建未完成。'
    fi
    enable_manager_maintenance_service
    manager_state_set_json install_completed true
    main_menu
    ;;
  menu)
    main_menu
    ;;
  *)
    die "未知参数：$1"
    ;;
esac
