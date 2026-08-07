#!/usr/bin/env bash
# Node identity, validation, selection and user-facing node operations.

node_count() {
  jq '.nodes | length' "$NODES_FILE"
}

node_by_id() {
  local node_id=$1
  jq -c --arg id "$node_id" '.nodes[] | select(.node_id == $id)' "$NODES_FILE"
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
  validate_name "$requested" || return 1
  if ! node_name_exists "$requested" "$exclude_id"; then
    printf '%s' "$requested"
    return 0
  fi
  local index=2 candidate
  while true; do
    candidate="${requested}-${index}"
    if ! node_name_exists "$candidate" "$exclude_id"; then
      printf '%s' "$candidate"
      return 0
    fi
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
  local port=$1
  local pattern="(^|:)${port}$"
  ss -H -tan 2>/dev/null | awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' && return 0
  ss -H -uan 2>/dev/null | awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' && return 0
  return 1
}

port_available() {
  local port=$1
  local exclude_id=${2:-}
  validate_port "$port" || return 1
  ! node_port_in_database "$port" "$exclude_id" || return 1
  ! system_port_in_use "$port"
}

choose_port() {
  local exclude_id=${1:-}
  local choice port attempt
  while true; do
    printf '%s\n\n1. 自动随机（%s-%s）\n2. 手动输入\n' '请选择端口：' "$DEFAULT_PORT_MIN" "$DEFAULT_PORT_MAX"
    printf '> '
    IFS= read -r choice || die "读取输入失败。"
    case "$choice" in
      1)
        for attempt in $(seq 1 500); do
          port=$(shuf -i "${DEFAULT_PORT_MIN}-${DEFAULT_PORT_MAX}" -n 1)
          if port_available "$port" "$exclude_id"; then
            printf '%s' "$port"
            return 0
          fi
        done
        die "在随机范围内没有找到同时可用的 TCP/UDP 端口。"
        ;;
      2)
        printf '请输入 1-65535 的端口：\n> '
        IFS= read -r port || die "读取输入失败。"
        if ! validate_port "$port"; then
          warn "端口必须是 1-65535 的整数。"
        elif ! port_available "$port" "$exclude_id"; then
          warn "端口 $port 的 TCP 或 UDP 已被占用，或与已有节点冲突；不会覆盖。"
        else
          printf '%s' "$port"
          return 0
        fi
        ;;
      *) warn "请选择 1 或 2。" ;;
    esac
  done
}

choose_method() {
  local choice
  while true; do
    printf '%s\n\n1. 2022-blake3-aes-128-gcm\n2. 2022-blake3-aes-256-gcm（默认）\n' '请选择加密方式：'
    printf '> '
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
  local choice value detected
  while true; do
    printf '%s\n\n1. 自动检测公网 IPv4\n2. 自动检测公网 IPv6\n3. 手动输入 IP\n4. 输入域名\n' '请选择节点地址：'
    printf '> '
    IFS= read -r choice || die "读取输入失败。"
    case "$choice" in
      1)
        value=$(discover_public_ip ipv4 2>/dev/null || true)
        [[ -n "$value" ]] || { warn "没有检测到公网 IPv4，请改用手动输入。"; continue; }
        printf '%s\t%s' "$value" ipv4
        return 0
        ;;
      2)
        value=$(discover_public_ip ipv6 2>/dev/null || true)
        if [[ -z "$value" ]]; then
          warn "没有检测到公网 IPv6；请选择其他地址方式，或确认服务器/云安全组已配置 IPv6。"
          continue
        fi
        printf '%s\t%s' "$value" ipv6
        return 0
        ;;
      3)
        printf '请输入 IPv4 或 IPv6：\n> '
        IFS= read -r value || die "读取输入失败。"
        detected=$(validate_address "$value" 2>/dev/null || true)
        if [[ "$detected" == ipv4 || "$detected" == ipv6 ]]; then
          printf '%s\t%s' "$value" "$detected"
          return 0
        fi
        warn "不是有效的 IPv4/IPv6 地址。"
        ;;
      4)
        printf '请输入域名（不含协议和端口）：\n> '
        IFS= read -r value || die "读取输入失败。"
        detected=$(validate_address "$value" 2>/dev/null || true)
        if [[ "$detected" == domain ]]; then
          printf '%s\t%s' "$value" domain
          return 0
        fi
        warn "不是有效的域名。"
        ;;
      *) warn "请选择 1-4。" ;;
    esac
  done
}

generate_node_id() {
  local node_id
  while true; do
    node_id=$(openssl rand -hex 16)
    if ! node_exists "$node_id"; then
      printf '%s' "$node_id"
      return 0
    fi
  done
}

node_new_record() {
  local name=$1 method=$2 port=$3 address=$4 address_type=$5 node_id=$6 password=$7
  local now reset_at next_reset
  now=$(timestamp_iso)
  reset_at=$(timestamp_iso)
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY")
  jq -n \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg method "$method" \
    --arg password "$password" \
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
    '{node_id:$node_id,name:$name,method:$method,password:$password,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}'
}

node_add_flow() {
  acquire_manager_lock
  local requested name method port address_line address address_type node_id password record candidate traffic_candidate candidate_history
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
  record=$(node_new_record "$name" "$method" "$port" "$address" "$address_type" "$node_id" "$password")
  candidate="$RUNTIME_DIR/nodes.candidate.$$.json"
  jq --argjson record "$record" '.nodes += [$record]' "$NODES_FILE" >"$candidate"
  traffic_candidate="$RUNTIME_DIR/traffic.add.$$.json"
  candidate_history="$RUNTIME_DIR/history.add.$$.json"
  traffic_candidate_add_node "$node_id" "$DEFAULT_QUOTA_BYTES" "$DEFAULT_RESET_DAY" >"$traffic_candidate"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  apply_state_transaction "$candidate" "$traffic_candidate" "$candidate_history" "add-node-$node_id" || {
    rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"
    die "添加节点失败，当前运行配置和节点数据库已保持不变。"
  }
  rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"
  success "节点创建成功。"
  show_node_credentials "$node_id"
}

node_list_compact() {
  local index=1 node node_id name port status current_u current_d total
  printf '\n%-4s %-20s %-8s %-12s %-12s %-12s %-12s %-10s\n' '序号' '名称' '端口' '上传' '下载' '合计' '限额' '状态'
  printf '%s\n' '--------------------------------------------------------------------------------'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    name=$(jq -er '.name' <<<"$node")
    port=$(jq -er '.port' <<<"$node")
    status=$(jq -er '.status' <<<"$node")
    current_u=$(traffic_value "$node_id" '.current_upload_bytes')
    current_d=$(traffic_value "$node_id" '.current_download_bytes')
    total=$((current_u + current_d))
    local quota
    quota=$(jq -er '.quota_bytes' <<<"$node")
    local quota_text='无限'
    (( quota > 0 )) && quota_text=$(format_bytes "$quota")
    printf '%-4s %-20s %-8s %-12s %-12s %-12s %-12s %-10s\n' "$index" "$name" "$port" "$(format_bytes "$current_u")" "$(format_bytes "$current_d")" "$(format_bytes "$total")" "$quota_text" "$(status_label "$status")"
    ((index++))
  done < <(jq -c '.nodes[]' "$NODES_FILE")
  (( index > 1 )) || info '当前没有节点。'
}

select_node_id() {
  local prompt=${1:-'请选择节点序号'}
  node_list_compact
  local count index
  count=$(node_count)
  (( count > 0 )) || return 1
  while true; do
    printf '%s（0 返回）\n> ' "$prompt"
    IFS= read -r index || die "读取输入失败。"
    [[ "$index" == 0 ]] && return 1
    if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= count )); then
      jq -er --argjson index "$index" '.nodes[$index-1].node_id' "$NODES_FILE"
      return 0
    fi
    warn "请输入有效的节点序号。"
  done
}

node_show_detail() {
  local node_id=$1 node
  node=$(node_by_id "$node_id") || die "节点不存在：$node_id"
  local upload download total total_upload total_download total_all quota reset_day status
  upload=$(traffic_value "$node_id" '.current_upload_bytes')
  download=$(traffic_value "$node_id" '.current_download_bytes')
  total=$((upload + download))
  total_upload=$(traffic_value "$node_id" '.total_upload_bytes')
  total_download=$(traffic_value "$node_id" '.total_download_bytes')
  total_all=$((total_upload + total_download))
  quota=$(jq -er '.quota_bytes' <<<"$node")
  reset_day=$(jq -er '.reset_day' <<<"$node")
  status=$(jq -er '.status' <<<"$node")
  printf '\n节点：%s\nNode ID：%s\n服务器地址：%s\n端口：%s（TCP + UDP）\n加密方式：%s\n状态：%s\n' \
    "$(jq -er '.name' <<<"$node")" "$node_id" "$(jq -er '.address' <<<"$node")" "$(jq -er '.port' <<<"$node")" "$(jq -er '.method' <<<"$node")" "$(status_label "$status")"
  printf '本周期上传：%s\n本周期下载：%s\n本周期合计：%s\n' "$(format_bytes "$upload")" "$(format_bytes "$download")" "$(format_bytes "$total")"
  if (( quota == 0 )); then printf '月流量限额：无限\n'; else printf '月流量限额：%s\n剩余：%s\n' "$(format_bytes "$quota")" "$(format_bytes "$(( quota > total ? quota - total : 0 ))")"; fi
  printf '累计上传：%s\n累计下载：%s\n累计合计：%s\n' "$(format_bytes "$total_upload")" "$(format_bytes "$total_download")" "$(format_bytes "$total_all")"
  printf '重置日：每月 %s 日\n上传限速：%s\n下载限速：%s\n下次重置：%s\n' "$reset_day" "$(format_mbps "$(jq -er '.upload_limit_mbps' <<<"$node")")" "$(format_mbps "$(jq -er '.download_limit_mbps' <<<"$node")")" "$(jq -er '.next_reset_at' <<<"$node")"
}

node_view_flow() {
  local node_id
  node_id=$(select_node_id '请选择要查看的节点') || return 0
  node_show_detail "$node_id"
  if prompt_yes_no '是否显示该节点的完整密钥、链接和二维码？' n; then
    show_node_credentials "$node_id"
  fi
}
