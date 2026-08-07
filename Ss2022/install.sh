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
source "$SCRIPT_DIR/lib/singbox.sh"

require_root
detect_host

existing_rem=$(command -v rem 2>/dev/null || true)
if [[ -n "$existing_rem" ]] && ! is_command_from_manager "$existing_rem"; then
  warn "检测到已有 rem 命令：$existing_rem。"
  prompt_yes_no '是否由 Ss2022 替换这个 rem 命令？' n || die '未替换已有 rem，安装已安全停止。'
fi

fresh_install=1
if [[ -f "$MANAGER_STATE" || -f "$NODES_FILE" || -x "$SING_BOX_BINARY" ]]; then
  fresh_install=0
  info '检测到已有安装数据，将执行幂等的修复/补齐流程，不会覆盖节点、密码或流量数据。'
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
    --arg created_at "$(timestamp_iso)" \
    '{schema_version:1,manager_version:$manager_version,sing_box_version:"",sing_box_binary_managed:false,sing_box_version_lock:null,created_at:$created_at,listen_mode:"ipv4",listen_address:"0.0.0.0",tfo_kernel_supported:false,tfo_kernel_enabled:false,tfo_config_supported:false,bbr_supported:false,bbr_enabled:false}' \
    | atomic_json_from_stdin "$MANAGER_STATE" 600
else
  jq -e . "$MANAGER_STATE" >/dev/null || die 'manager.json 无效，安装不会覆盖；请先使用备份恢复。'
fi

initialize_state_files

copy_program() {
  install -d -m 700 -- "$PROGRAM_DIR/lib" "$PROGRAM_DIR/config" "$PROGRAM_DIR/systemd"
  install -m 755 -- "$SCRIPT_DIR/ss-manager.sh" "$PROGRAM_DIR/ss-manager.sh"
  local file
  while IFS= read -r file; do install -m 700 -- "$file" "$PROGRAM_DIR/lib/$(basename "$file")"; done < <(find "$SCRIPT_DIR/lib" -maxdepth 1 -type f -name '*.sh' -print | sort)
  install -m 600 -- "$SCRIPT_DIR/config/defaults.conf" "$PROGRAM_DIR/config/defaults.conf"
  while IFS= read -r file; do install -m 644 -- "$file" "$PROGRAM_DIR/systemd/$(basename "$file")"; done < <(find "$SCRIPT_DIR/systemd" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -print | sort)
}
copy_program

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

install_singbox_service_unit
if [[ ! -f "$SING_BOX_CONFIG" ]]; then
  candidate="$RUNTIME_DIR/config.initial.$$.json"
  generate_singbox_config "$NODES_FILE" "$candidate"
  singbox_check_config "$candidate" >/dev/null
  install -m 600 -- "$candidate" "$SING_BOX_CONFIG"
  rm -f -- "$candidate"
else
  chmod 600 -- "$SING_BOX_CONFIG"
  singbox_check_config "$SING_BOX_CONFIG" >/dev/null || die '现有 sing-box 配置检查失败；安装不会覆盖它。'
fi

systemd_install_units() {
  install -m 644 -- "$PROGRAM_DIR/systemd/ss-manager-traffic.service" "$SYSTEMD_DIR/ss-manager-traffic.service"
  install -m 644 -- "$PROGRAM_DIR/systemd/ss-manager-traffic.timer" "$SYSTEMD_DIR/ss-manager-traffic.timer"
  systemctl daemon-reload
  systemctl enable "$SING_BOX_SERVICE" >/dev/null
  systemctl enable --now "$SYSTEMD_TRAFFIC_TIMER" >/dev/null
}
systemd_install_units

cat >"$RUNTIME_DIR/rem.wrapper" <<'EOF'
#!/usr/bin/env bash
exec /opt/ss-manager/ss-manager.sh "$@"
EOF
install -m 755 -- "$RUNTIME_DIR/rem.wrapper" /usr/local/bin/rem
rm -f -- "$RUNTIME_DIR/rem.wrapper"

if ! singbox_is_active; then
  singbox_start
fi
singbox_health_check "$NODES_FILE" || die 'sing-box 安装后健康检查失败，未进入节点创建流程。'

success "Ss2022 manager $MANAGER_VERSION 安装/修复完成。"
printf '以后可在任意目录执行：rem\n'
printf '本项目不会自动修改服务器防火墙、云安全组或现有安全策略。\n'

if (( fresh_install == 1 )) && (( $(node_count) == 0 )); then
  exec "$PROGRAM_DIR/ss-manager.sh" --first-run
fi
exec "$PROGRAM_DIR/ss-manager.sh" menu
