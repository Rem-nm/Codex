#!/usr/bin/env bash
# Official-source updates for sing-box and the manager.

manager_version() { printf '%s' "$MANAGER_VERSION"; }

singbox_lock_value() {
  manager_state_get sing_box_version_lock ''
}

singbox_update_info() {
  local current latest latest_version lock
  current=$(singbox_binary_version 2>/dev/null || printf '未安装')
  lock=$(singbox_lock_value)
  latest=$(fetch_singbox_release_json latest 2>/dev/null || true)
  if [[ -n "$latest" ]]; then
    latest_version=$(jq -r '.tag_name // "未知"' <<<"$latest")
  else
    latest_version='查询失败'
  fi
  printf '当前 sing-box：%s\n可用官方版本：%s\n版本锁定：%s\n' "$current" "$latest_version" "${lock:-未锁定}"
}

singbox_update_flow() {
  acquire_manager_lock
  singbox_update_info
  local lock latest latest_version target old_binary old_config old_version old_managed old_active=0
  lock=$(singbox_lock_value)
  latest=$(fetch_singbox_release_json latest 2>/dev/null || true)
  latest_version=$(jq -r '.tag_name // empty' <<<"$latest")
  [[ -n "$latest_version" ]] || { warn '无法查询官方 sing-box Release。'; return 0; }
  target=${latest_version#v}
  if [[ -n "$lock" ]]; then
    info "已锁定 sing-box $lock；如需更新请先解除版本锁定。"
    return 0
  fi
  prompt_yes_no "更新到官方版本 $target？更新前会备份当前二进制和配置" n || return 0
  old_version=$(singbox_binary_version 2>/dev/null || true)
  old_managed=$(manager_state_get sing_box_binary_managed false)
  if singbox_is_active; then old_active=1; fi
  old_binary="$RUNTIME_DIR/sing-box.update-old.$$"
  old_config="$RUNTIME_DIR/config.update-old.$$"
  [[ -x "$SING_BOX_BINARY" ]] && install -m 755 -- "$SING_BOX_BINARY" "$old_binary"
  [[ -f "$SING_BOX_CONFIG" ]] && install -m 600 -- "$SING_BOX_CONFIG" "$old_config"
  backup_create_snapshot "sing-box-update-$target" >/dev/null
  backup_prune
  if ! install_singbox_from_release "$target"; then
    rm -f -- "$old_binary" "$old_config"
    return 1
  fi
  if (( old_active == 1 )) && { ! singbox_restart || ! singbox_health_check "$NODES_FILE"; }; then
    error '新版 sing-box 健康检查失败，正在恢复旧版。'
    [[ -x "$old_binary" ]] && install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
    [[ -f "$old_config" ]] && install -m 600 -- "$old_config" "$SING_BOX_CONFIG"
    manager_state_set_json sing_box_version "$(jq -Rn --arg value "$old_version" '$value')" >/dev/null 2>&1 || true
    manager_state_set_json sing_box_binary_managed "$old_managed" >/dev/null 2>&1 || true
    singbox_restart >/dev/null 2>&1 || true
    if singbox_health_check "$NODES_FILE" >/dev/null 2>&1; then
      warn '旧版 sing-box 已恢复并通过健康检查。'
    else
      error '严重：旧版恢复后健康检查失败，请立即人工处理。'
    fi
    rm -f -- "$old_binary" "$old_config"
    return 1
  fi
  if (( old_active == 0 )); then
    ! singbox_is_active || {
      error '更新前 sing-box 已停止，但更新过程意外启动了服务。'
      [[ -x "$old_binary" ]] && install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
      [[ -f "$old_config" ]] && install -m 600 -- "$old_config" "$SING_BOX_CONFIG"
      manager_state_set_json sing_box_version "$(jq -Rn --arg value "$old_version" '$value')" >/dev/null 2>&1 || true
      manager_state_set_json sing_box_binary_managed "$old_managed" >/dev/null 2>&1 || true
      singbox_stop >/dev/null 2>&1 || true
      rm -f -- "$old_binary" "$old_config"
      return 1
    }
    if ! singbox_check_config "$SING_BOX_CONFIG" >/dev/null; then
      error '新版 sing-box 在停止状态下未能再次通过当前配置检查，正在恢复旧版。'
      [[ -x "$old_binary" ]] && install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
      [[ -f "$old_config" ]] && install -m 600 -- "$old_config" "$SING_BOX_CONFIG"
      manager_state_set_json sing_box_version "$(jq -Rn --arg value "$old_version" '$value')" >/dev/null 2>&1 || true
      manager_state_set_json sing_box_binary_managed "$old_managed" >/dev/null 2>&1 || true
      singbox_stop >/dev/null 2>&1 || true
      rm -f -- "$old_binary" "$old_config"
      return 1
    fi
  fi
  rm -f -- "$old_binary" "$old_config"
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
  tag=$(jq -r '.tag_name // empty' <<<"$json")
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
  ensure_dir "$backup_dir" 700
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$backup_dir/$index.present" || return 1
    else
      : >"$backup_dir/$index.absent"
    fi
    index=$((index + 1))
  done < <(manager_update_service_names)
}

manager_update_restore_service_files() {
  local backup_dir=$1 name path index=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    rm -f -- "$path"
    if [[ -e "$backup_dir/$index.present" || -L "$backup_dir/$index.present" ]]; then
      cp -a -- "$backup_dir/$index.present" "$path" || return 1
    elif [[ ! -f "$backup_dir/$index.absent" ]]; then
      error "manager 更新服务备份不完整：$name"
      return 1
    fi
    index=$((index + 1))
  done < <(manager_update_service_names)
  service_manager_reload
}

manager_update_install_service_files() {
  local source destination mode
  destination=$(service_definition_path "$SING_BOX_SERVICE") || return 1
  if [[ -f "$destination" ]] && ! service_definition_is_managed "$SING_BOX_SERVICE"; then
    error "$destination 已存在且不属于 Ss2022，拒绝在更新时覆盖。"
    return 1
  fi
  if [[ ! -f "$destination" ]] && service_exists "$SING_BOX_SERVICE"; then
    error "$SING_BOX_SERVICE 来自其他系统路径，拒绝在更新时接管。"
    return 1
  fi
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    source="$PROGRAM_DIR/systemd/sing-box.service"
    mode=644
  else
    source="$PROGRAM_DIR/openrc/sing-box"
    mode=755
  fi
  [[ -f "$source" ]] || { error "manager 更新包缺少服务模板：$source"; return 1; }
  install -m "$mode" -- "$source" "$destination" || return 1
  install_manager_maintenance_service_files
}

manager_update_finalize_switched_program() {
  local version=$1 version_output
  [[ -x "$PROGRAM_DIR/ss-manager.sh" ]] || return 1
  version_output=$("$PROGRAM_DIR/ss-manager.sh" --version 2>/dev/null) || return 1
  grep -Fxq "Ss2022 manager $version" <<<"$version_output" || return 1
  manager_update_install_service_files || return 1
  manager_state_set_json manager_version "$(jq -Rn --arg value "$version" '$value')"
}

manager_update_flow() {
  acquire_manager_lock
  assert_standard_destructive_paths
  manager_update_info
  local json tag version asset_name checksum_name asset_url checksum_url asset_digest archive checksum expected actual extract_root source_entry source_root old_program new_program service_backup state_backup invalid_program
  json=$(manager_release_json 2>/dev/null || true)
  tag=$(jq -r '.tag_name // empty' <<<"$json")
  [[ -n "$tag" ]] || { warn 'Rem-nm/Codex 暂无 manager Release 或查询失败，未执行任何下载。'; return 0; }
  version=${tag#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "manager Release 标签格式无效：$tag"
  asset_name="$MANAGER_RELEASE_ASSET"
  asset_url=$(jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json" 2>/dev/null) || { warn "manager Release 没有 $asset_name。"; return 0; }
  assert_official_manager_release_url "$asset_url"
  asset_digest=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest // empty' <<<"$json")
  if [[ "$asset_digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; then
    checksum_name=''
    checksum_url=''
  else
    checksum_name=$(jq -r '.assets[].name | select(test("(?i)(sha256|checksum)"))' <<<"$json" | head -n 1 || true)
    [[ -n "$checksum_name" ]] || { warn 'manager Release 没有 SHA256 校验资产或 asset digest，已停止更新。'; return 0; }
    checksum_url=$(jq -er --arg name "$checksum_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$json")
    assert_official_manager_release_url "$checksum_url"
  fi
  prompt_yes_no "从 Rem-nm/Codex 官方 Release 更新 manager 到 $version？" n || return 0

  archive="$RUNTIME_DIR/ss-manager-$version.tar.gz"
  checksum="$RUNTIME_DIR/ss-manager-$version.SHA256SUMS"
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
    expected=$(awk -v file="$asset_name" '$2 == file || $2 == "*" file {print $1; exit}' "$checksum")
  fi
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'manager Release SHA256 校验值无效。'
  actual=$(sha256sum -- "$archive" | awk '{print $1}')
  [[ "${actual,,}" == "${expected,,}" ]] || die 'manager 下载校验失败，未替换程序。'

  extract_root="$RUNTIME_DIR/ss-manager-$version-extract.$$"
  mkdir -p -- "$extract_root"
  if tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'; then :; else die 'manager 归档包含不安全路径。'; fi
  tar -xzf "$archive" -C "$extract_root" --no-same-owner
  source_entry=$(find "$extract_root" -type f -name ss-manager.sh -print -quit)
  [[ -n "$source_entry" ]] || die 'manager 归档结构无效：缺少 ss-manager.sh。'
  source_root=$(dirname -- "$source_entry")
  [[ -n "$source_root" && -f "$source_root/VERSION" ]] || die 'manager 归档结构无效。'
  [[ -f "$source_root/lib/service.sh" && -f "$source_root/openrc/sing-box" && -f "$source_root/systemd/sing-box.service" ]] \
    || die 'manager 归档缺少服务管理模板。'
  [[ "$(tr -d '[:space:]' <"$source_root/VERSION")" == "$version" ]] || die 'manager 归档 VERSION 与 Release 标签不一致。'
  while IFS= read -r file; do bash -n "$file" || die "manager 更新包语法检查失败：$file"; done < <(find "$source_root" -type f -name '*.sh')
  while IFS= read -r file; do sh -n "$file" || die "OpenRC 模板语法检查失败：$file"; done < <(find "$source_root/openrc" -maxdepth 1 -type f -print)

  old_program="${PROGRAM_DIR}.update-old.$$"
  new_program="${PROGRAM_DIR}.update-new.$$"
  service_backup="$RUNTIME_DIR/manager-update-services.$$"
  state_backup="$RUNTIME_DIR/manager-update-state.$$.json"
  [[ -d "$PROGRAM_DIR" && -x "$PROGRAM_DIR/ss-manager.sh" ]] || die '当前 manager 程序目录无效，拒绝更新。'
  [[ ! -e "$old_program" && ! -e "$new_program" ]] || die 'manager 更新暂存目录已存在，拒绝覆盖。'
  manager_update_backup_service_files "$service_backup" || die '无法备份当前服务定义，未执行 manager 更新。'
  install -m 600 -- "$MANAGER_STATE" "$state_backup" || die '无法备份 manager 状态，未执行更新。'
  cp -a -- "$source_root" "$new_program"
  if ! mv -- "$PROGRAM_DIR" "$old_program"; then
    rm -rf -- "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    die 'manager 更新无法保存当前程序，未执行切换。'
  fi
  if ! mv -- "$new_program" "$PROGRAM_DIR"; then
    mv -- "$old_program" "$PROGRAM_DIR" || die 'manager 更新切换失败，且旧程序恢复失败。'
    rm -rf -- "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    die 'manager 更新切换失败，已恢复旧版本。'
  fi
  if ! (manager_update_finalize_switched_program "$version"); then
    error 'manager 新版本自检、服务定义或状态提交失败，正在恢复旧版本。'
    invalid_program="${PROGRAM_DIR}.update-invalid.$$"
    if ! mv -- "$PROGRAM_DIR" "$invalid_program" || ! mv -- "$old_program" "$PROGRAM_DIR"; then
      die '严重：manager 更新失败且旧程序目录无法恢复，请立即人工处理。'
    fi
    install -m 600 -- "$state_backup" "$MANAGER_STATE" || error '旧 manager 状态恢复失败。'
    if ! manager_update_restore_service_files "$service_backup"; then
      error '旧服务定义恢复失败，请立即人工处理。'
    fi
    rm -rf -- "$invalid_program" "$extract_root" "$archive" "$checksum" "$new_program" "$service_backup" "$state_backup"
    return 1
  fi
  rm -rf -- "$old_program" "$extract_root" "$archive" "$checksum" "$service_backup" "$state_backup"
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
