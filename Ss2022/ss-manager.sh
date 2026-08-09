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

require_root
detect_host
ensure_runtime_dirs
validate_installed_state_files
initialize_state_files

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
    if (( $(node_count) == 0 )); then
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
