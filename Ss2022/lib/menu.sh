#!/usr/bin/env bash
# Interactive rem menu and all user-facing management flows.

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

node_delete_flow() {
  acquire_manager_lock
  traffic_collect_no_lock
  local node_id node node_name port keep_history candidate_nodes candidate_traffic candidate_history
  node_id=$(select_node_id '请选择要删除的节点') || return 0
  node=$(node_by_id "$node_id")
  node_name=$(jq -er '.name' <<<"$node")
  port=$(jq -er '.port' <<<"$node")
  printf '\n即将删除节点：%s（端口 %s，Node ID %s）\n' "$node_name" "$port" "$node_id"
  prompt_yes_no '确认删除该节点？' n || return 0
  keep_history=n
  if prompt_yes_no '是否保留该节点的累计/周期流量数据备份？' y; then keep_history=y; fi
  candidate_nodes="$RUNTIME_DIR/nodes.delete.$$.json"
  candidate_traffic="$RUNTIME_DIR/traffic.delete.$$.json"
  candidate_history="$RUNTIME_DIR/history.delete.$$.json"
  jq --arg id "$node_id" '.nodes |= map(select(.node_id != $id))' "$NODES_FILE" >"$candidate_nodes"
  traffic_candidate_remove_node "$node_id" >"$candidate_traffic"
  if [[ "$keep_history" == y ]]; then
    traffic_candidate_archive_deleted_node "$HISTORY_FILE" "$node_id" "$node_name" "$TRAFFIC_FILE" >"$candidate_history"
  else
    install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  fi
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "delete-node-$node_id"; then
    success "节点 $node_name 已删除。其他节点未受影响。"
  else
    error '删除失败，已自动恢复上一版本配置。'
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

node_modify_flow() {
  acquire_manager_lock
  local node_id node field requested name method port address_line address address_type password quota_gb quota reset_day upload_limit download_limit candidate_nodes candidate_traffic candidate_history traffic_source changed=0
  node_id=$(select_node_id '请选择要修改的节点') || return 0
  node=$(node_by_id "$node_id")
  printf '\n当前节点：%s（Node ID %s）\n' "$(jq -er '.name' <<<"$node")" "$node_id"
  printf '1. 名称\n2. 加密方式（会自动生成符合新算法的密钥）\n3. 端口\n4. 重新生成密钥\n5. 节点地址\n6. 月流量限额\n7. 流量重置日\n8. 上传/下载限速\n0. 返回\n> '
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
      password=$(generate_random_key "$(method_key_bytes "$(jq -er '.method' <<<"$node")")")
      jq --arg id "$node_id" --arg password "$password" '.nodes[] |= if .node_id == $id then .password=$password | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      info '已生成新的安全密钥；旧密钥立即失效。'
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
  jq -r --arg id "$node_id" '.cycles[$id].entries[]? | "\(.period)：上传 \(.upload_bytes | tostring) bytes，下载 \(.download_bytes | tostring) bytes，合计 \(.total_bytes | tostring) bytes"' "$HISTORY_FILE" || true
}

traffic_quota_flow() {
  acquire_manager_lock
  local node_id node quota_gb quota reset_day candidate_nodes candidate_traffic candidate_history
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
  traffic_update_node_settings "$node_id" "$quota" "$reset_day" >"$RUNTIME_DIR/traffic.quota.source.$$"
  mv -f -- "$(cat "$RUNTIME_DIR/traffic.quota.source.$$")" "$candidate_traffic"
  rm -f -- "$RUNTIME_DIR/traffic.quota.source.$$"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "quota-node-$node_id"; then success '月流量限额已更新。'; else error '月流量限额更新失败，已回滚。'; fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
}

traffic_reset_day_flow() {
  acquire_manager_lock
  local node_id node reset_day quota candidate_nodes candidate_traffic candidate_history
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
  traffic_update_node_settings "$node_id" "$quota" "$reset_day" >"$RUNTIME_DIR/traffic.reset.source.$$"
  mv -f -- "$(cat "$RUNTIME_DIR/traffic.reset.source.$$")" "$candidate_traffic"
  rm -f -- "$RUNTIME_DIR/traffic.reset.source.$$"
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
      2) singbox_start && singbox_health_check "$NODES_FILE" || warn '启动后健康检查未通过。' ;;
      3) singbox_stop ;;
      4) singbox_restart && singbox_health_check "$NODES_FILE" || warn '重启后健康检查未通过。' ;;
      5) journalctl -u "$SING_BOX_SERVICE" --output cat -n 80 --no-pager ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}

system_settings_flow() {
  acquire_manager_lock
  local choice
  while true; do
    printf '\n系统设置\n1. 查看系统能力\n2. 检查/启用 BBR\n3. 检查/启用 TCP Fast Open\n4. 刷新流量接口\n5. 查看 tc 流控规则\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1)
        printf '系统：%s\n架构：%s\n监听模式：%s（地址 %s）\nBBR：%s\nTFO 内核：%s\nTFO 配置字段：%s\n流量接口：\n' "$HOST_OS_NAME" "$HOST_ARCH" "$(manager_state_get listen_mode unknown)" "$(manager_state_get listen_address unknown)" "$(manager_state_get bbr_enabled false)" "$(manager_state_get tfo_kernel_enabled false)" "$(manager_state_get tfo_config_supported false)"
        traffic_interfaces
        ;;
      2) configure_bbr ;;
      3)
        configure_tcp_fast_open_kernel
        if [[ -x "$SING_BOX_BINARY" ]]; then singbox_config_supports_tfo || true; fi
        apply_state_transaction "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" 'system-tfo-update' || warn 'TFO 配置变更未提交，已回滚。'
        ;;
      4) detect_traffic_interfaces; success '已刷新流量接口。' ;;
      5) bandwidth_status ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
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
    local summary count total
    count=$(node_count)
    total=$(jq -n --slurpfile nodes "$NODES_FILE" --slurpfile traffic "$TRAFFIC_FILE" '
      reduce ($nodes[0].nodes[]?.node_id) as $id (0; . + (($traffic[0].nodes[$id].current_upload_bytes // 0) + ($traffic[0].nodes[$id].current_download_bytes // 0)))')
    printf '\n================================\n          REM SS Manager\n================================\n\nSing-box：%s\n节点数量：%s\n本周期总流量：%s\n\n' "$(singbox_status_summary)" "$count" "$(format_bytes "$total")"
    printf '1. 添加节点\n2. 删除节点\n3. 修改节点\n4. 查看节点\n5. 节点详细信息\n6. 显示节点链接 / 二维码\n7. 启用 / 停用节点\n\n8. 流量统计\n9. 流量限额\n10. 流量重置\n11. 上传 / 下载限速\n\n12. Sing-box 管理\n13. 更新管理\n14. 备份与恢复\n15. 系统设置\n16. 卸载\n\n0. 退出\n> '
    local choice
    IFS= read -r choice || exit 0
    case "$choice" in
      1) node_add_flow ;;
      2) node_delete_flow ;;
      3) node_modify_flow ;;
      4) node_list_compact ;;
      5) node_view_flow ;;
      6) show_node_link_flow ;;
      7) node_status_flow ;;
      8) traffic_stats_flow ;;
      9) traffic_quota_flow ;;
      10) traffic_reset_day_flow ;;
      11) bandwidth_flow ;;
      12) singbox_management_flow ;;
      13) update_menu_flow ;;
      14) backup_restore_flow ;;
      15) system_settings_flow ;;
      16) uninstall_flow ;;
      0) exit 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
