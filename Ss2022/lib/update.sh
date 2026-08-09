#!/usr/bin/env bash
# Official-source updates for sing-box and the manager.

manager_version() { printf '%s' "$MANAGER_VERSION"; }

singbox_lock_value() {
  manager_state_get sing_box_version_lock ''
}

singbox_update_info() {
  local current latest latest_version lock
  current=$(singbox_binary_version 2>/dev/null || printf '未安装')
  lock=$(singbox_lock_value) || return 1
  latest=$(fetch_singbox_release_json latest 2>/dev/null || true)
  if [[ -n "$latest" ]]; then
    latest_version=$(jq -r '.tag_name // "未知"' <<<"$latest" 2>/dev/null || true)
    [[ -n "$latest_version" ]] || latest_version='查询失败'
  else
    latest_version='查询失败'
  fi
  printf '当前 sing-box：%s\n可用官方版本：%s\n版本锁定：%s\n' "$current" "$latest_version" "${lock:-未锁定}"
}

singbox_update_transaction_exit_handler() {
  local status=$?
  trap - EXIT
  if [[ "${SINGBOX_UPDATE_TRANSACTION_ACTIVE:-0}" == 1 ]]; then
    (( status != 0 )) || status=1
    set +e
    error 'sing-box 更新未提交，正在从持久事务恢复更新前的二进制、配置、服务和状态。'
    if install_transaction_restore && install_transaction_clear; then
      warn 'sing-box 更新前状态已完整恢复。'
    else
      error "sing-box 更新自动恢复未完成；证据保留在 $INSTALL_TRANSACTION_DIR。"
    fi
  fi
  exit "$status"
}

singbox_update_transaction_begin() {
  install_transaction_begin || return 1
  SINGBOX_UPDATE_TRANSACTION_ACTIVE=1
  trap singbox_update_transaction_exit_handler EXIT
  install_transaction_set_phase singbox_update || return 1
}

singbox_update_transaction_commit() {
  install_transaction_set_phase committed || return 1
  SINGBOX_UPDATE_TRANSACTION_ACTIVE=0
  if ! install_transaction_clear; then
    warn "sing-box 更新已经提交，但事务日志未能清理；下次启动会仅重试清理：$INSTALL_TRANSACTION_DIR"
  fi
  trap - EXIT
}

singbox_update_flow() {
  acquire_manager_lock
  assert_standard_destructive_paths
  singbox_update_info
  local lock latest latest_version target old_active=0 active_status=0
  lock=$(singbox_lock_value) || return 1
  latest=$(fetch_singbox_release_json latest 2>/dev/null || true)
  latest_version=$(jq -r '.tag_name // empty' <<<"$latest" 2>/dev/null || true)
  [[ -n "$latest_version" ]] || { warn '无法查询官方 sing-box Release。'; return 0; }
  target=${latest_version#v}
  if [[ -n "$lock" ]]; then
    info "已锁定 sing-box $lock；如需更新请先解除版本锁定。"
    return 0
  fi
  prompt_yes_no "更新到官方版本 $target？更新前会备份当前二进制和配置" n || return 0
  singbox_is_active || active_status=$?
  (( active_status != 2 )) || { error '无法可靠查询 sing-box 运行状态，已停止更新。'; return 1; }
  if (( active_status == 0 )); then old_active=1; fi
  singbox_update_transaction_begin || return 1
  backup_create_snapshot "sing-box-update-$target" >/dev/null || return 1
  install_singbox_from_release "$target"
  if (( old_active == 1 )) && { ! singbox_restart || ! singbox_health_check "$NODES_FILE"; }; then
    error '新版 sing-box 健康检查失败，将由持久事务恢复旧版。'
    return 1
  fi
  if (( old_active == 0 )); then
    singbox_confirm_inactive || {
      error '更新前 sing-box 已停止，但更新后无法确认仍处于停止状态。'
      return 1
    }
    if ! singbox_check_config "$SING_BOX_CONFIG" >/dev/null; then
      error '新版 sing-box 在停止状态下未能再次通过当前配置检查，将由持久事务恢复旧版。'
      return 1
    fi
  fi
  singbox_update_transaction_commit || return 1
  backup_prune || warn 'sing-box 更新已经提交，但旧备份自动清理失败。'
  success "sing-box 已更新到 $target。"
}

singbox_set_lock_flow() {
  acquire_manager_lock
  local current input
  current=$(singbox_binary_version 2>/dev/null || true)
  [[ -n "$current" ]] || die '当前未安装 sing-box。'
  printf '当前版本：%s\n输入要锁定的版本（留空锁定当前版本）：\n> ' "$current"
  IFS= read -r input || die '读取输入失败。'
  [[ -z "$input" ]] && input=$current
  [[ "$input" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die '版本格式无效。'
  input=${input#v}
  manager_state_set_json sing_box_version_lock "$(jq -Rn --arg value "$input" '$value')"
  success "已锁定 sing-box $input。"
}

singbox_clear_lock_flow() {
  acquire_manager_lock
  manager_state_set_json sing_box_version_lock null
  success '已解除 sing-box 版本锁定。'
}

manager_release_json() {
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 30 \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -- "https://api.github.com/repos/$MANAGER_REPOSITORY/releases/latest"
}

assert_official_manager_release_url() {
  local url=$1
  [[ "$url" == https://github.com/Rem-nm/Codex/releases/download/* ]] || die "拒绝非官方 manager Release 地址：$url"
}

manager_update_info() {
  local json tag
  json=$(manager_release_json 2>/dev/null || true)
  tag=$(jq -r '.tag_name // empty' <<<"$json" 2>/dev/null || true)
  printf '当前 manager：%s\n可用官方版本：%s\n' "$MANAGER_VERSION" "${tag:-暂无可验证 Release}"
}

manager_update_service_names() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    printf '%s\n' "$SING_BOX_SERVICE" "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"
  else
    printf '%s\n' "$SING_BOX_SERVICE" "$OPENRC_TRAFFIC_SERVICE"
  fi
}

manager_update_backup_service_files() {
  local backup_dir=$1 name path index=0
  ensure_dir "$backup_dir" 700 || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$backup_dir/$index.present" || return 1
    else
      : >"$backup_dir/$index.absent" || return 1
    fi
    index=$((index + 1))
  done < <(manager_update_service_names)
}

manager_update_restore_service_files() {
  local backup_dir=$1 name path index=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    rm -f -- "$path" || return 1
    if [[ -e "$backup_dir/$index.present" || -L "$backup_dir/$index.present" ]]; then
      cp -a -- "$backup_dir/$index.present" "$path" || return 1
    elif [[ ! -f "$backup_dir/$index.absent" ]]; then
      error "manager 更新服务备份不完整：$name"
      return 1
    fi
    index=$((index + 1))
  done < <(manager_update_service_names)
  service_manager_reload || return 1
}

manager_update_install_service_files() {
  local source destination mode presence_status=0
  destination=$(service_definition_path "$SING_BOX_SERVICE") || return 1
  if service_definition_path_present "$SING_BOX_SERVICE" && ! service_definition_is_managed "$SING_BOX_SERVICE"; then
    error "$destination 已存在且不属于 Ss2022，拒绝在更新时覆盖。"
    return 1
  fi
  if ! service_definition_path_present "$SING_BOX_SERVICE"; then
    service_exists "$SING_BOX_SERVICE" || presence_status=$?
    (( presence_status != 2 )) || { error "无法可靠查询 $SING_BOX_SERVICE 是否存在，拒绝在更新时接管。"; return 1; }
    (( presence_status != 0 )) || { error "$SING_BOX_SERVICE 来自其他系统路径，拒绝在更新时接管。"; return 1; }
  fi
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    source="$PROGRAM_DIR/systemd/sing-box.service"
    mode=644
  else
    source="$PROGRAM_DIR/openrc/sing-box"
    mode=755
  fi
  [[ -f "$source" && ! -L "$source" ]] || { error "manager 更新包缺少常规服务模板或模板为符号链接：$source"; return 1; }
  atomic_file_write "$source" "$destination" "$mode" 755 || return 1
  install_manager_maintenance_service_files
}

manager_update_finalize_switched_program() {
  local version=$1 version_output
  [[ -x "$PROGRAM_DIR/ss-manager.sh" ]] || return 1
  version_output=$("$PROGRAM_DIR/ss-manager.sh" --self-test 2>/dev/null) || return 1
  grep -Fxq "Ss2022 manager $version" <<<"$version_output" || return 1
  manager_update_install_service_files || return 1
  manager_state_set_json manager_version "$(jq -Rn --arg value "$version" '$value')" || return 1
  install_rem_command || return 1
}

manager_update_transaction_exit_handler() {
  local status=$?
  trap - EXIT
  if [[ "${MANAGER_UPDATE_TRANSACTION_ACTIVE:-0}" == 1 ]]; then
    (( status != 0 )) || status=1
    set +e
    error 'manager 更新未提交，正在从持久事务恢复更新前的完整状态。'
    if install_transaction_restore && install_transaction_clear; then
      warn 'manager 更新前状态已完整恢复。'
    else
      error "manager 更新自动恢复未完成；证据保留在 $INSTALL_TRANSACTION_DIR。"
    fi
  fi
  exit "$status"
}

manager_update_transaction_begin() {
  install_transaction_begin "$@" || return 1
  MANAGER_UPDATE_TRANSACTION_ACTIVE=1
  trap manager_update_transaction_exit_handler EXIT
  install_transaction_set_phase manager_update || return 1
}

manager_update_transaction_commit() {
  install_transaction_set_phase committed || return 1
  MANAGER_UPDATE_TRANSACTION_ACTIVE=0
  if ! install_transaction_clear; then
    warn "manager 更新已经提交，但事务日志未能清理；下次启动会仅重试清理：$INSTALL_TRANSACTION_DIR"
  fi
  trap - EXIT
}

manager_update_normalize_program_permissions() {
  local root=$1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  find "$root" -type d -exec chmod 700 -- {} + || return 1
  find "$root" -type f -exec chmod 600 -- {} + || return 1
  chmod 755 -- "$root/ss-manager.sh" || return 1
  chmod 644 -- "$root/VERSION" || return 1
  find "$root/lib" "$root/openrc" -type f -exec chmod 700 -- {} + || return 1
  find "$root/systemd" -type f -exec chmod 644 -- {} + || return 1
}

manager_update_validate_package_structure() {
  local root=$1 relative
  local -a required_files=(
    ss-manager.sh VERSION config/defaults.conf
    lib/common.sh lib/system.sh lib/service.sh lib/singbox.sh lib/traffic.sh
    lib/bandwidth.sh lib/backup.sh lib/nodes.sh lib/links.sh lib/update.sh lib/menu.sh
    systemd/sing-box.service systemd/ss-manager-traffic.service systemd/ss-manager-traffic.timer
    openrc/sing-box openrc/ss-manager-traffic openrc/ss-manager-traffic-loop.sh
  )
  [[ -d "$root" && ! -L "$root" ]] || return 1
  for relative in "${required_files[@]}"; do
    [[ -f "$root/$relative" && ! -L "$root/$relative" ]] || {
      error "manager 更新包缺少常规文件：$relative"
      return 1
    }
  done
}

manager_update_flow() {
  acquire_manager_lock
  assert_standard_destructive_paths
  manager_update_info
  local json tag version asset_name checksum_name asset_url checksum_url asset_digest archive checksum expected actual extract_root source_entry source_root source_list syntax_list file old_program new_program service_backup state_backup invalid_program
  json=$(manager_release_json 2>/dev/null || true)
  tag=$(jq -r '.tag_name // empty' <<<"$json" 2>/dev/null || true)
  [[ -n "$tag" ]] || { warn 'Rem-nm/Codex 暂无 manager Release 或查询失败，未执行任何下载。'; return 0; }
  version=${tag#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "manager Release 标签格式无效：$tag"
  asset_name="$MANAGER_RELEASE_ASSET"
  asset_url=$(release_asset_url "$json" "$asset_name" 2>/dev/null) || { warn "manager Release 缺少唯一的 $asset_name。"; return 0; }
  assert_official_manager_release_url "$asset_url"
  asset_digest=$(release_asset_digest "$json" "$asset_name") || die 'manager Release 资产不唯一或元数据无效。'
  if [[ "$asset_digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; then
    checksum_name=''
    checksum_url=''
  else
    checksum_name=${MANAGER_CHECKSUM_ASSET:-SHA256SUMS}
    checksum_url=$(release_asset_url "$json" "$checksum_name" 2>/dev/null) \
      || { warn "manager Release 没有唯一的 $checksum_name 或 asset digest，已停止更新。"; return 0; }
    assert_official_manager_release_url "$checksum_url"
  fi
  prompt_yes_no "从 Rem-nm/Codex 官方 Release 更新 manager 到 $version？" n || return 0

  archive="$RUNTIME_DIR/ss-manager-$version.$$.${RANDOM}.tar.gz"
  checksum="$RUNTIME_DIR/ss-manager-$version.$$.${RANDOM}.SHA256SUMS"
  [[ ! -e "$archive" && ! -L "$archive" && ! -e "$checksum" && ! -L "$checksum" ]] \
    || die 'manager 下载暂存文件已存在，拒绝覆盖。'
  if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 120 \
    --output "$archive" -- "$asset_url"; then
    rm -f -- "$archive"
    die 'manager Release 下载失败；未替换当前程序。'
  fi
  if [[ -n "$asset_digest" ]]; then
    expected=${asset_digest#sha256:}
  else
    if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 30 \
      --output "$checksum" -- "$checksum_url"; then
      rm -f -- "$archive" "$checksum"
      die 'manager 校验文件下载失败；未替换当前程序。'
    fi
    expected=$(checksum_file_digest_for_asset "$checksum" "$asset_name") \
      || die "manager SHA256 文件中必须且只能包含一个 $asset_name 校验值。"
  fi
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'manager Release SHA256 校验值无效。'
  actual=$(sha256sum -- "$archive" | awk '{print $1}') || die '无法计算 manager 下载文件摘要。'
  [[ "${actual,,}" == "${expected,,}" ]] || die 'manager 下载校验失败，未替换程序。'

  extract_root="$RUNTIME_DIR/ss-manager-$version-extract.$$.${RANDOM}"
  [[ ! -e "$extract_root" && ! -L "$extract_root" ]] || die 'manager 解压暂存目录已存在，拒绝复用。'
  mkdir -m 700 -- "$extract_root" || die '无法创建 manager 解压暂存目录。'
  if tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'; then :; else die 'manager 归档包含不安全路径。'; fi
  if tar -tvzf "$archive" | awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {bad=1} END {exit bad}'; then :; else die 'manager 归档包含链接、设备或其他非普通条目。'; fi
  tar -xzf "$archive" -C "$extract_root" --no-same-owner --no-same-permissions \
    || die 'manager 归档解压失败。'
  local -a source_entries=() syntax_files=()
  source_list="$RUNTIME_DIR/manager-source-entries.$$.${RANDOM}.list"
  [[ ! -e "$source_list" && ! -L "$source_list" ]] || die 'manager 归档枚举暂存文件已存在。'
  find "$extract_root" -type f -name ss-manager.sh -print0 >"$source_list" \
    || { rm -f -- "$source_list"; die '无法枚举 manager 更新包入口。'; }
  while IFS= read -r -d '' source_entry; do source_entries+=("$source_entry"); done <"$source_list"
  rm -f -- "$source_list" || die 'manager 归档枚举暂存文件清理失败。'
  (( ${#source_entries[@]} == 1 )) || die 'manager 归档必须且只能包含一个 ss-manager.sh。'
  source_entry=${source_entries[0]}
  source_root=$(dirname -- "$source_entry") || die '无法确定 manager 更新包根目录。'
  manager_update_validate_package_structure "$source_root" || die 'manager 归档结构无效。'
  grep -q '^recover_incomplete_install_transaction()' "$source_root/lib/backup.sh" \
    || die 'manager 更新包缺少持久安装事务恢复能力。'
  [[ "$(tr -d '[:space:]' <"$source_root/VERSION")" == "$version" ]] || die 'manager 归档 VERSION 与 Release 标签不一致。'
  syntax_list="$RUNTIME_DIR/manager-syntax-entries.$$.${RANDOM}.list"
  [[ ! -e "$syntax_list" && ! -L "$syntax_list" ]] || die 'manager 语法检查枚举暂存文件已存在。'
  find "$source_root" -type f -name '*.sh' -print0 >"$syntax_list" \
    || { rm -f -- "$syntax_list"; die '无法枚举 manager 更新包的 shell 文件。'; }
  while IFS= read -r -d '' file; do syntax_files+=("$file"); done <"$syntax_list"
  rm -f -- "$syntax_list" || die 'manager 语法检查枚举暂存文件清理失败。'
  for file in "${syntax_files[@]}"; do bash -n "$file" || die "manager 更新包语法检查失败：$file"; done
  syntax_files=()
  syntax_list="$RUNTIME_DIR/manager-openrc-entries.$$.${RANDOM}.list"
  [[ ! -e "$syntax_list" && ! -L "$syntax_list" ]] || die 'OpenRC 语法检查枚举暂存文件已存在。'
  find "$source_root/openrc" -maxdepth 1 -type f -print0 >"$syntax_list" \
    || { rm -f -- "$syntax_list"; die '无法枚举 manager 更新包的 OpenRC 文件。'; }
  while IFS= read -r -d '' file; do syntax_files+=("$file"); done <"$syntax_list"
  rm -f -- "$syntax_list" || die 'OpenRC 语法检查枚举暂存文件清理失败。'
  for file in "${syntax_files[@]}"; do sh -n "$file" || die "OpenRC 模板语法检查失败：$file"; done

  old_program="${PROGRAM_DIR}.update-old.$$"
  new_program="${PROGRAM_DIR}.update-new.$$"
  invalid_program="${PROGRAM_DIR}.update-invalid.$$"
  service_backup="$RUNTIME_DIR/manager-update-services.$$"
  state_backup="$RUNTIME_DIR/manager-update-state.$$.json"
  [[ -d "$PROGRAM_DIR" && ! -L "$PROGRAM_DIR" && -x "$PROGRAM_DIR/ss-manager.sh" ]] || die '当前 manager 程序目录无效，拒绝更新。'
  [[ ! -e "$old_program" && ! -L "$old_program" && ! -e "$new_program" && ! -L "$new_program" \
    && ! -e "$invalid_program" && ! -L "$invalid_program" ]] || die 'manager 更新暂存目录已存在，拒绝覆盖。'
  manager_update_transaction_begin "$old_program" "$new_program" "$invalid_program" \
    || die '无法创建持久 manager 更新事务，未执行切换。'
  manager_update_backup_service_files "$service_backup" || die '无法备份当前服务定义，未执行 manager 更新。'
  install -m 600 -- "$MANAGER_STATE" "$state_backup" || die '无法备份 manager 状态，未执行更新。'
  cp -a -- "$source_root" "$new_program" || return 1
  manager_update_normalize_program_permissions "$new_program" || return 1
  durable_sync_tree "$new_program" || return 1
  if ! atomic_move_directory_to_absent_path "$PROGRAM_DIR" "$old_program"; then
    rm -rf -- "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    die 'manager 更新无法保存当前程序，未执行切换。'
  fi
  if ! atomic_move_directory_to_absent_path "$new_program" "$PROGRAM_DIR"; then
    atomic_move_directory_to_absent_path "$old_program" "$PROGRAM_DIR" || die 'manager 更新切换失败，且旧程序恢复失败。'
    rm -rf -- "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    die 'manager 更新切换失败，已恢复旧版本。'
  fi
  durable_sync_path /opt || return 1
  if ! manager_update_finalize_switched_program "$version"; then
    error 'manager 新版本自检、服务定义或状态提交失败，正在恢复旧版本。'
    if ! atomic_move_directory_to_absent_path "$PROGRAM_DIR" "$invalid_program" \
      || ! atomic_move_directory_to_absent_path "$old_program" "$PROGRAM_DIR"; then
      die '严重：manager 更新失败且旧程序目录无法恢复，请立即人工处理。'
    fi
    atomic_json_write "$state_backup" "$MANAGER_STATE" 600 || error '旧 manager 状态恢复失败。'
    if ! manager_update_restore_service_files "$service_backup"; then
      error '旧服务定义恢复失败，请立即人工处理。'
    fi
    rm -rf -- "$invalid_program" "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    return 1
  fi
  rm -rf -- "$old_program" || return 1
  durable_sync_path /opt || return 1
  manager_update_transaction_commit || return 1
  rm -rf -- "$extract_root" "$archive" "$checksum" "$service_backup" "$state_backup" \
    || warn 'manager 已提交，但下载/临时备份清理不完整。'
  success "manager 已更新到 $version；服务定义已同步，正在切换到新版本菜单。"
  trap - ERR
  exit 75
}

update_menu_flow() {
  local choice
  while true; do
    printf '\n更新管理\n1. 查看 sing-box 版本\n2. 更新 sing-box\n3. 锁定 sing-box 版本\n4. 解除 sing-box 版本锁定\n5. 查看 manager 版本\n6. 更新 manager\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1) singbox_update_info ;;
      2) run_menu_action singbox_update_flow ;;
      3) run_menu_action singbox_set_lock_flow ;;
      4) run_menu_action singbox_clear_lock_flow ;;
      5) manager_update_info ;;
      6) run_menu_action manager_update_flow ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
