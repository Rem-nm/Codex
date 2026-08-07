#!/usr/bin/env bash
# Configuration snapshots and transactional state changes.

validate_candidate_nodes() {
  local nodes_source=$1
  jq -e '.schema_version == 1 and (.nodes | type == "array")' "$nodes_source" >/dev/null || die "候选节点数据库结构无效。"
  local node node_id name method password port address address_type status quota reset_day upload_limit download_limit
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    name=$(jq -er '.name' <<<"$node")
    method=$(jq -er '.method' <<<"$node")
    password=$(jq -er '.password' <<<"$node")
    port=$(jq -er '.port' <<<"$node")
    address=$(jq -er '.address' <<<"$node")
    address_type=$(jq -er '.address_type' <<<"$node")
    status=$(jq -er '.status' <<<"$node")
    quota=$(jq -er '.quota_bytes' <<<"$node")
    reset_day=$(jq -er '.reset_day' <<<"$node")
    upload_limit=$(jq -er '.upload_limit_mbps' <<<"$node")
    download_limit=$(jq -er '.download_limit_mbps' <<<"$node")
    [[ "$node_id" =~ ^[a-f0-9]{32}$ ]] || die "候选节点 Node ID 无效。"
    validate_name "$name" || die "候选节点名称无效：$name"
    validate_method "$method" || die "候选节点加密方式无效：$method"
    validate_base64_key "$password" "$(method_key_bytes "$method")" || die "候选节点密钥格式/长度无效。"
    validate_port "$port" || die "候选节点端口无效：$port"
    validate_address "$address" >/dev/null || die "候选节点地址无效：$address"
    [[ "$address_type" == ipv4 || "$address_type" == ipv6 || "$address_type" == domain ]] || die "候选节点地址类型无效。"
    [[ "$status" == enabled || "$status" == disabled_manual || "$status" == disabled_quota || "$status" == disabled_error ]] || die "候选节点状态无效。"
    [[ "$quota" =~ ^[0-9]+$ ]] || die "候选节点配额无效。"
    validate_reset_day "$reset_day" || die "候选节点重置日无效。"
    validate_limit_mbps "$upload_limit" || die "候选节点上传限速无效。"
    validate_limit_mbps "$download_limit" || die "候选节点下载限速无效。"
  done < <(jq -c '.nodes[]' "$nodes_source")

  jq -e '([.nodes[].node_id] | length == (unique | length))' "$nodes_source" >/dev/null || die '候选节点存在重复 Node ID。'
  jq -e '([.nodes[] | (.name | ascii_downcase)] | length == (unique | length))' "$nodes_source" >/dev/null || die '候选节点名称必须唯一。'
  jq -e '([.nodes[].port] | length == (unique | length))' "$nodes_source" >/dev/null || die '候选节点端口必须唯一。'

  local current_node current_id current_port current_status
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    current_id=$(jq -er '.node_id' <<<"$node")
    current_port=$(jq -er '.port' <<<"$node")
    if system_port_in_use "$current_port"; then
      current_status=$(jq -r --arg id "$current_id" '.nodes[] | select(.node_id == $id) | .status' "$NODES_FILE")
      if [[ "$current_status" != enabled ]]; then
        die "候选端口 $current_port 已被系统其他服务占用。"
      fi
    fi
  done < <(jq -c '.nodes[]' "$nodes_source")
}

backup_create_snapshot() {
  local reason=$1
  local backup_path="$BACKUP_DIR/$(timestamp_compact)-$reason"
  local suffix=1
  while [[ -e "$backup_path" ]]; do
    backup_path="$BACKUP_DIR/$(timestamp_compact)-$reason-$suffix"
    ((suffix++))
  done
  ensure_dir "$backup_path" 700
  [[ -f "$NODES_FILE" ]] && install -m 600 -- "$NODES_FILE" "$backup_path/nodes.json"
  [[ -f "$TRAFFIC_FILE" ]] && install -m 600 -- "$TRAFFIC_FILE" "$backup_path/traffic.json"
  [[ -f "$HISTORY_FILE" ]] && install -m 600 -- "$HISTORY_FILE" "$backup_path/traffic-history.json"
  [[ -f "$SING_BOX_CONFIG" ]] && install -m 600 -- "$SING_BOX_CONFIG" "$backup_path/config.json"
  if [[ -x "$SING_BOX_BINARY" ]]; then
    install -m 755 -- "$SING_BOX_BINARY" "$backup_path/sing-box"
  fi
  jq -n \
    --arg reason "$reason" \
    --arg created_at "$(timestamp_iso)" \
    --arg manager_version "$MANAGER_VERSION" \
    --arg sing_box_version "$(singbox_binary_version 2>/dev/null || true)" \
    '{reason:$reason,created_at:$created_at,manager_version:$manager_version,sing_box_version:$sing_box_version}' \
    >"$backup_path/metadata.json"
  chmod 600 -- "$backup_path"/*
  printf '%s' "$backup_path"
}

backup_prune() {
  local -a backups=()
  mapfile -t backups < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  local count=${#backups[@]}
  local remove_count=$((count - DEFAULT_CONFIG_BACKUP_RETENTION))
  local index target
  (( remove_count > 0 )) || return 0
  for ((index=0; index<remove_count; index++)); do
    target="$BACKUP_DIR/${backups[$index]}"
    [[ "$target" == "$BACKUP_DIR/"* && "$target" != "$BACKUP_DIR/" ]] || die '备份清理目标不安全。'
    rm -rf -- "$target"
  done
}

restore_runtime_and_state() {
  local old_nodes=$1 old_traffic=$2 old_history=$3 old_config=$4
  if [[ -f "$old_nodes" ]]; then install -m 600 -- "$old_nodes" "$NODES_FILE"; fi
  if [[ -f "$old_traffic" ]]; then install -m 600 -- "$old_traffic" "$TRAFFIC_FILE"; fi
  if [[ -f "$old_history" ]]; then install -m 600 -- "$old_history" "$HISTORY_FILE"; fi
  if [[ -f "$old_config" ]]; then
    install -m 600 -- "$old_config" "$SING_BOX_CONFIG"
  else
    rm -f -- "$SING_BOX_CONFIG"
  fi
  if systemctl is-enabled --quiet "$SING_BOX_SERVICE" 2>/dev/null || systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null; then
    systemctl restart "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
  fi
  bandwidth_apply_nodes "$NODES_FILE" >/dev/null 2>&1 || true
  traffic_reset_kernel_baselines "$NODES_FILE" >/dev/null 2>&1 || true
}

apply_state_transaction() {
  local candidate_nodes=$1
  local candidate_traffic=$2
  local candidate_history=$3
  local reason=$4
  local collect_traffic=${5:-1}
  ensure_runtime_dirs
  initialize_state_files
  local merged_traffic=''
  if [[ "$collect_traffic" == 1 ]]; then
    traffic_collect_no_lock
    merged_traffic="$RUNTIME_DIR/traffic.txn-merge.$$.json"
    jq --slurpfile live "$TRAFFIC_FILE" '
      .nodes |= with_entries(
        .key as $id
        | if ($live[0].nodes[$id] // null) == null then .
          else
            .value.current_upload_bytes = ($live[0].nodes[$id].current_upload_bytes // 0)
            | .value.current_download_bytes = ($live[0].nodes[$id].current_download_bytes // 0)
            | .value.total_upload_bytes = ($live[0].nodes[$id].total_upload_bytes // 0)
            | .value.total_download_bytes = ($live[0].nodes[$id].total_download_bytes // 0)
          end
      )
    ' "$candidate_traffic" >"$merged_traffic"
    candidate_traffic="$merged_traffic"
  fi
  validate_candidate_nodes "$candidate_nodes"
  jq -e '.schema_version == 1 and (.nodes | type == "object")' "$candidate_traffic" >/dev/null || die '候选流量数据库结构无效。'
  jq -e '.schema_version == 1 and (.cycles | type == "object")' "$candidate_history" >/dev/null || die '候选流量历史结构无效。'

  local candidate_config="$RUNTIME_DIR/config.candidate.$$.json"
  local old_nodes="$RUNTIME_DIR/nodes.previous.$$.json"
  local old_traffic="$RUNTIME_DIR/traffic.previous.$$.json"
  local old_history="$RUNTIME_DIR/history.previous.$$.json"
  local old_config="$RUNTIME_DIR/config.previous.$$.json"
  generate_singbox_config "$candidate_nodes" "$candidate_config"
  if ! singbox_check_config "$candidate_config" >/dev/null 2>&1; then
    error '新配置未通过 sing-box 官方配置检查；未重启服务，也未修改节点数据库。'
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  install -m 600 -- "$NODES_FILE" "$old_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$old_traffic"
  install -m 600 -- "$HISTORY_FILE" "$old_history"
  [[ -f "$SING_BOX_CONFIG" ]] && install -m 600 -- "$SING_BOX_CONFIG" "$old_config"
  local backup_path
  backup_path=$(backup_create_snapshot "$reason")

  install -m 600 -- "$candidate_config" "$SING_BOX_CONFIG"
  if ! singbox_restart; then
    error 'sing-box 重启失败，正在恢复上一版本配置。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi
  if ! singbox_health_check "$candidate_nodes"; then
    error '新配置健康检查失败，正在恢复上一版本配置。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    if ! singbox_health_check "$old_nodes" >/dev/null 2>&1; then
      error '严重：旧配置恢复后健康检查也失败，请立即检查 systemctl status sing-box。'
    fi
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi

  if ! bandwidth_apply_and_check "$candidate_nodes"; then
    error '新 tc 流控规则应用/检查失败，正在恢复上一版本配置和规则。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    if ! singbox_health_check "$old_nodes" >/dev/null 2>&1; then
      error '严重：流控回滚后旧配置健康检查失败，请立即检查服务。'
    fi
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi

  # tc rules are recreated during every transaction, so their byte counters
  # start from zero. Reset persisted baselines to prevent the next sample
  # from comparing a new port/rule counter with an old one.
  if ! traffic_reset_kernel_baselines "$candidate_nodes"; then
    error '新的 tc 计数基线无法保存，正在恢复上一版本配置和规则。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi

  if ! atomic_json_write "$candidate_nodes" "$NODES_FILE" 600 \
    || ! atomic_json_write "$candidate_traffic" "$TRAFFIC_FILE" 600 \
    || ! atomic_json_write "$candidate_history" "$HISTORY_FILE" 600; then
    error '节点数据库提交失败，正在回滚运行配置和数据。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi

  if ! singbox_health_check "$NODES_FILE"; then
    error '提交后最终健康检查失败，正在回滚上一版本。'
    restore_runtime_and_state "$old_nodes" "$old_traffic" "$old_history" "$old_config"
    if ! singbox_health_check "$old_nodes" >/dev/null 2>&1; then
      error '严重：最终回滚后的旧配置健康检查失败，请立即人工处理。'
    fi
    rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
    return 1
  fi

  backup_prune
  rm -f -- "$candidate_config" "$old_nodes" "$old_traffic" "$old_history" "$old_config" "$merged_traffic"
  success "配置事务已提交，备份：$backup_path"
  return 0
}

backup_list() {
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

backup_restore_flow() {
  acquire_manager_lock
  local -a backups=()
  mapfile -t backups < <(backup_list)
  ((${#backups[@]} > 0)) || { info '暂无可恢复备份。'; return 0; }
  local index=1 item
  printf '\n可恢复备份：\n'
  for item in "${backups[@]}"; do printf '%s. %s\n' "$index" "$item"; ((index++)); done
  local choice
  printf '请选择备份序号（0 返回）：\n> '
  IFS= read -r choice || die '读取输入失败。'
  [[ "$choice" == 0 ]] && return 0
  [[ "$choice" =~ ^[0-9]+$ && choice -ge 1 && choice -le ${#backups[@]} ]] || die '无效的备份序号。'
  local selected="$BACKUP_DIR/${backups[$((choice-1))]}"
  [[ -f "$selected/nodes.json" && -f "$selected/traffic.json" && -f "$selected/traffic-history.json" ]] || die '备份缺少必要数据文件。'
  prompt_yes_no "确认恢复备份 ${backups[$((choice-1))]}？当前状态会先自动再备份" n || return 0
  traffic_collect_no_lock
  apply_state_transaction "$selected/nodes.json" "$selected/traffic.json" "$selected/traffic-history.json" "restore-${backups[$((choice-1))]}" 0 || die '恢复失败，已自动回滚。'
  success '备份恢复完成。'
}
