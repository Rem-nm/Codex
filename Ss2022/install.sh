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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/traffic.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/bandwidth.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup.sh"

require_root
detect_host
assert_standard_destructive_paths

install_preflight_existing_paths() {
  local existing_rem
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
}

install_preflight_service_ownership() {
  local name path source presence_status
  # This approval is an in-process result of the prompt below.  Never trust a
  # value inherited from the caller to authorize replacing a foreign service.
  SS_MANAGER_SERVICE_TAKEOVER_APPROVED=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    if service_definition_path_present "$name" && ! service_definition_is_managed "$name"; then
      if [[ "$name" == "$SING_BOX_SERVICE" ]]; then
        warn "$path 已存在且不是本项目创建。"
        prompt_yes_no '是否明确接管该 sing-box 服务并替换其服务定义？失败时会自动恢复' n \
          || die '未接管已有 sing-box 服务，安装已安全停止。'
        SS_MANAGER_SERVICE_TAKEOVER_APPROVED=1
      else
        die "$path 已存在且不是本项目创建；安装预检已停止，尚未修改项目状态。"
      fi
    fi
    if ! service_definition_path_present "$name"; then
      presence_status=0
      service_exists "$name" || presence_status=$?
      (( presence_status != 2 )) || die "无法可靠查询系统是否已有 $name 服务；拒绝在状态未知时接管。"
      if (( presence_status == 0 )) && [[ "$name" == "$SING_BOX_SERVICE" ]]; then
        warn "系统已有 $name 服务，但它不在本项目管理路径下。"
        prompt_yes_no '是否明确接管该 sing-box 服务？' n || die '未接管已有 sing-box 服务，安装已安全停止。'
        SS_MANAGER_SERVICE_TAKEOVER_APPROVED=1
      elif (( presence_status == 0 )); then
        die "系统已有同名维护服务 $name，且不属于 Ss2022；拒绝接管。"
      fi
    fi
    if [[ "$INIT_SYSTEM" == systemd ]]; then
      source="$SCRIPT_DIR/systemd/$(service_systemd_unit_name "$name")"
    elif [[ "$name" == "$SING_BOX_SERVICE" ]]; then
      source="$SCRIPT_DIR/openrc/sing-box"
    else
      source="$SCRIPT_DIR/openrc/$OPENRC_TRAFFIC_SERVICE"
    fi
    [[ -f "$source" && ! -L "$source" ]] || die "安装源缺少常规服务模板或模板为符号链接：$source"
  done < <(install_transaction_service_names)
  export SS_MANAGER_SERVICE_TAKEOVER_APPROVED
}

pending_recovery=0
if [[ -e "$INSTALL_TRANSACTION_DIR" || -L "$INSTALL_TRANSACTION_DIR" \
  || -e "$STATE_TRANSACTION_DIR" || -L "$STATE_TRANSACTION_DIR" ]]; then
  pending_recovery=1
  warn '检测到持久恢复日志；将先补齐恢复所需依赖并完成恢复，再执行接管确认。'
else
  install_preflight_existing_paths
  install_preflight_service_ownership
fi

install_packages
ensure_runtime_dirs
ensure_dir "$CONFIG_DIR" 700
ensure_dir "$DATA_DIR" 700
ensure_dir "$BACKUP_DIR" 700
acquire_manager_lock
recover_incomplete_install_transaction
recover_incomplete_state_transaction
if (( pending_recovery == 1 )); then
  install_preflight_existing_paths
  install_preflight_service_ownership
fi

fresh_install=1
if [[ -f "$MANAGER_STATE" || -f "$NODES_FILE" || -x "$PROGRAM_DIR/ss-manager.sh" ]]; then
  fresh_install=0
fi

if (( fresh_install == 0 )); then
  validate_installed_state_files
fi

program_stage="${PROGRAM_DIR}.install-new.$$"
program_old="${PROGRAM_DIR}.install-old.$$"
[[ ! -e "$program_stage" && ! -L "$program_stage" && ! -e "$program_old" && ! -L "$program_old" ]] \
  || die '安装程序暂存目录已存在，拒绝覆盖。'
install_transaction_begin "$program_stage" "$program_old"
INSTALL_TRANSACTION_ACTIVE=1
install_transaction_exit_handler() {
  local status=$?
  trap - EXIT
  if [[ "${INSTALL_TRANSACTION_ACTIVE:-0}" == 1 && "$status" -ne 0 ]]; then
    set +e
    error "安装/修复在退出码 $status 处中断，正在恢复安装前的完整状态。"
    if install_transaction_restore && install_transaction_clear; then
      warn '安装前的程序、状态、服务、二进制与内核设置已恢复。'
    else
      error "自动恢复未完成；恢复证据保留在 $INSTALL_TRANSACTION_DIR。"
    fi
  fi
  exit "$status"
}
trap install_transaction_exit_handler EXIT
install_transaction_set_phase installing || die '无法持久记录安装事务阶段。'

# Upgrade pre-1.0.4 traffic state only after the install transaction has
# snapshotted the old files.  A failure or crash therefore restores the
# legacy file instead of leaving a half-migrated database behind.
traffic_migrate_legacy_state || die '旧版 traffic.json 迁移失败；安装事务将恢复安装前状态。'

if [[ ! -f "$MANAGER_STATE" ]]; then
  manager_created_at=$(timestamp_iso) || die '无法生成 manager 状态时间戳。'
  jq -n \
    --arg manager_version "$MANAGER_VERSION" \
    --arg init_system "$INIT_SYSTEM" \
    --arg created_at "$manager_created_at" \
    '{schema_version:1,manager_version:$manager_version,init_system:$init_system,install_completed:false,sing_box_version:"",sing_box_binary_managed:false,sing_box_binary_sha256:"",sing_box_version_lock:null,created_at:$created_at,listen_mode:"ipv4",listen_address:"0.0.0.0",tfo_kernel_supported:false,tfo_kernel_enabled:false,tfo_config_supported:false,bbr_supported:false,bbr_enabled:false,tc_capabilities_verified:false,tc_capability_signature:"",quota_include_unauthenticated_upload:false}' \
    | atomic_json_from_stdin "$MANAGER_STATE" 600 || die '无法创建 manager.json。'
else
  jq -e . "$MANAGER_STATE" >/dev/null || die 'manager.json 无效，安装不会覆盖；请先使用备份恢复。'
fi

initialize_state_files || die '无法初始化状态文件。'
ensure_tc_capabilities || die '当前系统缺少 Ss2022 所需的 tc 能力；安装前状态将完整恢复。'

copy_program_to() {
  local target=$1
  [[ -f "$SCRIPT_DIR/ss-manager.sh" && ! -L "$SCRIPT_DIR/ss-manager.sh" \
    && -f "$SCRIPT_DIR/VERSION" && ! -L "$SCRIPT_DIR/VERSION" \
    && -f "$SCRIPT_DIR/config/defaults.conf" && ! -L "$SCRIPT_DIR/config/defaults.conf" ]] || return 1
  install -d -m 700 -- "$target/lib" "$target/config" "$target/systemd" "$target/openrc" || return 1
  install -m 755 -- "$SCRIPT_DIR/ss-manager.sh" "$target/ss-manager.sh" || return 1
  install -m 644 -- "$SCRIPT_DIR/VERSION" "$target/VERSION" || return 1
  local file list_file
  local -a files=()
  list_file=$(runtime_temp_file install-lib-files) || return 1
  find "$SCRIPT_DIR/lib" -maxdepth 1 -type f -name '*.sh' -print0 >"$list_file" \
    || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  ((${#files[@]} > 0)) || return 1
  for file in "${files[@]}"; do install -m 700 -- "$file" "$target/lib/$(basename -- "$file")" || return 1; done
  install -m 600 -- "$SCRIPT_DIR/config/defaults.conf" "$target/config/defaults.conf" || return 1
  files=()
  list_file=$(runtime_temp_file install-systemd-files) || return 1
  find "$SCRIPT_DIR/systemd" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -print0 >"$list_file" \
    || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  ((${#files[@]} > 0)) || return 1
  for file in "${files[@]}"; do install -m 644 -- "$file" "$target/systemd/$(basename -- "$file")" || return 1; done
  files=()
  list_file=$(runtime_temp_file install-openrc-files) || return 1
  find "$SCRIPT_DIR/openrc" -maxdepth 1 -type f -print0 >"$list_file" \
    || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  ((${#files[@]} > 0)) || return 1
  for file in "${files[@]}"; do install -m 700 -- "$file" "$target/openrc/$(basename -- "$file")" || return 1; done
  files=()
  list_file=$(runtime_temp_file install-bash-syntax-files) || return 1
  find "$target" -type f -name '*.sh' -print0 >"$list_file" || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  for file in "${files[@]}"; do bash -n "$file" || return 1; done
  files=()
  list_file=$(runtime_temp_file install-openrc-syntax-files) || return 1
  find "$target/openrc" -maxdepth 1 -type f -print0 >"$list_file" || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done <"$list_file"
  rm -f -- "$list_file" || return 1
  for file in "${files[@]}"; do sh -n "$file" || return 1; done
  [[ "$(tr -d '[:space:]' <"$target/VERSION")" == "$MANAGER_VERSION" ]] || return 1
}

copy_program_to "$program_stage" || die '新 manager 程序暂存或语法检查失败。'
durable_sync_tree "$program_stage" || die '新 manager 程序无法持久同步到磁盘。'
if [[ -e "$PROGRAM_DIR" || -L "$PROGRAM_DIR" ]]; then
  atomic_move_directory_to_absent_path "$PROGRAM_DIR" "$program_old" || die '无法原子保存当前 manager 程序目录。'
fi
atomic_move_directory_to_absent_path "$program_stage" "$PROGRAM_DIR" || die '无法切换到新 manager 程序目录。'
durable_sync_path /opt || die 'manager 程序目录切换无法持久同步。'
manager_state_set_json manager_version "$(jq -Rn --arg value "$MANAGER_VERSION" '$value')" || die '无法提交 manager 版本状态。'
manager_state_set_json init_system "$(jq -Rn --arg value "$INIT_SYSTEM" '$value')" || die '无法提交 init system 状态。'

singbox_install_target=latest
singbox_locked_version=$(manager_state_get sing_box_version_lock '') || die '无法读取 sing-box 版本锁定状态。'
singbox_binary_managed=$(manager_state_get sing_box_binary_managed false) || die '无法读取 sing-box 二进制所有权状态。'
if [[ -n "$singbox_locked_version" && "$singbox_locked_version" != null ]]; then
  singbox_install_target="$singbox_locked_version"
  info "检测到 sing-box 版本锁定，将安装锁定版本 $singbox_install_target。"
fi

if [[ -d "$SING_BOX_BINARY" ]]; then
  die "$SING_BOX_BINARY 是目录或指向目录，拒绝把二进制误写入其中。"
elif [[ -L "$SING_BOX_BINARY" ]]; then
  warn "检测到 sing-box 路径是符号链接：$SING_BOX_BINARY。"
  prompt_yes_no '是否明确用 SagerNet 官方 Release 的常规文件替换该链接？' n \
    || die '未替换 sing-box 符号链接，安装已安全停止。'
  install_singbox_from_release "$singbox_install_target"
elif [[ ! -e "$SING_BOX_BINARY" ]]; then
  install_singbox_from_release "$singbox_install_target"
elif [[ ! -x "$SING_BOX_BINARY" ]]; then
  warn "检测到已有但不可执行的 sing-box 路径：$SING_BOX_BINARY。"
  prompt_yes_no '是否明确用 SagerNet 官方 Release 替换该文件？' n \
    || die '未替换现有 sing-box 文件，安装已安全停止。'
  install_singbox_from_release "$singbox_install_target"
elif [[ "$singbox_binary_managed" != true ]]; then
  warn "检测到已有 $SING_BOX_BINARY，但它不是本项目管理的程序。"
  prompt_yes_no '是否备份并替换为 SagerNet 官方 Release？' n || die '未接管现有 sing-box，安装已安全停止。'
  install_singbox_from_release "$singbox_install_target"
else
  ensure_managed_singbox_binary_identity || die '现有 sing-box 二进制身份与 manager 所有权状态不一致。'
  info "保留现有本项目管理的 sing-box：$(singbox_binary_version)"
fi

detect_listen_mode || die '监听模式探测/状态提交失败。'
detect_traffic_interfaces || die '默认路由接口探测/状态提交失败。'
configure_bbr || die 'BBR 配置未能安全提交。'
configure_tcp_fast_open_kernel || die 'TCP Fast Open 内核配置未能安全提交。'
singbox_config_supports_tfo || die 'TCP Fast Open 配置能力探测状态未能安全提交。'

candidate=$(runtime_temp_file config.install-candidate) || die '无法创建候选配置暂存文件。'
generate_singbox_config "$NODES_FILE" "$candidate" || die '无法从节点数据库生成候选配置。'
singbox_check_config "$candidate" >/dev/null || die '节点数据库生成的候选配置未通过 sing-box 官方检查。'
check_manager_maintenance_service_files

install_singbox_service_unit || die 'sing-box 服务定义安装失败。'
install_manager_maintenance_service_files || die '流量维护服务定义安装失败。'

install_rem_command || die 'rem 命令安装失败。'

atomic_json_write "$candidate" "$SING_BOX_CONFIG" 600 || die '候选 sing-box 配置安装失败。'
if ! singbox_restart || ! singbox_health_check "$NODES_FILE"; then
  die 'sing-box 安装/修复后的健康检查失败；将由持久安装事务恢复完整安装前状态。'
fi
rm -f -- "$candidate" || warn '安装配置已经提交，但候选配置清理失败。'

installed_node_count=$(jq -er '.nodes | length' "$NODES_FILE") || die '无法读取节点数据库，未进入节点创建流程。'
install_completed=$(manager_state_get install_completed false) || die '无法读取安装完成状态。'
if (( installed_node_count > 0 )) || [[ "$install_completed" == true ]]; then
  enable_manager_maintenance_service || die '流量维护服务启用失败。'
  manager_state_set_json install_completed true || die '安装完成状态提交失败。'
fi
"$PROGRAM_DIR/ss-manager.sh" --self-test >/dev/null 2>&1 || die '安装后的 manager 入口自检失败。'
ensure_managed_singbox_binary_identity || die '安装后的 sing-box 二进制身份检查失败。'
validate_installed_state_files
if [[ -e "$program_old" ]]; then
  [[ "$program_old" == /opt/ss-manager.install-old.* ]] || die '旧程序清理目标不安全。'
  rm -rf -- "$program_old" || die '旧 manager 程序暂存目录清理失败。'
  durable_sync_path /opt || die '旧 manager 程序目录删除无法持久同步。'
fi
install_transaction_set_phase committed || die '安装完成标记无法持久提交；将恢复安装前状态。'
INSTALL_TRANSACTION_ACTIVE=0
install_transaction_clear || warn "安装已经提交，但持久安装事务日志未能清理；下次启动会仅重试清理：$INSTALL_TRANSACTION_DIR"
trap - EXIT

success "Ss2022 manager $MANAGER_VERSION 安装/修复完成。"
printf '以后可在任意目录执行：rem\n'
printf '本项目不会自动修改服务器防火墙、云安全组或现有安全策略。\n'

if (( installed_node_count == 0 )) && [[ "$install_completed" != true ]]; then
  release_manager_lock
  exec "$PROGRAM_DIR/ss-manager.sh" --first-run
fi
release_manager_lock
exec "$PROGRAM_DIR/ss-manager.sh" menu
