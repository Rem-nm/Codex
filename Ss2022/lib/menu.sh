#!/usr/bin/env bash
# Interactive rem menu and all user-facing management flows.

run_menu_action() {
  local status
  # Run one interactive action in its own process.  Any flock descriptor is
  # therefore released as soon as that action returns instead of remaining
  # held for the lifetime of the main menu.
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    trap 'on_error $LINENO' ERR
    "$@"
  )
  status=$?
  set -e
  trap 'on_error $LINENO' ERR
  # Consumed by ss-manager.sh during the mandatory first-node flow.
  # shellcheck disable=SC2034
  MENU_ACTION_STATUS=$status
  if (( status != 0 )); then
    warn "本次操作未完成（退出码 $status）；主菜单仍可继续使用。"
  fi
  return 0
}

write_temp_json() {
  local content=$1 prefix=$2
  local path="$RUNTIME_DIR/${prefix}.$$.$RANDOM.json"
  printf '%s\n' "$content" >"$path"
  chmod 600 -- "$path"
  printf '%s' "$path"
}

node_update_field_in_file() {
  local source=$1 destination=$2 node_id=$3 filter=$4
  jq --arg id "$node_id" "$filter" "$source" >"$destination"
  chmod 600 -- "$destination"
}

choose_existing_node_key() {
  local current_id=$1 required_method=$2 source_id source_node source_method
  while true; do
    source_id=$(select_node_id '请选择要复制密钥的现有节点') || return 1
    if [[ "$source_id" == "$current_id" ]]; then
      warn '请选择另一个节点。'
      continue
    fi
    source_node=$(node_by_id "$source_id")
    source_method=$(jq -er '.method' <<<"$source_node")
    if [[ "$source_method" != "$required_method" ]]; then
      warn "密钥长度必须匹配加密方式；请选择使用 $required_method 的节点。"
      continue
    fi
    jq -er '.password' <<<"$source_node"
    return 0
  done
}

node_delete_flow() {
  acquire_manager_lock
  local node_id node node_name port keep_history candidate_nodes candidate_traffic candidate_history
  node_id=$(select_node_id '请选择要删除的节点') || return 0
  node=$(node_by_id "$node_id")
  node_name=$(jq -er '.name' <<<"$node")
  port=$(jq -er '.port' <<<"$node")
  printf '\n即将删除节点：%s（端口 %s，Node ID %s）\n' "$node_name" "$port" "$node_id"
  prompt_yes_no '确认删除该节点？' n || return 0
  keep_history=n
  if prompt_yes_no '是否保留该节点的累计/周期流量数据备份？' y; then keep_history=y; fi
  # Sample immediately before constructing the delete candidates so the
  # archived totals include traffic that arrived while confirmation was open.
  traffic_collect_no_lock
  candidate_nodes="$RUNTIME_DIR/nodes.delete.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.delete.$$.json"
  candidate_history="$RUNTIME_DIR/history.delete.$$.json"
  jq --arg id "$node_id" '.nodes |= map(select(.node_id != $id))' "$NODES_FILE" >"$candidate_nodes"
  traffic_candidate_remove_node "$node_id" >"$candidate_traffic"
  if [[ "$keep_history" == y ]]; then
    traffic_candidate_archive_deleted_node "$HISTORY_FILE" "$node_id" "$node_name" "$TRAFFIC_FILE" >"$candidate_history"
  else
    traffic_candidate_purge_deleted_node "$HISTORY_FILE" "$node_id" >"$candidate_history"
  fi
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "delete-node-$node_id" 0; then
    success "节点 $node_name 已删除。其他节点未受影响。"
  else
    error '删除失败，已自动恢复上一版本配置。'
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

node_modify_flow() {
  acquire_manager_lock
  local node_id node field action requested name method port address_line address address_type password quota_gb quota reset_day upload_limit download_limit candidate_nodes candidate_traffic candidate_history traffic_source changed=0
  node_id=$(select_node_id '请选择要修改的节点') || return 0
  node=$(node_by_id "$node_id")
  printf '\n当前节点：%s（Node ID %s）\n' "$(jq -er '.name' <<<"$node")" "$node_id"
  printf '1. 名称\n2. 加密方式（会自动生成符合新算法的密钥）\n3. 端口\n4. 修改密钥（重新生成或复制同算法节点）\n5. 节点地址\n6. 月流量限额\n7. 流量重置日\n8. 上传/下载限速\n0. 返回\n> '
  IFS= read -r field || die '读取输入失败。'
  candidate_nodes="$RUNTIME_DIR/nodes.modify.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.modify.$$.json"
  candidate_history="$RUNTIME_DIR/history.modify.$$.json"
  install -m 600 -- "$NODES_FILE" "$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  case "$field" in
    1)
      requested=$(read_nonempty '请输入新的节点名称：')
      validate_name "$requested" || die '节点名称包含控制字符、路径字符或超过 64 个字符。'
      name=$(unique_node_name "$requested" "$node_id") || die '无法生成唯一名称。'
      [[ "$name" == "$requested" ]] || info "名称已存在，自动使用：$name"
      jq --arg id "$node_id" --arg name "$name" '.nodes[] |= if .node_id == $id then .name=$name | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    2)
      method=$(choose_method)
      password=$(generate_random_key "$(method_key_bytes "$method")")
      jq --arg id "$node_id" --arg method "$method" --arg password "$password" '.nodes[] |= if .node_id == $id then .method=$method | .password=$password | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      info '加密方式已修改，并已自动生成新的安全密钥。'
      changed=1
      ;;
    3)
      port=$(choose_port "$node_id")
      jq --arg id "$node_id" --argjson port "$port" '.nodes[] |= if .node_id == $id then .port=$port | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    4)
      method=$(jq -er '.method' <<<"$node")
      printf '1. 重新生成安全随机密钥（默认）\n2. 复制另一个同加密方式节点的密钥\n0. 返回\n> '
      IFS= read -r action || die '读取输入失败。'
      [[ -z "$action" ]] && action=1
      case "$action" in
        1) password=$(generate_random_key "$(method_key_bytes "$method")") ;;
        2)
          password=$(choose_existing_node_key "$node_id" "$method") || {
            rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
            return 0
          }
          ;;
        0) rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0 ;;
        *) warn '无效选项。'; rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0 ;;
      esac
      jq --arg id "$node_id" --arg password "$password" '.nodes[] |= if .node_id == $id then .password=$password | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      info '节点密钥已更新；旧密钥立即失效。'
      changed=1
      ;;
    5)
      address_line=$(choose_address)
      address=${address_line%$'\t'*}
      address_type=${address_line##*$'\t'}
      jq --arg id "$node_id" --arg address "$address" --arg address_type "$address_type" '.nodes[] |= if .node_id == $id then .address=$address | .address_type=$address_type | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    6)
      printf '请输入月流量限额（GB，0=不限）：\n> '
      IFS= read -r quota_gb || die '读取输入失败。'
      quota=$(bytes_from_gb "$quota_gb" 2>/dev/null || true)
      [[ "$quota" =~ ^[0-9]+$ ]] || die '请输入非负数字，例如 500 或 0。'
      reset_day=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .reset_day' "$candidate_nodes")
      traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
      mv -f -- "$traffic_source" "$candidate_traffic"
      traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      jq --arg id "$node_id" --argjson quota "$quota" '.nodes[] |= if .node_id == $id then .quota_bytes=$quota | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    7)
      printf '请输入新的每月重置日（1-28）：\n> '
      IFS= read -r reset_day || die '读取输入失败。'
      validate_reset_day "$reset_day" || die '重置日必须为 1-28。'
      quota=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .quota_bytes' "$candidate_nodes")
      traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
      mv -f -- "$traffic_source" "$candidate_traffic"
      traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      jq --arg id "$node_id" --argjson reset_day "$reset_day" '.nodes[] |= if .node_id == $id then .reset_day=$reset_day | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    8)
      printf '请输入上传限速 Mbps（0=不限）：\n> '
      IFS= read -r upload_limit || die '读取输入失败。'
      printf '请输入下载限速 Mbps（0=不限）：\n> '
      IFS= read -r download_limit || die '读取输入失败。'
      validate_limit_mbps "$upload_limit" && validate_limit_mbps "$download_limit" || die '限速必须是 0 或非负数字。'
      jq --arg id "$node_id" --arg upload "$upload_limit" --arg download "$download_limit" '.nodes[] |= if .node_id == $id then .upload_limit_mbps=($upload|tonumber) | .download_limit_mbps=($download|tonumber) | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    0) rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0 ;;
    *) warn '无效选项。'; rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0 ;;
  esac

  if (( changed == 0 )); then rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0; fi
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "modify-node-$node_id"; then
    success '节点修改成功。'
  else
    error '节点修改失败，已自动恢复上一版本配置。'
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" "$RUNTIME_DIR/traffic.modify.generated.$$"
}

node_status_flow() {
  acquire_manager_lock
  local node_id node action status reason candidate_nodes candidate_traffic candidate_history
  node_id=$(select_node_id '请选择要启用/停用的节点') || return 0
  node=$(node_by_id "$node_id")
  status=$(jq -er '.status' <<<"$node")
  printf '1. 启用节点\n2. 手动停用节点\n3. 标记为错误停用\n0. 返回\n> '
  IFS= read -r action || die '读取输入失败。'
  case "$action" in
    1) status=enabled; reason='' ;;
    2) status=disabled_manual; reason='用户手动停用' ;;
    3) status=disabled_error; reason='用户确认节点运行/配置异常' ;;
    0) return 0 ;;
    *) warn '无效选项。'; return 0 ;;
  esac
  candidate_nodes="$RUNTIME_DIR/nodes.status.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.status.$$.json"
  candidate_history="$RUNTIME_DIR/history.status.$$.json"
  jq --arg id "$node_id" --arg status "$status" --arg reason "$reason" '.nodes[] |= if .node_id == $id then .status=$status | .status_reason=$reason | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "status-node-$node_id"; then success "节点状态已更新为：$(status_label "$status")。"; else error '状态修改失败，已自动回滚。'; fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

traffic_stats_flow() {
  acquire_manager_lock
  traffic_collect_no_lock
  node_list_compact
  local node_id
  node_id=$(select_node_id '请选择要查看流量详情的节点') || return 0
  node_show_detail "$node_id"
  printf '\n最近结算历史：\n'
  local entry period upload download total
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    period=$(jq -er '.period' <<<"$entry")
    upload=$(jq -er '.upload_bytes' <<<"$entry")
    download=$(jq -er '.download_bytes' <<<"$entry")
    total=$(jq -er '.total_bytes' <<<"$entry")
    printf '%s：上传 %s，下载 %s，合计 %s\n' "$period" "$(format_bytes "$upload")" "$(format_bytes "$download")" "$(format_bytes "$total")"
  done < <(jq -c --arg id "$node_id" '.cycles[$id].entries[]?' "$HISTORY_FILE")
}

traffic_quota_flow() {
  acquire_manager_lock
  local node_id node quota_gb quota reset_day candidate_nodes candidate_traffic candidate_history traffic_source
  node_id=$(select_node_id '请选择要设置流量限额的节点') || return 0
  node=$(node_by_id "$node_id")
  printf '请输入月流量限额（GB，0=不限）：\n> '
  IFS= read -r quota_gb || die '读取输入失败。'
  quota=$(bytes_from_gb "$quota_gb" 2>/dev/null || true)
  [[ "$quota" =~ ^[0-9]+$ ]] || die '请输入非负数字，例如 500 或 0。'
  reset_day=$(jq -er '.reset_day' <<<"$node")
  candidate_nodes="$RUNTIME_DIR/nodes.quota.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.quota.$$.json"
  candidate_history="$RUNTIME_DIR/history.quota.$$.json"
  jq --arg id "$node_id" --argjson quota "$quota" '.nodes[] |= if .node_id == $id then .quota_bytes=$quota | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
  mv -f -- "$traffic_source" "$candidate_traffic"
  traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
  mv -f -- "$candidate_nodes.next" "$candidate_nodes"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "quota-node-$node_id"; then success '月流量限额已更新。'; else error '月流量限额更新失败，已回滚。'; fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

traffic_reset_day_flow() {
  acquire_manager_lock
  local node_id node reset_day quota candidate_nodes candidate_traffic candidate_history traffic_source
  node_id=$(select_node_id '请选择要设置重置日的节点') || return 0
  node=$(node_by_id "$node_id")
  printf '请输入每月重置日（1-28）：\n> '
  IFS= read -r reset_day || die '读取输入失败。'
  validate_reset_day "$reset_day" || die '重置日必须为 1-28。'
  quota=$(jq -er '.quota_bytes' <<<"$node")
  candidate_nodes="$RUNTIME_DIR/nodes.reset.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.reset.$$.json"
  candidate_history="$RUNTIME_DIR/history.reset.$$.json"
  jq --arg id "$node_id" --argjson reset_day "$reset_day" '.nodes[] |= if .node_id == $id then .reset_day=$reset_day | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
  mv -f -- "$traffic_source" "$candidate_traffic"
  traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
  mv -f -- "$candidate_nodes.next" "$candidate_nodes"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "reset-day-node-$node_id"; then success '流量重置日已更新。'; else error '重置日更新失败，已回滚。'; fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

bandwidth_flow() {
  acquire_manager_lock
  local node_id node upload_limit download_limit candidate_nodes candidate_traffic candidate_history
  node_id=$(select_node_id '请选择要设置限速的节点') || return 0
  node=$(node_by_id "$node_id")
  printf '请输入上传限速 Mbps（0=不限）：\n> '
  IFS= read -r upload_limit || die '读取输入失败。'
  printf '请输入下载限速 Mbps（0=不限）：\n> '
  IFS= read -r download_limit || die '读取输入失败。'
  validate_limit_mbps "$upload_limit" && validate_limit_mbps "$download_limit" || die '限速必须为 0 或非负数字。'
  candidate_nodes="$RUNTIME_DIR/nodes.bandwidth.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.bandwidth.$$.json"
  candidate_history="$RUNTIME_DIR/history.bandwidth.$$.json"
  jq --arg id "$node_id" --arg upload "$upload_limit" --arg download "$download_limit" '.nodes[] |= if .node_id == $id then .upload_limit_mbps=($upload|tonumber) | .download_limit_mbps=($download|tonumber) | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "bandwidth-node-$node_id"; then success '节点上下行限速已更新。'; else error '限速更新失败，已回滚。'; fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

singbox_management_flow() {
  local choice
  while true; do
    printf '\nSing-box 管理\n1. 查看状态\n2. 启动\n3. 停止\n4. 重启\n5. 查看最近日志\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1) systemctl status "$SING_BOX_SERVICE" --no-pager ;;
      2) run_menu_action singbox_start_action ;;
      3) run_menu_action singbox_stop_action ;;
      4) run_menu_action singbox_restart_action ;;
      5) journalctl -u "$SING_BOX_SERVICE" --output cat -n 80 --no-pager ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}

singbox_start_action() {
  acquire_manager_lock
  singbox_start
  singbox_health_check "$NODES_FILE" || die '启动后健康检查未通过。'
}

singbox_stop_action() {
  acquire_manager_lock
  singbox_stop
  ! singbox_is_active || die 'sing-box 停止操作未生效。'
  success 'sing-box 已停止；定时维护不会擅自重新启动它。'
}

singbox_restart_action() {
  acquire_manager_lock
  singbox_restart
  singbox_health_check "$NODES_FILE" || die '重启后健康检查未通过。'
}

system_settings_flow() {
  local choice
  while true; do
    printf '\n系统设置\n1. 查看系统能力\n2. 检查/启用 BBR\n3. 检查/启用 TCP Fast Open\n4. 刷新流量接口\n5. 查看 tc 流控规则\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1)
        printf '系统：%s\n架构：%s\n监听模式：%s（地址 %s）\nBBR：%s\nTFO 内核：%s\nTFO 配置字段：%s\n流量接口：\n' "$HOST_OS_NAME" "$HOST_ARCH" "$(manager_state_get listen_mode unknown)" "$(manager_state_get listen_address unknown)" "$(manager_state_get bbr_enabled false)" "$(manager_state_get tfo_kernel_enabled false)" "$(manager_state_get tfo_config_supported false)"
        traffic_interfaces
        ;;
      2) run_menu_action system_bbr_action ;;
      3) run_menu_action system_tfo_action ;;
      4) run_menu_action system_refresh_interfaces_action ;;
      5) bandwidth_status ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}

system_bbr_action() {
  acquire_manager_lock
  configure_bbr
}

system_tfo_action() {
  acquire_manager_lock
  configure_tcp_fast_open_kernel
  if [[ -x "$SING_BOX_BINARY" ]]; then singbox_config_supports_tfo || true; fi
  apply_state_transaction "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" 'system-tfo-update' || die 'TFO 配置变更未提交，已回滚。'
}

system_refresh_interfaces_action() {
  acquire_manager_lock
  traffic_collect_no_lock
  local previous_interfaces="$RUNTIME_DIR/interfaces.previous.$$.json"
  install -m 600 -- "$INTERFACES_FILE" "$previous_interfaces"
  detect_traffic_interfaces
  if ! (bandwidth_apply_and_check "$NODES_FILE") || ! (traffic_reset_kernel_baselines "$NODES_FILE"); then
    error '新接口上的 tc 规则无法应用，正在恢复之前的接口计划。'
    install -m 600 -- "$previous_interfaces" "$INTERFACES_FILE"
    bandwidth_apply_and_check "$NODES_FILE" >/dev/null 2>&1 || warn '旧接口计划恢复后，tc 规则仍需人工检查。'
    traffic_reset_kernel_baselines "$NODES_FILE" >/dev/null 2>&1 || warn '旧接口计划恢复后，计数基线仍需人工检查。'
    rm -f -- "$previous_interfaces"
    return 1
  fi
  rm -f -- "$previous_interfaces"
  success '已刷新流量接口，并重新验证统计/限速规则。'
}

remove_manager_service_files() {
  systemctl disable --now "$SYSTEMD_TRAFFIC_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$SYSTEMD_TRAFFIC_SERVICE" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f -- "$SYSTEMD_DIR/$SYSTEMD_TRAFFIC_TIMER" "$SYSTEMD_DIR/$SYSTEMD_TRAFFIC_SERVICE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_rem_command() {
  if [[ -e /usr/local/bin/rem ]] && is_command_from_manager /usr/local/bin/rem; then
    rm -f -- /usr/local/bin/rem
  fi
}

uninstall_flow() {
  require_root
  assert_standard_destructive_paths
  local mode
  printf '\n卸载模式：\n1. 仅删除程序，保留配置和数据\n2. 删除程序和运行配置，保留备份\n3. 完全卸载\n0. 返回\n> '
  IFS= read -r mode || die '读取输入失败。'
  [[ "$mode" == 1 || "$mode" == 2 || "$mode" == 3 ]] || return 0
  prompt_yes_no "确认执行卸载模式 $mode？本项目不会修改任何防火墙规则" n || return 0
  acquire_manager_lock
  bandwidth_remove_manager_rules
  remove_manager_service_files
  remove_rem_command
  if [[ "$mode" != 1 ]]; then
    systemctl disable --now "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
    if singbox_service_unit_is_managed; then rm -f -- "$SYSTEMD_DIR/$SING_BOX_SERVICE"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$(manager_state_get sing_box_binary_managed false)" == true ]]; then rm -f -- "$SING_BOX_BINARY"; fi
    rm -f -- "$SING_BOX_CONFIG"
    if [[ "$mode" == 2 ]]; then
      rm -f -- "$MANAGER_STATE" "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" "$COUNTERS_FILE" "$INTERFACES_FILE" "$DATA_DIR/bandwidth-plan.json"
      find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf -- {} + 2>/dev/null || true
      rm -rf -- "$DATA_DIR"
    else
      restore_kernel_settings_on_uninstall
      rm -rf -- "$CONFIG_DIR" "$DATA_DIR"
    fi
  fi
  rm -rf -- "$PROGRAM_DIR"
  success '卸载流程完成。本项目没有修改或删除 iptables/nftables/UFW/firewalld/ipset 规则。'
  exit 0
}

main_menu() {
  initialize_state_files
  while true; do
    local count total
    count=$(node_count)
    total=$(jq -n --slurpfile nodes "$NODES_FILE" --slurpfile traffic "$TRAFFIC_FILE" '
      reduce ($nodes[0].nodes[]?.node_id) as $id (0; . + (($traffic[0].nodes[$id].current_upload_bytes // 0) + ($traffic[0].nodes[$id].current_download_bytes // 0)))')
    printf '\n================================\n          REM SS Manager\n================================\n\nSing-box：%s\n节点数量：%s\n本周期总流量：%s\n\n' "$(singbox_status_summary)" "$count" "$(format_bytes "$total")"
    printf '1. 添加节点\n2. 删除节点\n3. 修改节点\n4. 查看节点\n5. 节点详细信息\n6. 显示节点链接 / 二维码\n7. 启用 / 停用节点\n\n8. 流量统计\n9. 流量限额\n10. 流量重置\n11. 上传 / 下载限速\n\n12. Sing-box 管理\n13. 更新管理\n14. 备份与恢复\n15. 系统设置\n16. 卸载\n\n0. 退出\n> '
    local choice
    IFS= read -r choice || exit 0
    case "$choice" in
      1) run_menu_action node_add_flow ;;
      2) run_menu_action node_delete_flow ;;
      3) run_menu_action node_modify_flow ;;
      4) node_list_compact ;;
      5) node_view_flow ;;
      6) show_node_link_flow ;;
      7) run_menu_action node_status_flow ;;
      8) run_menu_action traffic_stats_flow ;;
      9) run_menu_action traffic_quota_flow ;;
      10) run_menu_action traffic_reset_day_flow ;;
      11) run_menu_action bandwidth_flow ;;
      12) singbox_management_flow ;;
      13) update_menu_flow ;;
      14) backup_management_flow ;;
      15) system_settings_flow ;;
      16) uninstall_flow ;;
      0) exit 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
