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
  url=$(singbox_api_url_for_version "$requested") || return 1
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' -- "$url"
}

release_asset_url() {
  local release_json=$1
  local asset_name=$2
  jq -er --arg name "$asset_name" '
    [.assets[]? | select(.name == $name)]
    | if length == 1 and (.[0].browser_download_url | type == "string" and length > 0)
      then .[0].browser_download_url
      else empty
      end
  ' <<<"$release_json"
}

release_asset_digest() {
  local release_json=$1
  local asset_name=$2
  jq -er --arg name "$asset_name" '
    [.assets[]? | select(.name == $name)]
    | if length == 1 then (.[0].digest // "") else empty end
  ' <<<"$release_json"
}

release_checksum_asset_name() {
  local release_json=$1
  jq -er '
    [.assets[]?.name
      | select(type == "string" and test("(sha256|checksum)"; "i"))]
    | unique
    | if length == 1 then .[0] else empty end
  ' <<<"$release_json"
}

checksum_file_digest_for_asset() {
  local checksum_file=$1 asset_name=$2
  [[ -f "$checksum_file" && ! -L "$checksum_file" && -n "$asset_name" ]] || return 1
  awk -v file="$asset_name" '
    $2 == file || $2 == "*" file {
      count++
      digest=$1
    }
    END {
      if (count != 1 || length(digest) != 64 || digest ~ /[^A-Fa-f0-9]/) exit 1
      print digest
    }
  ' "$checksum_file"
}

assert_official_singbox_release_url() {
  local url=$1
  [[ "$url" == https://github.com/SagerNet/sing-box/releases/download/* ]] || die "拒绝非官方 sing-box Release 地址：$url"
}

singbox_binary_version() {
  local output version
  [[ -f "$SING_BOX_BINARY" && ! -L "$SING_BOX_BINARY" && -x "$SING_BOX_BINARY" && -O "$SING_BOX_BINARY" ]] || return 1
  output=$("$SING_BOX_BINARY" version 2>/dev/null) || return 1
  version=$(awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+([-.].*)?$/) { print $i; exit } }' <<<"$output") \
    || return 1
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

singbox_binary_digest() {
  [[ -f "$SING_BOX_BINARY" && ! -L "$SING_BOX_BINARY" && -x "$SING_BOX_BINARY" && -O "$SING_BOX_BINARY" ]] || return 1
  local digest
  digest=$(sha256sum -- "$SING_BOX_BINARY" | awk '{print $1}') || return 1
  [[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
  printf '%s' "${digest,,}"
}

singbox_commit_binary_state() {
  local version=$1 managed=$2 digest=$3
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || return 1
  [[ "$managed" == true || "$managed" == false ]] || return 1
  [[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
  jq -e --arg version "$version" --argjson managed "$managed" --arg digest "${digest,,}" '
    .sing_box_version=$version
    | .sing_box_binary_managed=$managed
    | .sing_box_binary_sha256=$digest
  ' "$MANAGER_STATE" | atomic_json_from_stdin "$MANAGER_STATE" 600
}

validate_managed_singbox_binary_identity() {
  local managed recorded_version recorded_digest actual_version actual_digest
  managed=$(manager_state_get sing_box_binary_managed false) || return 1
  [[ "$managed" == true ]] || return 0
  recorded_version=$(manager_state_get sing_box_version '') || return 1
  recorded_digest=$(manager_state_get sing_box_binary_sha256 '') || return 1
  [[ -n "$recorded_version" && "$recorded_digest" =~ ^[A-Fa-f0-9]{64}$ ]] || {
    error 'sing-box 所有权状态缺少二进制摘要；请重新运行固定版本 install.sh 完成安全迁移。'
    return 1
  }
  actual_version=$(singbox_binary_version) || return 1
  actual_digest=$(singbox_binary_digest) || return 1
  [[ "$actual_version" == "$recorded_version" && "$actual_digest" == "${recorded_digest,,}" ]] || {
    error 'sing-box 二进制版本或 SHA256 与 manager 所有权记录不一致；拒绝把外部替换文件当作项目二进制。'
    return 1
  }
}

ensure_managed_singbox_binary_identity() {
  local managed recorded_version recorded_digest actual_version actual_digest
  managed=$(manager_state_get sing_box_binary_managed false) || return 1
  [[ "$managed" == true ]] || return 0
  recorded_version=$(manager_state_get sing_box_version '') || return 1
  [[ -n "$recorded_version" ]] || return 1
  actual_version=$(singbox_binary_version) || return 1
  [[ "$actual_version" == "$recorded_version" ]] || {
    error '现有 sing-box 版本与 manager 所有权记录不一致；拒绝迁移或信任外部替换文件。'
    return 1
  }
  actual_digest=$(singbox_binary_digest) || return 1
  recorded_digest=$(manager_state_get sing_box_binary_sha256 '') || return 1
  if [[ -z "$recorded_digest" ]]; then
    singbox_commit_binary_state "$actual_version" true "$actual_digest" || return 1
    info '已为旧版 manager 状态补齐 sing-box SHA256 所有权记录。'
    return 0
  fi
  [[ "${recorded_digest,,}" == "$actual_digest" ]] || {
    error '现有 sing-box SHA256 与 manager 所有权记录不一致；拒绝信任外部替换文件。'
    return 1
  }
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
  ensure_runtime_dirs || return 1

  local requested=${1:-latest}
  local release_json tag version archive_name checksum_name archive_url checksum_url archive_digest
  if ! release_json=$(fetch_singbox_release_json "$requested"); then
    die '无法查询 SagerNet/sing-box 官方 Release；未修改现有安装。'
  fi
  jq -e '.tag_name and (.assets | type == "array")' >/dev/null <<<"$release_json" || die "官方 Release 响应格式异常。"
  tag=$(jq -er '.tag_name | select(type == "string")' <<<"$release_json") || die '官方 Release 标签无效。'
  version=${tag#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "官方 Release 标签不是可接受的 sing-box 版本：$tag"
  archive_name="sing-box-${version}-linux-${HOST_ARCH}.tar.gz"
  archive_url=$(release_asset_url "$release_json" "$archive_name") || die "官方 Release 没有当前架构资产：$archive_name"
  assert_official_singbox_release_url "$archive_url"
  archive_digest=$(release_asset_digest "$release_json" "$archive_name") || die '官方 Release 资产不唯一或元数据无效。'
  if [[ "$archive_digest" =~ ^sha256:[A-Fa-f0-9]{64}$ ]]; then
    checksum_name=''
    checksum_url=''
  else
    checksum_name=$(release_checksum_asset_name "$release_json") \
      || die "官方 Release 未提供唯一的 SHA256 校验文件或资产 digest，已停止替换。"
    checksum_url=$(release_asset_url "$release_json" "$checksum_name") || die "无法取得官方校验文件地址。"
    assert_official_singbox_release_url "$checksum_url"
  fi

  local archive_file="$RUNTIME_DIR/sing-box-${version}-${HOST_ARCH}.$$.${RANDOM}.tar.gz"
  local checksum_file="$RUNTIME_DIR/sing-box-${version}.$$.${RANDOM}.SHA256SUMS"
  local extract_dir="$RUNTIME_DIR/sing-box-${version}-${HOST_ARCH}-extract.$$.${RANDOM}"
  local candidate_list="$RUNTIME_DIR/sing-box-candidates.$$.${RANDOM}.list"
  # /run is commonly mounted noexec on hardened Debian hosts.  Keep the
  # candidate next to the final binary so version/configuration probes run on
  # the same executable filesystem as the installed service.
  local candidate_dir
  candidate_dir=$(dirname -- "$SING_BOX_BINARY") || die '无法确定 sing-box 候选目录。'
  local candidate="$candidate_dir/.sing-box-${version}-${HOST_ARCH}.candidate.${BASHPID}.${RANDOM}"
  [[ ! -e "$archive_file" && ! -L "$archive_file" && ! -e "$checksum_file" && ! -L "$checksum_file" \
    && ! -e "$extract_dir" && ! -L "$extract_dir" && ! -e "$candidate" && ! -L "$candidate" ]] \
    || die 'sing-box 下载或安装暂存路径已存在，拒绝覆盖。'
  mkdir -m 700 -- "$extract_dir" || die '无法创建 sing-box 解压目录。'
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
    expected=$(checksum_file_digest_for_asset "$checksum_file" "$archive_name") \
      || die "官方 SHA256 文件中必须且只能包含一个 $archive_name 校验值。"
  fi
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die "官方 SHA256 文件中没有 $archive_name 的有效校验值。"
  actual=$(sha256sum -- "$archive_file" | awk '{print $1}') || die '无法计算 sing-box 下载文件摘要。'
  [[ "${actual,,}" == "${expected,,}" ]] || die "sing-box 下载校验失败，已停止替换。"

  if tar -tzf "$archive_file" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'; then :; else
    die 'sing-box 官方归档包含不安全路径，已停止解压。'
  fi
  if tar -tvzf "$archive_file" | awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {bad=1} END {exit bad}'; then :; else
    die 'sing-box 官方归档包含链接、设备或其他非普通条目，已停止解压。'
  fi
  tar -xzf "$archive_file" -C "$extract_dir" --no-same-owner --no-same-permissions || die 'sing-box 官方归档解压失败。'
  local extracted
  local -a extracted_candidates=()
  [[ ! -e "$candidate_list" && ! -L "$candidate_list" ]] || die 'sing-box 归档枚举暂存文件已存在。'
  find "$extract_dir" -type f -name sing-box -perm -u+x -print0 >"$candidate_list" \
    || { rm -f -- "$candidate_list"; die '无法枚举 sing-box 归档中的可执行文件。'; }
  while IFS= read -r -d '' extracted; do extracted_candidates+=("$extracted"); done <"$candidate_list"
  rm -f -- "$candidate_list" || die 'sing-box 归档枚举暂存文件清理失败。'
  (( ${#extracted_candidates[@]} == 1 )) || die '官方归档必须且只能包含一个可执行 sing-box。'
  extracted=${extracted_candidates[0]}
  install -m 755 -- "$extracted" "$candidate" || die '无法安装 sing-box 候选二进制。'
  local candidate_version
  candidate_version=$("$candidate" version 2>/dev/null | awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+([-.].*)?$/) { print $i; exit } }') \
    || die 'sing-box 候选二进制无法执行。'
  [[ "$candidate_version" == "$version" ]] || die "下载的 sing-box 版本与 Release 标签不一致。"
  if [[ -f "$SING_BOX_CONFIG" ]]; then
    "$candidate" check -c "$SING_BOX_CONFIG" >/dev/null || die "新 sing-box 无法读取当前配置，已停止替换。"
  fi

  local old_binary="$RUNTIME_DIR/sing-box.previous"
  if [[ -x "$SING_BOX_BINARY" ]]; then
    install -m 755 -- "$SING_BOX_BINARY" "$old_binary" || die '无法备份当前 sing-box 二进制。'
  fi
  if ! atomic_file_write "$candidate" "$SING_BOX_BINARY" 755 755; then
    rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
    die 'sing-box 二进制替换失败；版本状态保持不变。'
  fi
  if [[ -f "$SING_BOX_CONFIG" ]] && ! "$SING_BOX_BINARY" check -c "$SING_BOX_CONFIG" >/dev/null 2>&1; then
    if [[ -x "$old_binary" ]]; then
      atomic_file_write "$old_binary" "$SING_BOX_BINARY" 755 755 || die '严重：新二进制检查失败且旧 sing-box 无法恢复。'
    else
      rm -f -- "$SING_BOX_BINARY" || die '严重：无法移除无效 sing-box 二进制。'
    fi
    die "替换后 sing-box 配置检查失败，已恢复旧二进制。"
  fi
  local installed_digest
  installed_digest=$(singbox_binary_digest) || {
    if [[ -x "$old_binary" ]]; then
      atomic_file_write "$old_binary" "$SING_BOX_BINARY" 755 755 || die '严重：摘要检查失败且旧 sing-box 无法恢复。'
    else
      rm -f -- "$SING_BOX_BINARY" || die '严重：摘要检查失败且新 sing-box 无法移除。'
    fi
    rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
    die 'sing-box 安装后摘要检查失败，已恢复替换前的二进制。'
  }
  if ! singbox_commit_binary_state "$version" true "$installed_digest"; then
    if [[ -x "$old_binary" ]]; then
      atomic_file_write "$old_binary" "$SING_BOX_BINARY" 755 755 || die '严重：管理状态失败且旧 sing-box 无法恢复。'
    else
      rm -f -- "$SING_BOX_BINARY" || die '严重：管理状态失败且新 sing-box 无法移除。'
    fi
    rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary"
    die 'sing-box 版本/摘要管理状态写入失败，已恢复替换前的二进制。'
  fi
  rm -rf -- "$extract_dir" "$archive_file" "$checksum_file" "$candidate" "$old_binary" \
    || warn 'sing-box 已安装，但下载暂存文件清理不完整。'
  success "已安装 sing-box $version（来源：SagerNet/sing-box 官方 Release）。"
}

singbox_check_config() {
  local config_file=$1
  [[ -f "$config_file" ]] || die "配置文件不存在：$config_file"
  "$SING_BOX_BINARY" check -c "$config_file"
}

singbox_config_supports_tfo() {
  local probe="$RUNTIME_DIR/tfo-probe.$$.${RANDOM}.json"
  local password
  [[ ! -e "$probe" && ! -L "$probe" ]] || return 1
  password=$(generate_random_key 16) || return 1
  printf '%s' "$password" | jq -Rs \
    '. as $password | {inbounds:[{type:"shadowsocks",tag:"ss-manager-tfo-probe",listen:"0.0.0.0",listen_port:1,method:"2022-blake3-aes-128-gcm",password:$password,tcp_fast_open:true}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' \
    >"$probe" || return 1
  chmod 600 -- "$probe" || { rm -f -- "$probe"; return 1; }
  if "$SING_BOX_BINARY" check -c "$probe" >/dev/null 2>&1; then
    manager_state_set_json tfo_config_supported true || { rm -f -- "$probe"; return 1; }
    rm -f -- "$probe" || warn 'TFO 能力状态已提交，但探测配置清理失败。'
    return 0
  fi
  manager_state_set_json tfo_config_supported false || { rm -f -- "$probe"; return 1; }
  rm -f -- "$probe" || warn 'TFO 能力状态已提交，但探测配置清理失败。'
  warn "当前 sing-box 构建不接受 TCP Fast Open 配置字段，已自动跳过该字段。"
  return 0
}

generate_singbox_config() {
  local nodes_source=$1
  local output_file=$2
  local tfo_supported tfo_kernel listen_mode
  tfo_supported=$(manager_state_get tfo_config_supported false) || return 1
  tfo_kernel=$(manager_state_get tfo_kernel_enabled false) || return 1
  [[ "$tfo_supported" == true && "$tfo_kernel" == true ]] || tfo_supported=false
  listen_mode=$(manager_state_get listen_mode ipv4) || return 1
  [[ "$listen_mode" =~ ^(dual|ipv4|family-specific)$ ]] || return 1

  # Transform the protected node database directly. This keeps every node key
  # out of both shell-expanded external command arguments and process listings.
  jq -e --arg listen_mode "$listen_mode" --argjson tfo "$tfo_supported" '
    def inbound($node; $listen; $tag):
      ({
        type: "shadowsocks",
        tag: $tag,
        listen: $listen,
        listen_port: $node.port,
        method: $node.method,
        password: $node.password
      } | if $tfo then .tcp_fast_open = true else . end);
    [
      .nodes[]
      | select(.status == "enabled") as $node
      | if $listen_mode == "dual" then
          inbound($node; "::"; "ss-\($node.node_id)")
        elif $listen_mode == "ipv4" then
          inbound($node; "0.0.0.0"; "ss-\($node.node_id)")
        elif $node.address_type == "ipv4" then
          inbound($node; "0.0.0.0"; "ss-\($node.node_id)")
        elif $node.address_type == "ipv6" then
          inbound($node; "::"; "ss-\($node.node_id)")
        elif $node.address_type == "domain" then
          inbound($node; "0.0.0.0"; "ss-\($node.node_id)-ipv4"),
          inbound($node; "::"; "ss-\($node.node_id)-ipv6")
        else
          error("unsupported node address type")
        end
    ] as $inbounds
    | {log:{disabled:true},inbounds:$inbounds,outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}
  ' "$nodes_source" >"$output_file" || return 1
  chmod 600 -- "$output_file" || return 1
  jq -e . "$output_file" >/dev/null
}

singbox_config_matches_managed_state() {
  [[ -f "$SING_BOX_CONFIG" && ! -L "$SING_BOX_CONFIG" ]] || return 1
  local expected current_digest expected_digest
  expected=$(runtime_temp_file config.ownership-check) || return 1
  generate_singbox_config "$NODES_FILE" "$expected" || { rm -f -- "$expected"; return 1; }
  current_digest=$(sha256sum -- "$SING_BOX_CONFIG" | awk '{print $1}') || { rm -f -- "$expected"; return 1; }
  expected_digest=$(sha256sum -- "$expected" | awk '{print $1}') || { rm -f -- "$expected"; return 1; }
  rm -f -- "$expected" || warn '配置所有权检查已完成，但运行时探测文件清理失败。'
  [[ "$current_digest" == "$expected_digest" ]]
}

singbox_service_unit_is_managed() {
  service_definition_is_managed "$SING_BOX_SERVICE"
}

install_singbox_service_unit() {
  local source destination mode presence_status=0
  destination=$(service_definition_path "$SING_BOX_SERVICE") || return 1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    source="$PROJECT_ROOT/systemd/sing-box.service"
    mode=644
  else
    source="$PROJECT_ROOT/openrc/sing-box"
    mode=755
  fi
  [[ -f "$source" && ! -L "$source" ]] || die "缺少常规 sing-box 服务模板或模板为符号链接：$source"
  if service_definition_path_present "$SING_BOX_SERVICE" && ! singbox_service_unit_is_managed; then
    die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
  fi
  if ! service_definition_path_present "$SING_BOX_SERVICE"; then
    service_exists "$SING_BOX_SERVICE" || presence_status=$?
    (( presence_status != 2 )) || die "无法可靠查询系统是否已有 $SING_BOX_SERVICE 服务；拒绝在状态未知时接管。"
    if (( presence_status == 0 )); then
      warn "系统已有 $SING_BOX_SERVICE 服务，但它不在本项目管理路径下。"
      if [[ "${SS_MANAGER_SERVICE_TAKEOVER_APPROVED:-0}" != 1 ]]; then
        prompt_yes_no '是否明确接管该 sing-box 服务？' n || die '未接管已有 sing-box 服务，安装已安全停止。'
      fi
    fi
  fi
  atomic_file_write "$source" "$destination" "$mode" 755 || return 1
  service_manager_reload || return 1
  service_enable "$SING_BOX_SERVICE" >/dev/null || return 1
  local enabled_status=0
  service_is_enabled "$SING_BOX_SERVICE" || enabled_status=$?
  (( enabled_status == 0 )) || return 1
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
  local active_status=0
  service_is_active "$SING_BOX_SERVICE" || active_status=$?
  (( active_status != 2 )) || return 1
  if (( active_status == 0 )); then
    service_restart "$SING_BOX_SERVICE"
  else
    service_start "$SING_BOX_SERVICE"
  fi
}

singbox_is_active() {
  service_is_active "$SING_BOX_SERVICE"
}

singbox_confirm_inactive() {
  service_confirm_inactive "$SING_BOX_SERVICE"
}

singbox_process_pid() {
  local binary_real proc_path proc_exe proc_argv0
  local -a pids=()
  binary_real=$(readlink -f -- "$SING_BOX_BINARY" 2>/dev/null || true)
  [[ -n "$binary_real" ]] || return 1
  for proc_path in /proc/[0-9]*; do
    [[ -r "$proc_path/exe" ]] || continue
    proc_exe=$(readlink -f -- "$proc_path/exe" 2>/dev/null || true)
    # On musl systems, gcompat executes the glibc sing-box release through
    # the musl loader, so /proc/<pid>/exe resolves to ld-musl rather than the
    # configured binary.  The supervised process still exposes its absolute
    # executable path as argv[0]; use it as a second, exact identity check.
    proc_argv0=$(tr '\0' '\n' <"$proc_path/cmdline" 2>/dev/null | head -n 1 || true)
    [[ "$proc_exe" == "$binary_real" || "$proc_argv0" == "$binary_real" ]] || continue
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

port_listener_owned_by_pid() {
  local protocol=$1 port=$2 pid=$3 family=${4:-any} output
  validate_port "$port" || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  local -a args=(-H -l -n -p)
  case "$protocol" in tcp) args+=(-t) ;; udp) args+=(-u) ;; *) return 1 ;; esac
  case "$family" in ipv4) args+=(-4) ;; ipv6) args+=(-6) ;; any) ;; *) return 1 ;; esac
  output=$(ss "${args[@]}" 2>/dev/null) || return 1
  awk -v pattern="(^|:)${port}$" -v owner="pid=${pid}," '
    $4 ~ pattern {
      found=1
      if (index($0, owner) == 0) foreign=1
    }
    END { exit !(found && !foreign) }
  ' <<<"$output"
}

singbox_owns_node_port() {
  local port=$1 pid=${2:-}
  [[ -n "$pid" ]] || pid=$(singbox_process_pid) || return 1
  port_listener_owned_by_pid tcp "$port" "$pid" any \
    && port_listener_owned_by_pid udp "$port" "$pid" any
}

singbox_health_check_once() {
  local nodes_source=${1:-$NODES_FILE}
  singbox_is_active || { error "sing-box 服务未运行。"; return 1; }
  local main_pid
  main_pid=$(singbox_process_pid) || { error "无法确认唯一的 sing-box 主进程。"; return 1; }
  [[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 0 ]] || { error "无法取得 sing-box 主进程 PID。"; return 1; }
  kill -0 "$main_pid" 2>/dev/null || { error "sing-box 主进程不存在。"; return 1; }
  singbox_check_config "$SING_BOX_CONFIG" >/dev/null || { error "当前运行配置检查失败。"; return 1; }

  local node port address_type listener family node_lines listeners
  node_lines=$(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    port=$(jq -er '.port' <<<"$node") || return 1
    address_type=$(jq -er '.address_type' <<<"$node") || return 1
    listeners=$(node_listeners_for_family "$address_type") || return 1
    while IFS= read -r listener; do
      [[ -n "$listener" ]] || continue
      [[ "$listener" == '::' ]] && family=ipv6 || family=ipv4
      port_listener_owned_by_pid tcp "$port" "$main_pid" "$family" \
        || { error "预期 $family TCP 端口未由 sing-box 监听：$port"; return 1; }
      port_listener_owned_by_pid udp "$port" "$main_pid" "$family" \
        || { error "预期 $family UDP 端口未由 sing-box 监听：$port"; return 1; }
    done <<<"$listeners"
  done <<<"$node_lines"
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
  local active_status=0
  singbox_is_active || active_status=$?
  case "$active_status" in
    0) printf '运行中' ;;
    1) printf '未运行' ;;
    *) printf '状态查询失败' ;;
  esac
}
