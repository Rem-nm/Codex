#!/usr/bin/env bash
# Installed entry point for rem and scheduled maintenance operations.

set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
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
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/nodes.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/links.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/update.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/menu.sh"

if [[ "${1:-}" == --self-test ]]; then
  printf 'Ss2022 manager %s\n' "$MANAGER_VERSION"
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
ensure_tc_capabilities
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
    singbox_health_check "$NODES_FILE"
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
