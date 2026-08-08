#!/usr/bin/env bash
# sing-box binary lifecycle, configuration generation and health checks.

singbox_api_url_for_version() {
  local requested=${1:-}
  if [[ -z "$requested" || "$requested" == latest ]]; then
    printf 'https://api.github.com/repos/%s/releases/latest' "$SING_BOX_REPOSITORY"
  else
    requested=${requested#v}
    printf 'https://api.github.com/repos/%s/releases/tags/v%s' "$SING_BOX_REPOSITORY" "$requested"
  fi
}

fetch_singbox_release_json() {
  local requested=${1:-}
  local url
  url=$(singbox_api_url_for_version "$requested")
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' -- "$url"
}

release_asset_url() {
  local release_json=$1
  local asset_name=$2
  jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json"
}

assert_official_singbox_release_url() {
  local url=$1
  [[ "$url" == https://github.com/SagerNet/sing-box/releases/download/* ]] || die "拒绝非官方 sing-box Release 地址：$url"
}

singbox_binary_version() {
  [[ -x "$SING_BOX_BINARY" ]] || return 1
  "$SING_BOX_BINARY" version 2>/dev/null | awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+([-.].*)?$/) { print $i; exit } }'
}

backup_singbox_binary() {
  local backup_path=$1
  [[ -x "$SING_BOX_BINARY" ]] || return 0
  install -m 755 -- "$SING_BOX_BINARY" "$backup_path"
}

install_singbox_from_release() {
  require_root
  require_cmd curl jq sha256sum tar mktemp install
  [[ -n "${HOST_ARCH:-}" ]] || detect_host
  ensure_runtime_dirs

  local requested=${1:-latest}
  local previous_version previous_managed
  previous_version=$(manager_state_get sing_box_version '')
  previous_managed=$(manager_state_get sing_box_binary_managed false)
  local release_json tag version archive_name checksum_name archive_url checksum_url archive_digest
  if ! release_json=$(fetch_singbox_release_json "$requested"); then
    die '无法查询 SagerNet/sing-box 官方 Release；未修改现有安装。'
  fi
  jq -e '.tag_name and (.assets | type == "array")' >/dev/null <<<"$release_json" || die "官方 Release 响应格式异常。"
  tag=$(jq -er '.tag_name' <<<"$release_json")
  version=${tag#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "官方 Release 标签不是可接受的 sing-box 版本：$tag"
  archive_name="sing-box-${version}-linux-${HOST_ARCH}.tar.gz"
  archive_url=$(release_asset_url "$release_json" "$archive_name") || die "官方 Release 没有当前架构资产：$archive_name"
  assert_official_singbox_release_url "$archive_url"
  archive_digest=$(jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | .digest // empty' <<<"$release_json")
  if [[ "$archive_digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; then
    checksum_name=''
    checksum_url=''
  else
    checksum_name=$(jq -r '.assets[].name | select(test("(?i)(sha256|checksum)"))' <<<"$release_json" | head -n 1 || true)
    [[ -n "$checksum_name" ]] || die "官方 Release 未提供 SHA256 校验文件或资产 digest，已停止替换。"
    checksum_url=$(release_asset_url "$release_json" "$checksum_name") || die "无法取得官方校验文件地址。"
    assert_official_singbox_release_url "$checksum_url"
  fi

  local archive_file="$RUNTIME_DIR/sing-box-${version}-${HOST_ARCH}.tar.gz"
  local checksum_file="$RUNTIME_DIR/sing-box-${version}-SHA256SUMS"
  local extract_dir="$RUNTIME_DIR/sing-box-${version}-${HOST_ARCH}-extract.$$"
  # /run is commonly mounted noexec on hardened Debian hosts.  Keep the
  # candidate next to the final binary so version/configuration probes run on
  # the same executable filesystem as the installed service.
  local candidate_dir
  candidate_dir=$(dirname -- "$SING_BOX_BINARY")
  local candidate="$candidate_dir/.sing-box-${version}-${HOST_ARCH}.candidate.${BASHPID}"
  rm -rf -- "$extract_dir"
  mkdir -p -- "$extract_dir"
  info "正在下载 sing-box $version（$HOST_ARCH）……"
  if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 120 \
    --output "$archive_file" -- "$archive_url"; then
    rm -f -- "$archive_file"
    die 'sing-box 官方 Release 下载失败；未替换现有二进制。'
  fi
  local expected actual
  if [[ -n "$archive_digest" ]]; then
    expected=${archive_digest#sha256:}
  else
    if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 30 \
      --output "$checksum_file" -- "$checksum_url"; then
      rm -f -- "$archive_file" "$checksum_file"
      die 'sing-box 官方校验文件下载失败；未替换现有二进制。'
    fi
    expected=$(awk -v file="$archive_name" '$2 == file || $2 == "*" file { print $1; exit }' "$checksum_file")
  fi
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die "官方 SHA256 文件中没有 $archive_name 的有效校验值。"
  actual=$(sha256sum -- "$archive_file" | awk '{print $1}')
  [[ "${actual,,}" == "${expected,,}" ]] || die "sing-box 下载校验失败，已停止替换。"

  if tar -tzf "$archive_file" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'; then :; else
    die 'sing-box 官方归档包含不安全路径，已停止解压。'
  fi
  tar -xzf "$archive_file" -C "$extract_dir" --no-same-owner
  local extracted
  extracted=$(find "$extract_dir" -type f -name sing-box -perm -u+x -print -quit)
  [[ -n "$extracted" ]] || die "官方归档中没有可执行 sing-box。"
  install -m 755 -- "$extracted" "$candidate"
  local candidate_version
  candidate_version=$("$candidate" version 2>/dev/null | awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+([-.].*)?$/) { print $i; exit } }')
  [[ "$candidate_version" == "$version" ]] || die "下载的 sing-box 版本与 Release 标签不一致。"
  if [[ -f "$SING_BOX_CONFIG" ]]; then
    "$candidate" check -c "$SING_BOX_CONFIG" >/dev/null || die "新 sing-box 无法读取当前配置，已停止替换。"
  fi

  local old_binary="$RUNTIME_DIR/sing-box.previous"
  if [[ -x "$SING_BOX_BINARY" ]]; then
    install -m 755 -- "$SING_BOX_BINARY" "$old_binary"
  fi
  install -m 755 -- "$candidate" "$SING_BOX_BINARY"
  if [[ -f "$SING_BOX_CONFIG" ]] && ! "$SING_BOX_BINARY" check -c "$SING_BOX_CONFIG" >/dev/null 2>&1; then
    [[ -x "$old_binary" ]] && install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
    die "替换后 sing-box 配置检查失败，已恢复旧二进制。"
  fi
  if ! manager_state_set_json sing_box_version "$(jq -Rn --arg value "$version" '$value')"; then
    if [[ -x "$old_binary" ]]; then
      install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
    else
      rm -f -- "$SING_BOX_BINARY"
    fi
    manager_state_set_json sing_box_version "$(jq -Rn --arg value "$previous_version" '$value')" >/dev/null 2>&1 || true
    manager_state_set_json sing_box_binary_managed "$previous_managed" >/dev/null 2>&1 || true
    rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
    die 'sing-box 版本状态写入失败，已恢复替换前的二进制。'
  fi
  if ! manager_state_set_json sing_box_binary_managed true; then
    if [[ -x "$old_binary" ]]; then
      install -m 755 -- "$old_binary" "$SING_BOX_BINARY"
    else
      rm -f -- "$SING_BOX_BINARY"
    fi
    manager_state_set_json sing_box_version "$(jq -Rn --arg value "$previous_version" '$value')" >/dev/null 2>&1 || true
    manager_state_set_json sing_box_binary_managed "$previous_managed" >/dev/null 2>&1 || true
    rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
    die 'sing-box 管理状态写入失败，已恢复替换前的二进制。'
  fi
  rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
  success "已安装 sing-box $version（来源：SagerNet/sing-box 官方 Release）。"
}

singbox_check_config() {
  local config_file=$1
  [[ -f "$config_file" ]] || die "配置文件不存在：$config_file"
  "$SING_BOX_BINARY" check -c "$config_file"
}

singbox_config_supports_tfo() {
  local probe="$RUNTIME_DIR/tfo-probe.json"
  local password
  password=$(generate_random_key 16)
  jq -n --arg password "$password" \
    '{inbounds:[{type:"shadowsocks",tag:"ss-manager-tfo-probe",listen:"0.0.0.0",listen_port:1,method:"2022-blake3-aes-128-gcm",password:$password,tcp_fast_open:true}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' \
    >"$probe"
  if "$SING_BOX_BINARY" check -c "$probe" >/dev/null 2>&1; then
    manager_state_set_json tfo_config_supported true
    rm -f -- "$probe"
    return 0
  fi
  manager_state_set_json tfo_config_supported false
  rm -f -- "$probe"
  warn "当前 sing-box 构建不接受 TCP Fast Open 配置字段，已自动跳过该字段。"
  return 1
}

generate_singbox_config() {
  local nodes_source=$1
  local output_file=$2
  local inbounds='[]'
  local node node_id method password port address_type listener tfo_supported
  tfo_supported=$(manager_state_get tfo_config_supported false)
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    method=$(jq -er '.method' <<<"$node")
    password=$(jq -er '.password' <<<"$node")
    port=$(jq -er '.port' <<<"$node")
    address_type=$(jq -er '.address_type' <<<"$node")
    listener=$(node_listener_for_family "$address_type")
    local entry
    entry=$(jq -n \
      --arg tag "ss-${node_id}" \
      --arg listen "$listener" \
      --argjson port "$port" \
      --arg method "$method" \
      --arg password "$password" \
      --argjson tfo "$tfo_supported" \
      '({type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,method:$method,password:$password} | if $tfo then .tcp_fast_open=true else . end)')
    inbounds=$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$inbounds")
  done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")

  jq -n --argjson inbounds "$inbounds" \
    '{log:{disabled:true},inbounds:$inbounds,outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' \
    >"$output_file"
  chmod 600 -- "$output_file"
  jq -e . "$output_file" >/dev/null
}

singbox_service_unit_is_managed() {
  service_definition_is_managed "$SING_BOX_SERVICE"
}

install_singbox_service_unit() {
  local source destination mode
  destination=$(service_definition_path "$SING_BOX_SERVICE")
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    source="$PROJECT_ROOT/systemd/sing-box.service"
    mode=644
  else
    source="$PROJECT_ROOT/openrc/sing-box"
    mode=755
  fi
  [[ -f "$source" ]] || die "缺少 sing-box 服务模板：$source"
  if [[ -f "$destination" ]] && ! singbox_service_unit_is_managed; then
    die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
  fi
  if [[ ! -f "$destination" ]] && service_exists "$SING_BOX_SERVICE"; then
    warn "系统已有 $SING_BOX_SERVICE 服务，但它不在本项目管理路径下。"
    prompt_yes_no '是否明确接管该 sing-box 服务？' n || die '未接管已有 sing-box 服务，安装已安全停止。'
  fi
  install -m "$mode" -- "$source" "$destination"
  service_manager_reload
  service_enable "$SING_BOX_SERVICE" >/dev/null
}

singbox_start() {
  service_start "$SING_BOX_SERVICE"
}

singbox_stop() {
  service_stop "$SING_BOX_SERVICE"
}

singbox_restart() {
  # 当前官方文档提供的是 check/format/merge，没有可依赖的
  # 通用热 reload 命令；因此事务使用快速 restart，避免伪造 HUP 行为。
  if service_is_active "$SING_BOX_SERVICE"; then
    service_restart "$SING_BOX_SERVICE"
  else
    service_start "$SING_BOX_SERVICE"
  fi
}

singbox_is_active() {
  service_is_active "$SING_BOX_SERVICE"
}

singbox_process_pid() {
  local binary_real proc_path proc_exe
  local -a pids=()
  binary_real=$(readlink -f -- "$SING_BOX_BINARY" 2>/dev/null || true)
  [[ -n "$binary_real" ]] || return 1
  for proc_path in /proc/[0-9]*; do
    [[ -r "$proc_path/exe" ]] || continue
    proc_exe=$(readlink -f -- "$proc_path/exe" 2>/dev/null || true)
    [[ "$proc_exe" == "$binary_real" ]] || continue
    pids+=("${proc_path##*/}")
  done
  ((${#pids[@]} == 1)) || return 1
  printf '%s' "${pids[0]}"
}

port_is_listening_tcp() {
  local port=$1
  ss -H -ltn 2>/dev/null | awk -v pattern="(^|:)${port}$" '$4 ~ pattern { found=1 } END { exit !found }'
}

port_is_listening_udp() {
  local port=$1
  ss -H -lun 2>/dev/null | awk -v pattern="(^|:)${port}$" '$4 ~ pattern { found=1 } END { exit !found }'
}

singbox_health_check_once() {
  local nodes_source=${1:-$NODES_FILE}
  singbox_is_active || { error "sing-box 服务未运行。"; return 1; }
  local main_pid
  main_pid=$(singbox_process_pid) || { error "无法确认唯一的 sing-box 主进程。"; return 1; }
  [[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 0 ]] || { error "无法取得 sing-box 主进程 PID。"; return 1; }
  kill -0 "$main_pid" 2>/dev/null || { error "sing-box 主进程不存在。"; return 1; }
  singbox_check_config "$SING_BOX_CONFIG" >/dev/null || { error "当前运行配置检查失败。"; return 1; }

  local node port
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    port=$(jq -er '.port' <<<"$node")
    port_is_listening_tcp "$port" || { error "预期 TCP 端口未监听：$port"; return 1; }
    port_is_listening_udp "$port" || { error "预期 UDP 端口未监听：$port"; return 1; }
  done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  return 0
}

singbox_health_check() {
  local nodes_source=${1:-$NODES_FILE}
  local attempts=0
  while (( attempts < 10 )); do
    ((attempts += 1))
    if singbox_health_check_once "$nodes_source" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  singbox_health_check_once "$nodes_source"
}

singbox_status_summary() {
  if singbox_is_active; then
    printf '运行中'
  else
    printf '未运行'
  fi
}
