#!/usr/bin/env bash
# First install / idempotent repair entry point.

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

require_root
detect_host
assert_standard_destructive_paths

existing_rem=$(command -v rem 2>/dev/null || true)
if [[ -n "$existing_rem" ]] && ! is_command_from_manager "$existing_rem"; then
  warn "检测到已有 rem 命令：$existing_rem。"
  prompt_yes_no '是否由 Ss2022 替换这个 rem 命令？' n || die '未替换已有 rem，安装已安全停止。'
fi

fresh_install=1
if [[ -f "$MANAGER_STATE" || -f "$NODES_FILE" || -x "$PROGRAM_DIR/ss-manager.sh" ]]; then
  fresh_install=0
  info '检测到已有安装数据，将执行幂等的修复/补齐流程，不会覆盖节点、密码或流量数据。'
fi

if (( fresh_install == 1 )) && [[ -f "$SING_BOX_CONFIG" ]]; then
  warn "检测到已有 sing-box 配置：$SING_BOX_CONFIG；它不属于已识别的 Ss2022 安装。"
  prompt_yes_no '是否明确由 Ss2022 接管，并以节点数据库生成的配置替换它？失败时会自动恢复' n \
    || die '未接管已有 sing-box 配置，安装已安全停止。'
fi

install_packages
ensure_runtime_dirs
ensure_dir "$PROGRAM_DIR" 700
ensure_dir "$CONFIG_DIR" 700
ensure_dir "$DATA_DIR" 700
ensure_dir "$BACKUP_DIR" 700

if [[ ! -f "$MANAGER_STATE" ]]; then
  jq -n \
    --arg manager_version "$MANAGER_VERSION" \
    --arg init_system "$INIT_SYSTEM" \
    --arg created_at "$(timestamp_iso)" \
    '{schema_version:1,manager_version:$manager_version,init_system:$init_system,install_completed:false,sing_box_version:"",sing_box_binary_managed:false,sing_box_version_lock:null,created_at:$created_at,listen_mode:"ipv4",listen_address:"0.0.0.0",tfo_kernel_supported:false,tfo_kernel_enabled:false,tfo_config_supported:false,bbr_supported:false,bbr_enabled:false}' \
    | atomic_json_from_stdin "$MANAGER_STATE" 600
else
  jq -e . "$MANAGER_STATE" >/dev/null || die 'manager.json 无效，安装不会覆盖；请先使用备份恢复。'
fi

initialize_state_files

install_previous_config=''
if [[ -f "$SING_BOX_CONFIG" ]]; then
  install_previous_config="$RUNTIME_DIR/config.install-previous.$$.json"
  install -m 600 -- "$SING_BOX_CONFIG" "$install_previous_config"
fi

copy_program() {
  install -d -m 700 -- "$PROGRAM_DIR/lib" "$PROGRAM_DIR/config" "$PROGRAM_DIR/systemd" "$PROGRAM_DIR/openrc"
  install -m 755 -- "$SCRIPT_DIR/ss-manager.sh" "$PROGRAM_DIR/ss-manager.sh"
  install -m 644 -- "$SCRIPT_DIR/VERSION" "$PROGRAM_DIR/VERSION"
  local file
  while IFS= read -r file; do install -m 700 -- "$file" "$PROGRAM_DIR/lib/$(basename "$file")"; done < <(find "$SCRIPT_DIR/lib" -maxdepth 1 -type f -name '*.sh' -print | sort)
  install -m 600 -- "$SCRIPT_DIR/config/defaults.conf" "$PROGRAM_DIR/config/defaults.conf"
  while IFS= read -r file; do install -m 644 -- "$file" "$PROGRAM_DIR/systemd/$(basename "$file")"; done < <(find "$SCRIPT_DIR/systemd" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -print | sort)
  while IFS= read -r file; do install -m 700 -- "$file" "$PROGRAM_DIR/openrc/$(basename "$file")"; done < <(find "$SCRIPT_DIR/openrc" -maxdepth 1 -type f -print | sort)
}
copy_program
manager_state_set_json manager_version "$(jq -Rn --arg value "$MANAGER_VERSION" '$value')"
manager_state_set_json init_system "$(jq -Rn --arg value "$INIT_SYSTEM" '$value')"

singbox_install_target=latest
singbox_locked_version=$(manager_state_get sing_box_version_lock '')
if [[ -n "$singbox_locked_version" && "$singbox_locked_version" != null ]]; then
  singbox_install_target="$singbox_locked_version"
  info "检测到 sing-box 版本锁定，将安装锁定版本 $singbox_install_target。"
fi

if [[ ! -x "$SING_BOX_BINARY" ]]; then
  install_singbox_from_release "$singbox_install_target"
elif [[ "$(manager_state_get sing_box_binary_managed false)" != true ]]; then
  warn "检测到已有 $SING_BOX_BINARY，但它不是本项目管理的程序。"
  prompt_yes_no '是否备份并替换为 SagerNet 官方 Release？' n || die '未接管现有 sing-box，安装已安全停止。'
  install_singbox_from_release "$singbox_install_target"
else
  info "保留现有本项目管理的 sing-box：$(singbox_binary_version || true)"
fi

detect_listen_mode
detect_traffic_interfaces
configure_bbr
configure_tcp_fast_open_kernel
singbox_config_supports_tfo || true

candidate="$RUNTIME_DIR/config.install-candidate.$$.json"
generate_singbox_config "$NODES_FILE" "$candidate"
singbox_check_config "$candidate" >/dev/null || die '节点数据库生成的候选配置未通过 sing-box 官方检查。'
check_manager_maintenance_service_files

install_service_path=$(service_definition_path "$SING_BOX_SERVICE")
install_previous_service=''
install_service_mode=644
if [[ "$INIT_SYSTEM" == 'openrc' ]]; then
  install_service_mode=755
fi
install_had_service_unit=0
if service_exists "$SING_BOX_SERVICE"; then
  install_had_service_unit=1
fi
if [[ -f "$install_service_path" ]]; then
  install_previous_service="$RUNTIME_DIR/sing-box.service.install-previous.$$"
  install -m "$install_service_mode" -- "$install_service_path" "$install_previous_service"
fi
install_singbox_service_unit

install_manager_maintenance_service_files

cat >"$RUNTIME_DIR/rem.wrapper" <<'EOF'
#!/usr/bin/env bash
exec /opt/ss-manager/ss-manager.sh "$@"
EOF
install -m 755 -- "$RUNTIME_DIR/rem.wrapper" /usr/local/bin/rem
rm -f -- "$RUNTIME_DIR/rem.wrapper"

install -m 600 -- "$candidate" "$SING_BOX_CONFIG"
if ! singbox_restart || ! singbox_health_check "$NODES_FILE"; then
  error 'sing-box 安装/修复后的健康检查失败，正在恢复安装前配置。'
  singbox_stop >/dev/null 2>&1 || true
  if [[ -n "$install_previous_config" && -f "$install_previous_config" ]]; then
    install -m 600 -- "$install_previous_config" "$SING_BOX_CONFIG"
  else
    rm -f -- "$SING_BOX_CONFIG"
  fi
  if [[ -n "$install_previous_service" && -f "$install_previous_service" ]]; then
    install -m "$install_service_mode" -- "$install_previous_service" "$install_service_path"
  else
    rm -f -- "$install_service_path"
  fi
  service_manager_reload >/dev/null 2>&1 || true
  if (( install_had_service_unit == 1 )) && [[ -n "$install_previous_config" ]]; then
    singbox_restart >/dev/null 2>&1 || true
  fi
  rm -f -- "$candidate" "$install_previous_config" "$install_previous_service"
  die '安装/修复失败；安装前配置已恢复，未进入节点创建流程。'
fi
rm -f -- "$candidate" "$install_previous_config" "$install_previous_service"

success "Ss2022 manager $MANAGER_VERSION 安装/修复完成。"
printf '以后可在任意目录执行：rem\n'
printf '本项目不会自动修改服务器防火墙、云安全组或现有安全策略。\n'

installed_node_count=$(jq -er '.nodes | length' "$NODES_FILE") || die '无法读取节点数据库，未进入节点创建流程。'
install_completed=$(manager_state_get install_completed false)
if (( installed_node_count == 0 )) && [[ "$install_completed" != true ]]; then
  exec "$PROGRAM_DIR/ss-manager.sh" --first-run
fi
enable_manager_maintenance_service
manager_state_set_json install_completed true
exec "$PROGRAM_DIR/ss-manager.sh" menu
