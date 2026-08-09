#!/usr/bin/env bash
# Node identity, validation, selection and user-facing node operations.

node_count() {
  jq '.nodes | length' "$NODES_FILE"
}

node_by_id() {
  local node_id=$1
  jq -ce --arg id "$node_id" '[.nodes[] | select(.node_id == $id)] | if length == 1 then .[0] else empty end' "$NODES_FILE"
}

node_exists() {
  local node_id=$1
  jq -e --arg id "$node_id" 'any(.nodes[]; .node_id == $id)' "$NODES_FILE" >/dev/null
}

node_name_exists() {
  local name=$1
  local exclude_id=${2:-}
  jq -e --arg name "$name" --arg exclude "$exclude_id" \
    'any(.nodes[]; (.name | ascii_downcase) == ($name | ascii_downcase) and .node_id != $exclude)' "$NODES_FILE" >/dev/null
}

unique_node_name() {
  local requested=$1
  local exclude_id=${2:-}
  local exists_status=0
  validate_name "$requested" || return 1
  node_name_exists "$requested" "$exclude_id" || exists_status=$?
  if (( exists_status == 1 )); then
    printf '%s' "$requested"
    return 0
  fi
  (( exists_status == 0 )) || return 1
  local index=2 candidate suffix prefix_length
  while true; do
    suffix="-${index}"
    prefix_length=$((64 - ${#suffix}))
    (( prefix_length > 0 )) || return 1
    candidate="${requested:0:prefix_length}${suffix}"
    validate_name "$candidate" || return 1
    exists_status=0
    node_name_exists "$candidate" "$exclude_id" || exists_status=$?
    if (( exists_status == 1 )); then
      printf '%s' "$candidate"
      return 0
    fi
    (( exists_status == 0 )) || return 1
    ((index++))
  done
}

node_port_in_database() {
  local port=$1
  local exclude_id=${2:-}
  jq -e --argjson port "$port" --arg exclude "$exclude_id" \
    'any(.nodes[]; .port == $port and .node_id != $exclude)' "$NODES_FILE" >/dev/null
}

system_port_in_use() {
  local port=$1 tcp_listeners udp_listeners
  local pattern="(^|:)${port}$"
  tcp_listeners=$(ss -H -ltn 2>/dev/null) || return 2
  udp_listeners=$(ss -H -lun 2>/dev/null) || return 2
  awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' <<<"$tcp_listeners" && return 0
  awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' <<<"$udp_listeners" && return 0
  return 1
}

port_available() {
  local port=$1
  local exclude_id=${2:-}
  local database_status=0
  validate_port "$port" || return 1
  node_port_in_database "$port" "$exclude_id" || database_status=$?
  (( database_status == 1 )) || {
    (( database_status == 0 )) && return 1
    return 2
  }
  local port_state=0
  system_port_in_use "$port" || port_state=$?
  (( port_state != 2 )) || return 2
  if (( port_state == 0 )); then
    # While editing an enabled node, its unchanged live port is expected to
    # be occupied by sing-box.  Every other occupied port remains forbidden.
    [[ -n "$exclude_id" ]] || return 1
    local live_port live_status
    live_port=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | .port' "$NODES_FILE") || return 2
    live_status=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | .status' "$NODES_FILE") || return 2
    [[ "$live_status" == enabled && "$live_port" == "$port" ]] || return 1
    singbox_is_active || return 1
    singbox_owns_node_port "$port" || return 1
  fi
  return 0
}

# Called without an argument for new nodes and with an excluded Node ID while
# editing; ShellCheck cannot see the latter across separately sourced modules.
# shellcheck disable=SC2120
choose_port() {
  local exclude_id=${1:-}
  local port attempt availability_status
  while true; do
    printf '请输入端口（回车随机，范围 %s-%s）：\n> ' "$DEFAULT_PORT_MIN" "$DEFAULT_PORT_MAX" >&2
    IFS= read -r port || die "读取输入失败。"
    port=$(trim_spaces "$port")
    if [[ -z "$port" ]]; then
      for ((attempt=1; attempt<=500; attempt++)); do
        port=$(shuf -i "${DEFAULT_PORT_MIN}-${DEFAULT_PORT_MAX}" -n 1)
        if port_available "$port" "$exclude_id"; then
          printf '%s' "$port"
          return 0
        else
          availability_status=$?
          (( availability_status != 2 )) || die '无法可靠查询系统 TCP/UDP 监听端口，已停止选择端口。'
        fi
      done
      die "在随机范围内没有找到同时可用的 TCP/UDP 端口。"
    fi
    if ! validate_port "$port"; then
      warn "端口必须是 1-65535 的整数；直接回车可随机选择。"
    elif port_available "$port" "$exclude_id"; then
      printf '%s' "$port"
      return 0
    else
      availability_status=$?
      (( availability_status != 2 )) || die '无法可靠查询系统 TCP/UDP 监听端口，已停止选择端口。'
      warn "端口 $port 的 TCP 或 UDP 已被占用，或与已有节点冲突；不会覆盖。"
    fi
  done
}

choose_method() {
  local choice
  while true; do
    printf '%s\n\n1. 2022-blake3-aes-128-gcm\n2. 2022-blake3-aes-256-gcm（默认）\n' '请选择加密方式：' >&2
    printf '> ' >&2
    IFS= read -r choice || die "读取输入失败。"
    [[ -z "$choice" ]] && choice=2
    case "$choice" in
      1) printf '2022-blake3-aes-128-gcm'; return 0 ;;
      2) printf '2022-blake3-aes-256-gcm'; return 0 ;;
      *) warn "请选择 1 或 2。" ;;
    esac
  done
}

choose_address() {
  local value detected
  while true; do
    printf '请输入节点地址（回车自动检测，优先 IPv4、失败后 IPv6；也可直接输入 IP/域名）：\n> ' >&2
    IFS= read -r value || die "读取输入失败。"
    value=$(trim_spaces "$value")
    if [[ -z "$value" || "$value" == auto ]]; then
      detected=ipv4
      value=$(discover_public_ip ipv4 2>/dev/null || true)
      if [[ -z "$value" ]]; then
        detected=ipv6
        value=$(discover_public_ip ipv6 2>/dev/null || true)
      fi
      [[ -n "$value" ]] || { warn "没有检测到公网 IPv4/IPv6，请直接输入 IP 或域名。"; continue; }
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    if [[ "$value" == ipv4 ]]; then
      detected=ipv4
      value=$(discover_public_ip ipv4 2>/dev/null || true)
      [[ -n "$value" ]] || { warn "没有检测到公网 IPv4，请直接输入 IP 或域名。"; continue; }
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    if [[ "$value" == ipv6 || "$value" == auto6 ]]; then
      detected=ipv6
      value=$(discover_public_ip ipv6 2>/dev/null || true)
      if [[ -z "$value" ]]; then
        warn "没有检测到公网 IPv6；请直接输入 IPv6、IPv4 或域名。"
        continue
      fi
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    detected=$(validate_address "$value" 2>/dev/null || true)
    if [[ "$detected" == ipv4 || "$detected" == ipv6 || "$detected" == domain ]]; then
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    warn "不是有效的 IPv4、IPv6 或域名。"
  done
}

generate_node_id() {
  local node_id exists_status
  while true; do
    node_id=$(openssl rand -hex 16) || return 1
    exists_status=0
    node_exists "$node_id" || exists_status=$?
    if (( exists_status == 1 )); then
      printf '%s' "$node_id"
      return 0
    fi
    (( exists_status == 0 )) || return 1
  done
}

node_new_record() {
  local name=$1 method=$2 port=$3 address=$4 address_type=$5 node_id=$6 password=$7
  local now reset_at next_reset
  now=$(timestamp_iso) || return 1
  reset_at=$(timestamp_iso) || return 1
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY") || return 1
  # Feed the key through stdin instead of exposing it in jq's argv.
  printf '%s' "$password" | jq -Rs \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg method "$method" \
    --arg address "$address" \
    --arg address_type "$address_type" \
    --arg now "$now" \
    --arg reset_at "$reset_at" \
    --arg next_reset "$next_reset" \
    --argjson port "$port" \
    --argjson quota "$DEFAULT_QUOTA_BYTES" \
    --argjson reset_day "$DEFAULT_RESET_DAY" \
    --argjson upload_limit "$DEFAULT_UPLOAD_LIMIT_MBPS" \
    --argjson download_limit "$DEFAULT_DOWNLOAD_LIMIT_MBPS" \
    '. as $password | {node_id:$node_id,name:$name,method:$method,password:$password,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}'
}

node_add_flow() {
  acquire_manager_lock
  local requested name method port address_line address address_type node_id password record_file candidate traffic_candidate candidate_history
  requested=$(read_nonempty '请输入节点名称：')
  validate_name "$requested" || die "节点名称包含控制字符、路径字符或超过 64 个字符。"
  name=$(unique_node_name "$requested") || die "无法生成唯一节点名称。"
  [[ "$name" == "$requested" ]] || info "名称已存在，自动使用：$name"
  method=$(choose_method)
  port=$(choose_port)
  address_line=$(choose_address)
  address=${address_line%$'\t'*}
  address_type=${address_line##*$'\t'}
  node_id=$(generate_node_id)
  password=$(generate_random_key "$(method_key_bytes "$method")")
  record_file=$(runtime_temp_file node-record) || die '无法创建节点记录暂存文件。'
  node_new_record "$name" "$method" "$port" "$address" "$address_type" "$node_id" "$password" >"$record_file" \
    || { rm -f -- "$record_file"; die '无法创建节点记录。'; }
  chmod 600 -- "$record_file" || { rm -f -- "$record_file"; die '无法保护节点记录暂存文件。'; }
  candidate=$(runtime_temp_file nodes.candidate) || { rm -f -- "$record_file"; die '无法创建节点候选暂存文件。'; }
  jq --slurpfile record "$record_file" '.nodes += [$record[0]]' "$NODES_FILE" >"$candidate" \
    || { rm -f -- "$record_file" "$candidate"; die '无法生成节点候选数据库。'; }
  rm -f -- "$record_file" || { rm -f -- "$candidate"; die '无法清理节点密钥暂存文件。'; }
  traffic_candidate=$(runtime_temp_file traffic.add) || { rm -f -- "$candidate"; die '无法创建流量候选暂存文件。'; }
  candidate_history=$(runtime_temp_file history.add) || { rm -f -- "$candidate" "$traffic_candidate"; die '无法创建历史候选暂存文件。'; }
  traffic_candidate_add_node "$node_id" "$DEFAULT_QUOTA_BYTES" "$DEFAULT_RESET_DAY" >"$traffic_candidate" \
    || { rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"; die '无法生成新节点流量状态。'; }
  install -m 600 -- "$HISTORY_FILE" "$candidate_history" \
    || { rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"; die '无法复制流量历史候选状态。'; }
  apply_state_transaction "$candidate" "$traffic_candidate" "$candidate_history" "add-node-$node_id" || {
    rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"
    die "添加节点失败，当前运行配置和节点数据库已保持不变。"
  }
  rm -f -- "$candidate" "$traffic_candidate" "$candidate_history" \
    || warn '节点已经创建，但运行时候选文件清理失败。'
  success "节点创建成功。"
  show_node_credentials "$node_id" || warn '节点已经创建，但凭据展示未完整完成；可稍后从菜单重新显示。'
}

node_list_compact() {
  local index=1 node node_id name port status current_u current_d total node_lines
  local quota quota_text upload_text download_text total_text status_text
  printf '\n%-4s %-20s %-8s %-12s %-12s %-12s %-12s %-10s\n' '序号' '名称' '端口' '上传' '下载' '合计' '限额' '状态'
  printf '%s\n' '--------------------------------------------------------------------------------'
  node_lines=$(jq -c '.nodes[]' "$NODES_FILE") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    name=$(jq -er '.name' <<<"$node") || return 1
    port=$(jq -er '.port' <<<"$node") || return 1
    status=$(jq -er '.status' <<<"$node") || return 1
    current_u=$(traffic_value "$node_id" '.current_upload_bytes') || return 1
    current_d=$(traffic_value "$node_id" '.current_download_bytes') || return 1
    total=$((current_u + current_d))
    quota=$(jq -er '.quota_bytes' <<<"$node") || return 1
    quota_text='无限'
    if (( quota > 0 )); then
      quota_text=$(format_bytes "$quota") || return 1
    fi
    upload_text=$(format_bytes "$current_u") || return 1
    download_text=$(format_bytes "$current_d") || return 1
    total_text=$(format_bytes "$total") || return 1
    status_text=$(status_label "$status") || return 1
    printf '%-4s %-20s %-8s %-12s %-12s %-12s %-12s %-10s\n' "$index" "$name" "$port" "$upload_text" "$download_text" "$total_text" "$quota_text" "$status_text"
    ((index++))
  done <<<"$node_lines"
  (( index > 1 )) || info '当前没有节点。'
}

select_node_id() {
  local prompt=${1:-'请选择节点序号'}
  # This function is normally called through command substitution; the list
  # and prompt are UI output, not the selected Node ID.
  node_list_compact >&2 || return 2
  local count index
  count=$(node_count) || return 2
  (( count > 0 )) || return 1
  while true; do
    printf '%s（0 返回）\n> ' "$prompt" >&2
    IFS= read -r index || return 2
    [[ "$index" == 0 ]] && return 1
    if [[ "$index" =~ ^[1-9][0-9]*$ ]] && (( index >= 1 && index <= count )); then
      jq -er --argjson index "$index" '.nodes[$index-1].node_id' "$NODES_FILE" || return 2
      return 0
    fi
    warn "请输入有效的节点序号。"
  done
}

select_node_for_flow() {
  local output_variable=$1 prompt=$2 selected='' select_status=0
  selected=$(select_node_id "$prompt") || select_status=$?
  if (( select_status == 0 )); then
    printf -v "$output_variable" '%s' "$selected"
    return 0
  fi
  (( select_status == 1 )) && return 1
  die '无法可靠读取或显示节点数据库，操作已停止。'
}

node_show_detail() {
  local node_id=$1 node
  node=$(node_by_id "$node_id") || die "节点不存在：$node_id"
  local upload download total total_upload total_download total_all quota reset_day status billable
  local name address port method upload_limit download_limit next_reset status_text
  local upload_text download_text total_text total_upload_text total_download_text total_all_text
  upload=$(traffic_value "$node_id" '.current_upload_bytes') || die '无法读取节点上传流量。'
  download=$(traffic_value "$node_id" '.current_download_bytes') || die '无法读取节点下载流量。'
  total=$((upload + download))
  billable=$(quota_billable_bytes "$upload" "$download") || die '配额计数超出安全整数范围。'
  total_upload=$(traffic_value "$node_id" '.total_upload_bytes') || die '无法读取节点累计上传流量。'
  total_download=$(traffic_value "$node_id" '.total_download_bytes') || die '无法读取节点累计下载流量。'
  total_all=$((total_upload + total_download))
  quota=$(jq -er '.quota_bytes' <<<"$node") || die '节点限额字段无效。'
  reset_day=$(jq -er '.reset_day' <<<"$node") || die '节点重置日字段无效。'
  status=$(jq -er '.status' <<<"$node") || die '节点状态字段无效。'
  name=$(jq -er '.name' <<<"$node") || die '节点名称字段无效。'
  address=$(jq -er '.address' <<<"$node") || die '节点地址字段无效。'
  port=$(jq -er '.port' <<<"$node") || die '节点端口字段无效。'
  method=$(jq -er '.method' <<<"$node") || die '节点加密方式字段无效。'
  upload_limit=$(jq -er '.upload_limit_mbps' <<<"$node") || die '节点上传限速字段无效。'
  download_limit=$(jq -er '.download_limit_mbps' <<<"$node") || die '节点下载限速字段无效。'
  next_reset=$(jq -er '.next_reset_at' <<<"$node") || die '节点下次重置时间无效。'
  status_text=$(status_label "$status") || die '无法格式化节点状态。'
  upload_text=$(format_bytes "$upload") || die '无法格式化上传流量。'
  download_text=$(format_bytes "$download") || die '无法格式化下载流量。'
  total_text=$(format_bytes "$total") || die '无法格式化本周期流量。'
  total_upload_text=$(format_bytes "$total_upload") || die '无法格式化累计上传流量。'
  total_download_text=$(format_bytes "$total_download") || die '无法格式化累计下载流量。'
  total_all_text=$(format_bytes "$total_all") || die '无法格式化累计流量。'
  printf '\n节点：%s\nNode ID：%s\n服务器地址：%s\n端口：%s（TCP + UDP）\n加密方式：%s\n状态：%s\n' \
    "$name" "$node_id" "$address" "$port" "$method" "$status_text"
  printf '本周期上传：%s\n本周期下载：%s\n本周期合计：%s\n' "$upload_text" "$download_text" "$total_text"
  if (( quota == 0 )); then
    printf '月流量限额：无限（自动停用默认按下载计费；上传为端口层观测值）\n'
  else
    printf '月流量限额：%s\n计费流量：%s（默认仅下载；降低但不能消除未认证流量影响）\n剩余：%s\n' \
      "$(format_bytes "$quota")" "$(format_bytes "$billable")" "$(format_bytes "$(( quota > billable ? quota - billable : 0 ))")"
  fi
  printf '累计上传：%s\n累计下载：%s\n累计合计：%s\n' "$total_upload_text" "$total_download_text" "$total_all_text"
  printf '重置日：每月 %s 日\n上传限速：%s\n下载限速：%s\n下次重置：%s\n' "$reset_day" "$(format_mbps "$upload_limit")" "$(format_mbps "$download_limit")" "$next_reset"
}

node_view_flow() {
  local node_id
  select_node_for_flow node_id '请选择要查看的节点' || return 0
  node_show_detail "$node_id"
  if prompt_yes_no '是否显示该节点的完整密钥、链接和二维码？' n; then
    show_node_credentials "$node_id"
  fi
}
