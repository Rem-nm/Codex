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
  # A successful self-update exits its isolated action with 75. Replace the
  # old long-lived menu process so all subsequently executed functions come
  # from the newly installed manager version.
  if (( status == 75 )); then
    # exec returns only when replacement itself fails; the following die then
    # reports that failure instead of continuing with old loaded functions.
    # shellcheck disable=SC2093
    exec "$PROGRAM_DIR/ss-manager.sh" menu
    die 'manager 已更新，但新版本菜单无法启动。'
  fi
  if (( status != 0 )); then
    if [[ -e "$INSTALL_TRANSACTION_DIR" || -L "$INSTALL_TRANSACTION_DIR" \
      || -e "$STATE_TRANSACTION_DIR" || -L "$STATE_TRANSACTION_DIR" ]]; then
      warn '检测到失败操作留下的持久事务，主菜单返回前先执行恢复。'
      if ! (
        set -Eeuo pipefail
        trap 'on_error $LINENO' ERR
        acquire_manager_lock
        recover_incomplete_install_transaction
        recover_incomplete_state_transaction
      ); then
        die '失败操作的持久事务无法自动恢复；为避免继续修改不一致状态，主菜单已停止。'
      fi
      local installed_version=''
      if [[ -r "$PROGRAM_DIR/VERSION" ]]; then
        IFS= read -r installed_version <"$PROGRAM_DIR/VERSION" || true
        installed_version=${installed_version//$'\r'/}
      fi
      if [[ -n "$installed_version" && "$installed_version" != "$MANAGER_VERSION" ]]; then
        # shellcheck disable=SC2093
        exec "$PROGRAM_DIR/ss-manager.sh" menu
        die '事务恢复完成，但已恢复版本的菜单无法启动。'
      fi
    fi
    warn "本次操作未完成（退出码 $status）；主菜单仍可继续使用。"
  fi
  return 0
}

write_temp_json() {
  local content=$1 prefix=$2
  local path
  path=$(runtime_temp_file "$prefix") || return 1
  printf '%s\n' "$content" >"$path" || return 1
  chmod 600 -- "$path" || return 1
  printf '%s' "$path"
}

prepare_state_candidate_paths() {
  local prefix=$1 nodes_variable=$2 traffic_variable=$3 history_variable=$4
  local nodes_path traffic_path history_path
  nodes_path=$(runtime_temp_file "nodes.$prefix") || return 1
  traffic_path=$(runtime_temp_file "traffic.$prefix") || { rm -f -- "$nodes_path"; return 1; }
  history_path=$(runtime_temp_file "history.$prefix") || { rm -f -- "$nodes_path" "$traffic_path"; return 1; }
  printf -v "$nodes_variable" '%s' "$nodes_path"
  printf -v "$traffic_variable" '%s' "$traffic_path"
  printf -v "$history_variable" '%s' "$history_path"
}

node_update_field_in_file() {
  local source=$1 destination=$2 node_id=$3 filter=$4
  jq --arg id "$node_id" "$filter" "$source" >"$destination" || return 1
  chmod 600 -- "$destination" || return 1
}

choose_existing_node_key() {
  local current_id=$1 required_method=$2 source_id source_node source_method source_protocol
  while true; do
    select_node_for_flow source_id '请选择要复制密钥的现有节点' || return 1
    if [[ "$source_id" == "$current_id" ]]; then
      warn '请选择另一个节点。'
      continue
    fi
    source_node=$(node_by_id "$source_id") || die '无法读取所选节点。'
    source_protocol=$(node_protocol "$source_node") || die '所选节点协议字段无效。'
    if [[ "$source_protocol" != shadowsocks ]]; then
      warn 'VLESS 节点没有可复制的 Shadowsocks 密钥；请选择 SS2022 节点。'
      continue
    fi
    source_method=$(jq -er '.method' <<<"$source_node") || die '所选节点的加密方式无效。'
    if [[ "$source_method" != "$required_method" ]]; then
      warn "密钥长度必须匹配加密方式；请选择使用 $required_method 的节点。"
      continue
    fi
    jq -er '.password' <<<"$source_node" || die '所选节点的密钥无效。'
    return 0
  done
}

node_delete_flow() {
  acquire_manager_lock
  local node_id node node_name protocol port keep_history candidate_nodes candidate_traffic candidate_history candidate_certs=''
  select_node_for_flow node_id '请选择要删除的节点' || return 0
  node=$(node_by_id "$node_id")
  node_name=$(jq -er '.name' <<<"$node")
  protocol=$(node_protocol "$node") || die '节点协议字段无效。'
  port=$(jq -er '.port' <<<"$node")
  printf '\n即将删除节点：%s（协议 %s，端口 %s，Node ID %s）\n' "$node_name" "$(protocol_label "$protocol")" "$port" "$node_id"
  prompt_yes_no '确认删除该节点？' n || return 0
  keep_history=n
  if prompt_yes_no '是否保留该节点的累计/周期流量数据备份？' y; then keep_history=y; fi
  # Sample immediately before constructing the delete candidates so the
  # archived totals include traffic that arrived while confirmation was open.
  traffic_collect_no_lock
  prepare_state_candidate_paths delete candidate_nodes candidate_traffic candidate_history \
    || die '无法创建删除事务候选文件。'
  jq --arg id "$node_id" '.nodes |= map(select(.node_id != $id))' "$NODES_FILE" >"$candidate_nodes"
  if [[ "$protocol" == hysteria2 ]]; then
    candidate_certs=$(hysteria2_make_candidate_cert_root) || die '无法创建 Hysteria2 证书删除候选目录。'
    hysteria2_remove_candidate_node "$candidate_certs" "$node_id" || { rm -rf -- "$candidate_certs"; die '无法移除 Hysteria2 节点证书。'; }
  fi
  traffic_candidate_remove_node "$node_id" >"$candidate_traffic"
  if [[ "$keep_history" == y ]]; then
    traffic_candidate_archive_deleted_node "$HISTORY_FILE" "$node_id" "$node_name" "$TRAFFIC_FILE" >"$candidate_history"
  else
    traffic_candidate_purge_deleted_node "$HISTORY_FILE" "$node_id" >"$candidate_history"
  fi
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "delete-node-$node_id" 0 "$candidate_certs"; then
    success "节点 $node_name 已删除。其他节点未受影响。"
  else
    error '删除失败，已自动恢复上一版本配置。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '删除事务已结束，但运行时候选文件清理失败。'
  [[ -z "$candidate_certs" || ! -e "$candidate_certs" ]] || rm -rf -- "$candidate_certs"
  return "$transaction_status"
}

node_modify_flow() {
  acquire_manager_lock
  local node_id node field action protocol requested name method port address_line address address_type password quota_gb quota reset_day upload_limit download_limit candidate_nodes candidate_traffic candidate_history traffic_source changed=0 show_credentials_after=0 candidate_certs=''
  local server_name handshake_line handshake_server handshake_port uuid keypair private_key public_key short_id certificate_pin
  select_node_for_flow node_id '请选择要修改的节点' || return 0
  node=$(node_by_id "$node_id")
  protocol=$(node_protocol "$node") || die '节点协议字段无效。'
  printf '\n当前节点：%s（%s，Node ID %s）\n' "$(jq -er '.name' <<<"$node")" "$(protocol_label "$protocol")" "$node_id"
  if [[ "$protocol" == shadowsocks ]]; then
    printf '1. 名称\n2. 加密方式（会自动生成符合新算法的密钥）\n3. 端口\n4. 修改密钥（重新生成或复制同算法节点）\n5. 节点地址\n6. 月流量限额\n7. 流量重置日\n8. 上传/下载限速\n0. 返回\n> '
  elif [[ "$protocol" == vless ]]; then
    printf '1. 名称\n2. 端口\n3. 节点地址\n4. Reality Server Name / SNI\n5. Reality 握手目标\n6. 月流量限额\n7. 流量重置日\n8. 上传/下载限速\n9. 重新生成 UUID\n10. 重新生成 Reality KeyPair\n11. 重新生成 Short ID\n0. 返回\n> '
  else
    printf '1. 名称\n2. 端口\n3. 节点地址\n4. 修改密码\n5. 重新生成自签名证书\n6. 月流量限额\n7. 流量重置日\n8. 上传/下载限速\n0. 返回\n> '
  fi
  IFS= read -r field || die '读取输入失败。'
  if [[ "$protocol" == shadowsocks ]]; then
    case "$field" in
      1) field=name ;; 2) field=ss-method ;; 3) field=port ;; 4) field=ss-key ;;
      5) field=address ;; 6) field=quota ;; 7) field=reset ;; 8) field=bandwidth ;;
      0) return 0 ;; *) warn '无效选项。'; return 0 ;;
    esac
  elif [[ "$protocol" == vless ]]; then
    case "$field" in
      1) field=name ;; 2) field=port ;; 3) field=address ;; 4) field=vless-sni ;;
      5) field=vless-handshake ;; 6) field=quota ;; 7) field=reset ;; 8) field=bandwidth ;;
      9) field=vless-uuid ;; 10) field=vless-keypair ;; 11) field=vless-short ;;
      0) return 0 ;; *) warn '无效选项。'; return 0 ;;
    esac
  else
    case "$field" in
      1) field=name ;; 2) field=port ;; 3) field=address ;; 4) field=hy2-password ;;
      5) field=hy2-cert ;; 6) field=quota ;; 7) field=reset ;; 8) field=bandwidth ;;
      0) return 0 ;; *) warn '无效选项。'; return 0 ;;
    esac
  fi
  prepare_state_candidate_paths modify candidate_nodes candidate_traffic candidate_history \
    || die '无法创建修改事务候选文件。'
  install -m 600 -- "$NODES_FILE" "$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if [[ "$protocol" == hysteria2 ]]; then
    candidate_certs=$(hysteria2_make_candidate_cert_root) || die '无法创建 Hysteria2 证书候选目录。'
  fi
  case "$field" in
    name)
      requested=$(read_nonempty '请输入新的节点名称：')
      validate_name "$requested" || die '节点名称包含控制字符、路径字符或超过 64 个字符。'
      name=$(unique_node_name "$requested" "$node_id") || die '无法生成唯一名称。'
      [[ "$name" == "$requested" ]] || info "名称已存在，自动使用：$name"
      jq --arg id "$node_id" --arg name "$name" '.nodes[] |= if .node_id == $id then .name=$name | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    ss-method)
      method=$(choose_method)
      password=$(generate_random_key "$(method_key_bytes "$method")")
      printf '%s' "$password" | jq -Rs --arg id "$node_id" --arg method "$method" --slurpfile source "$candidate_nodes" \
        '. as $password | $source[0] | .nodes[] |= if .node_id == $id then .method=$method | .password=$password | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成节点加密方式候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      info '加密方式已修改，并已自动生成新的安全密钥。'
      changed=1
      ;;
    port)
      port=$(choose_port "$node_id" "$protocol")
      jq --arg id "$node_id" --argjson port "$port" '.nodes[] |= if .node_id == $id then .port=$port | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    ss-key)
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
      printf '%s' "$password" | jq -Rs --arg id "$node_id" --slurpfile source "$candidate_nodes" \
        '. as $password | $source[0] | .nodes[] |= if .node_id == $id then .password=$password | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成节点密钥候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      info '节点密钥已更新；旧密钥立即失效。'
      changed=1
      ;;
    address)
      address_line=$(choose_address)
      address=${address_line%$'\t'*}
      address_type=${address_line##*$'\t'}
      jq --arg id "$node_id" --arg address "$address" --arg address_type "$address_type" '.nodes[] |= if .node_id == $id then .address=$address | .address_type=$address_type | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    quota)
      printf '请输入月流量限额（GB，0=不限；安全上限 9007199.254740991 GB）：\n> '
      IFS= read -r quota_gb || die '读取输入失败。'
      quota=$(bytes_from_gb "$quota_gb" 2>/dev/null || true)
      validate_safe_uint "$quota" || die '请输入 0-9007199.254740991 范围内的非负 GB 数值。'
      reset_day=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .reset_day' "$candidate_nodes")
      traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
      mv -f -- "$traffic_source" "$candidate_traffic"
      traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      jq --arg id "$node_id" --argjson quota "$quota" '.nodes[] |= if .node_id == $id then .quota_bytes=$quota | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      traffic_sync_quota_status "$candidate_nodes" "$candidate_traffic" "$node_id" "$quota" "$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    reset)
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
    bandwidth)
      printf '请输入上传限速 Mbps（0=不限）：\n> '
      IFS= read -r upload_limit || die '读取输入失败。'
      printf '请输入下载限速 Mbps（0=不限）：\n> '
      IFS= read -r download_limit || die '读取输入失败。'
      if ! validate_limit_mbps "$upload_limit" || ! validate_limit_mbps "$download_limit"; then
        die '限速必须是 0 或非负数字。'
      fi
      jq --arg id "$node_id" --arg upload "$upload_limit" --arg download "$download_limit" '.nodes[] |= if .node_id == $id then .upload_limit_mbps=($upload|tonumber) | .download_limit_mbps=($download|tonumber) | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    vless-sni)
      server_name=$(choose_reality_server_name)
      handshake_server=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .reality_handshake_server' "$candidate_nodes") || die '无法读取 Reality 握手服务器。'
      handshake_port=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .reality_handshake_port' "$candidate_nodes") || die '无法读取 Reality 握手端口。'
      reality_handshake_reachable "$handshake_server" "$handshake_port" "$server_name" \
        || warn '新 SNI 对当前握手目标无法完成 TCP/TLS 探测；将继续配置事务，稍后必须用客户端验证。'
      jq --arg id "$node_id" --arg server_name "$server_name" '.nodes[] |= if .node_id == $id then .reality_server_name=$server_name | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    vless-handshake)
      handshake_line=$(choose_reality_handshake_target)
      handshake_server=${handshake_line%$'\t'*}
      handshake_port=${handshake_line##*$'\t'}
      server_name=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .reality_server_name' "$candidate_nodes") || die '无法读取 Reality SNI。'
      reality_handshake_reachable "$handshake_server" "$handshake_port" "$server_name" \
        || warn '新握手目标当前无法完成 TCP/TLS 探测；将继续配置事务，稍后必须用客户端验证。'
      jq --arg id "$node_id" --arg server "$handshake_server" --argjson port "$handshake_port" '.nodes[] |= if .node_id == $id then .reality_handshake_server=$server | .reality_handshake_port=$port | .updated_at=(now|todateiso8601) else . end' "$candidate_nodes" >"$candidate_nodes.next"
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      ;;
    vless-uuid)
      prompt_yes_no '重新生成 UUID 后现有客户端配置将失效，需要重新导入。确认继续？' n || { rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0; }
      uuid=$(generate_unique_vless_uuid) || die 'sing-box 无法生成未被其他节点使用的新 VLESS UUID。'
      printf '%s' "$uuid" | jq -eRs --arg id "$node_id" --slurpfile source "$candidate_nodes" \
        '. as $uuid | $source[0] | .nodes[] |= if .node_id == $id then .uuid=$uuid | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成 VLESS UUID 候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      show_credentials_after=1
      ;;
    vless-keypair)
      prompt_yes_no '重新生成 Reality KeyPair 后现有客户端配置将失效，需要重新导入。确认继续？' n || { rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0; }
      keypair=$(generate_unique_reality_keypair) || die 'sing-box 无法生成未被其他节点使用的新 Reality KeyPair。'
      private_key=${keypair%$'\t'*}
      public_key=${keypair##*$'\t'}
      printf '%s' "$private_key" | jq -Rs --arg id "$node_id" --arg public_key "$public_key" --slurpfile source "$candidate_nodes" \
        '. as $private_key | $source[0] | .nodes[] |= if .node_id == $id then .reality_private_key=$private_key | .reality_public_key=$public_key | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成 Reality KeyPair 候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      show_credentials_after=1
      ;;
    vless-short)
      prompt_yes_no '重新生成 Short ID 后现有客户端配置将失效，需要重新导入。确认继续？' n || { rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; return 0; }
      short_id=$(generate_unique_reality_short_id) || die '无法安全生成未被其他节点使用的新 Reality Short ID。'
      printf '%s' "$short_id" | jq -eRs --arg id "$node_id" --slurpfile source "$candidate_nodes" \
        '. as $short_id | $source[0] | .nodes[] |= if .node_id == $id then .reality_short_id=$short_id | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成 Reality Short ID 候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      show_credentials_after=1
      ;;
    hy2-password)
      prompt_yes_no '重新生成认证密码后，现有客户端节点配置将立即失效，需要重新获取分享链接或重新扫描二维码。确认继续？' n \
        || { rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; [[ -z "$candidate_certs" ]] || rm -rf -- "$candidate_certs"; return 0; }
      password=$(generate_hysteria2_password) || die '无法生成新的 Hysteria2 密码。'
      printf '%s' "$password" | jq -Rs --arg id "$node_id" --slurpfile source "$candidate_nodes" \
        '. as $password | $source[0] | .nodes[] |= if .node_id == $id then .password=$password | .updated_at=(now|todateiso8601) else . end' \
        >"$candidate_nodes.next" || die '无法生成 Hysteria2 密码候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      show_credentials_after=1
      ;;
    hy2-cert)
      prompt_yes_no '重新生成 TLS 证书后，证书 SHA-256 Pin 将改变，现有客户端保存的指纹将失效，需要重新获取分享链接或重新扫描二维码。确认继续？' n \
        || { rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"; [[ -z "$candidate_certs" ]] || rm -rf -- "$candidate_certs"; return 0; }
      server_name=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .tls_server_name' "$candidate_nodes") || die '无法读取 Hysteria2 TLS SNI。'
      certificate_pin=$(hysteria2_generate_certificate "$candidate_certs" "$node_id" "$server_name") \
        || die '无法重新生成 Hysteria2 自签名证书。'
      jq --arg id "$node_id" --arg pin "$certificate_pin" \
        '.nodes[] |= if .node_id == $id then .certificate_sha256=$pin | .updated_at=(now|todateiso8601) else . end' \
        "$candidate_nodes" >"$candidate_nodes.next" || die '无法写入 Hysteria2 证书候选配置。'
      mv -f -- "$candidate_nodes.next" "$candidate_nodes"
      changed=1
      show_credentials_after=1
      ;;
  esac

  if (( changed == 0 )); then
    [[ -z "$candidate_certs" ]] || rm -rf -- "$candidate_certs"
    rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history"
    return 0
  fi
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "modify-node-$node_id" 1 "$candidate_certs"; then
    success '节点修改成功。'
    if (( show_credentials_after == 1 )); then
      show_node_credentials "$node_id" \
        || warn 'VLESS 身份已经更新，但新客户端凭据未完整显示；请从“显示节点链接 / 二维码”重新查看。'
    fi
  else
    error '节点修改失败，已自动恢复上一版本配置。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '修改事务已结束，但运行时候选文件清理失败。'
  [[ -z "$candidate_certs" || ! -e "$candidate_certs" ]] || rm -rf -- "$candidate_certs"
  return "$transaction_status"
}

node_status_flow() {
  acquire_manager_lock
  local node_id node action status reason candidate_nodes candidate_traffic candidate_history
  select_node_for_flow node_id '请选择要启用/停用的节点' || return 0
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
  prepare_state_candidate_paths status candidate_nodes candidate_traffic candidate_history \
    || die '无法创建状态事务候选文件。'
  jq --arg id "$node_id" --arg status "$status" --arg reason "$reason" '.nodes[] |= if .node_id == $id then .status=$status | .status_reason=$reason | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  if [[ "$status" == enabled ]]; then
    local quota
    quota=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .quota_bytes' "$candidate_nodes")
    traffic_sync_quota_status "$candidate_nodes" "$candidate_traffic" "$node_id" "$quota" "$candidate_nodes.next"
    mv -f -- "$candidate_nodes.next" "$candidate_nodes"
    status=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .status' "$candidate_nodes")
  fi
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "status-node-$node_id"; then
    success "节点状态已更新为：$(status_label "$status")。"
  else
    error '状态修改失败，已自动回滚。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '状态事务已结束，但运行时候选文件清理失败。'
  return "$transaction_status"
}

traffic_stats_flow() {
  acquire_manager_lock
  traffic_collect_no_lock
  node_list_compact
  local node_id
  select_node_for_flow node_id '请选择要查看流量详情的节点' || return 0
  node_show_detail "$node_id"
  printf '\n最近结算历史：\n'
  local entry period upload download total history_entries
  history_entries=$(jq -c --arg id "$node_id" '.cycles[$id].entries[]?' "$HISTORY_FILE") \
    || die '无法读取节点结算历史。'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    period=$(jq -er '.period' <<<"$entry")
    upload=$(jq -er '.upload_bytes' <<<"$entry")
    download=$(jq -er '.download_bytes' <<<"$entry")
    total=$(jq -er '.total_bytes' <<<"$entry")
    printf '%s：上传 %s，下载 %s，合计 %s\n' "$period" "$(format_bytes "$upload")" "$(format_bytes "$download")" "$(format_bytes "$total")"
  done <<<"$history_entries"
}

traffic_quota_flow() {
  acquire_manager_lock
  local node_id node quota_gb quota reset_day candidate_nodes candidate_traffic candidate_history traffic_source quota_policy
  select_node_for_flow node_id '请选择要设置流量限额的节点' || return 0
  node=$(node_by_id "$node_id")
  quota_policy=$(quota_policy_description) || die '无法读取全局配额策略。'
  printf '请输入月流量限额（GB，0=不限；安全上限 9007199.254740991 GB）：\n'
  printf '当前自动停用策略：%s；端口级统计仍非认证账单。\n> ' "$quota_policy"
  IFS= read -r quota_gb || die '读取输入失败。'
  quota=$(bytes_from_gb "$quota_gb" 2>/dev/null || true)
  validate_safe_uint "$quota" || die '请输入 0-9007199.254740991 范围内的非负 GB 数值，例如 500 或 0。'
  reset_day=$(jq -er '.reset_day' <<<"$node")
  prepare_state_candidate_paths quota candidate_nodes candidate_traffic candidate_history \
    || die '无法创建配额事务候选文件。'
  jq --arg id "$node_id" --argjson quota "$quota" '.nodes[] |= if .node_id == $id then .quota_bytes=$quota | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
  mv -f -- "$traffic_source" "$candidate_traffic"
  traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
  mv -f -- "$candidate_nodes.next" "$candidate_nodes"
  traffic_sync_quota_status "$candidate_nodes" "$candidate_traffic" "$node_id" "$quota" "$candidate_nodes.next"
  mv -f -- "$candidate_nodes.next" "$candidate_nodes"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "quota-node-$node_id"; then
    success '月流量限额已更新。'
  else
    error '月流量限额更新失败，已回滚。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '配额事务已结束，但运行时候选文件清理失败。'
  return "$transaction_status"
}

traffic_reset_day_flow() {
  acquire_manager_lock
  local node_id node reset_day quota candidate_nodes candidate_traffic candidate_history traffic_source
  select_node_for_flow node_id '请选择要设置重置日的节点' || return 0
  node=$(node_by_id "$node_id")
  printf '请输入每月重置日（1-28）：\n> '
  IFS= read -r reset_day || die '读取输入失败。'
  validate_reset_day "$reset_day" || die '重置日必须为 1-28。'
  quota=$(jq -er '.quota_bytes' <<<"$node")
  prepare_state_candidate_paths reset candidate_nodes candidate_traffic candidate_history \
    || die '无法创建重置日事务候选文件。'
  jq --arg id "$node_id" --argjson reset_day "$reset_day" '.nodes[] |= if .node_id == $id then .reset_day=$reset_day | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  traffic_source=$(traffic_update_node_settings "$node_id" "$quota" "$reset_day")
  mv -f -- "$traffic_source" "$candidate_traffic"
  traffic_sync_nodes_schedule "$candidate_nodes" "$candidate_traffic" "$candidate_nodes.next"
  mv -f -- "$candidate_nodes.next" "$candidate_nodes"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "reset-day-node-$node_id"; then
    success '流量重置日已更新。'
  else
    error '重置日更新失败，已回滚。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '重置日事务已结束，但运行时候选文件清理失败。'
  return "$transaction_status"
}

bandwidth_flow() {
  acquire_manager_lock
  local node_id node upload_limit download_limit candidate_nodes candidate_traffic candidate_history
  select_node_for_flow node_id '请选择要设置限速的节点' || return 0
  node=$(node_by_id "$node_id")
  printf '请输入上传限速 Mbps（0=不限）：\n> '
  IFS= read -r upload_limit || die '读取输入失败。'
  printf '请输入下载限速 Mbps（0=不限）：\n> '
  IFS= read -r download_limit || die '读取输入失败。'
  if ! validate_limit_mbps "$upload_limit" || ! validate_limit_mbps "$download_limit"; then
    die '限速必须为 0 或非负数字。'
  fi
  prepare_state_candidate_paths bandwidth candidate_nodes candidate_traffic candidate_history \
    || die '无法创建限速事务候选文件。'
  jq --arg id "$node_id" --arg upload "$upload_limit" --arg download "$download_limit" '.nodes[] |= if .node_id == $id then .upload_limit_mbps=($upload|tonumber) | .download_limit_mbps=($download|tonumber) | .updated_at=(now|todateiso8601) else . end' "$NODES_FILE" >"$candidate_nodes"
  install -m 600 -- "$TRAFFIC_FILE" "$candidate_traffic"
  install -m 600 -- "$HISTORY_FILE" "$candidate_history"
  local transaction_status=0
  if apply_state_transaction "$candidate_nodes" "$candidate_traffic" "$candidate_history" "bandwidth-node-$node_id"; then
    success '节点上下行限速已更新。'
  else
    error '限速更新失败，已回滚。'
    transaction_status=1
  fi
  rm -f -- "$candidate_nodes" "$candidate_traffic" "$candidate_history" \
    || warn '限速事务已结束，但运行时候选文件清理失败。'
  return "$transaction_status"
}

singbox_management_flow() {
  local choice
  while true; do
    printf '\nSing-box 管理\n1. 查看状态\n2. 启动\n3. 停止\n4. 重启\n5. 查看最近日志\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1) service_status "$SING_BOX_SERVICE" ;;
      2) run_menu_action singbox_start_action ;;
      3) run_menu_action singbox_stop_action ;;
      4) run_menu_action singbox_restart_action ;;
      5) service_recent_logs "$SING_BOX_SERVICE" ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}

singbox_start_action() {
  acquire_manager_lock
  singbox_start || return 1
  singbox_health_check "$NODES_FILE" || die '启动后健康检查未通过。'
}

singbox_stop_action() {
  acquire_manager_lock
  singbox_stop || return 1
  singbox_confirm_inactive || die '无法确认 sing-box 已停止。'
  success 'sing-box 已停止；定时维护不会擅自重新启动它。'
}

singbox_restart_action() {
  acquire_manager_lock
  singbox_restart || return 1
  singbox_health_check "$NODES_FILE" || die '重启后健康检查未通过。'
}

system_settings_flow() {
  local choice listen_mode listen_address bbr_enabled tfo_kernel_enabled tfo_config_supported
  while true; do
    printf '\n系统设置\n1. 查看系统能力\n2. 检查/启用 BBR\n3. 检查/启用 TCP Fast Open\n4. 刷新流量接口\n5. 查看 tc 流控规则\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1)
        listen_mode=$(manager_state_get listen_mode unknown) || die '无法读取监听模式状态。'
        listen_address=$(manager_state_get listen_address unknown) || die '无法读取监听地址状态。'
        bbr_enabled=$(manager_state_get bbr_enabled false) || die '无法读取 BBR 状态。'
        tfo_kernel_enabled=$(manager_state_get tfo_kernel_enabled false) || die '无法读取 TFO 内核状态。'
        tfo_config_supported=$(manager_state_get tfo_config_supported false) || die '无法读取 TFO 配置状态。'
        printf '系统：%s\n架构：%s\n监听模式：%s（地址 %s）\nBBR：%s\nTFO 内核：%s\nTFO 配置字段：%s\n流量接口：\n' "$HOST_OS_NAME" "$HOST_ARCH" "$listen_mode" "$listen_address" "$bbr_enabled" "$tfo_kernel_enabled" "$tfo_config_supported"
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

system_mutation_transaction_exit_handler() {
  local status=$?
  trap - EXIT
  if [[ "${SYSTEM_MUTATION_TRANSACTION_ACTIVE:-0}" == 1 ]]; then
    (( status != 0 )) || status=1
    set +e
    error '系统设置未完成，正在恢复变更前的 manager、sysctl、内核、服务和配置状态。'
    if install_transaction_restore && install_transaction_clear; then
      warn '系统设置事务已完整回滚。'
    else
      error "系统设置自动回滚未完成；恢复证据保留在 $INSTALL_TRANSACTION_DIR。"
    fi
  fi
  exit "$status"
}

system_mutation_transaction_begin() {
  local phase=$1
  install_transaction_begin || return 1
  SYSTEM_MUTATION_TRANSACTION_ACTIVE=1
  trap system_mutation_transaction_exit_handler EXIT
  install_transaction_set_phase "$phase" || return 1
}

system_mutation_transaction_commit() {
  install_transaction_set_phase committed || return 1
  SYSTEM_MUTATION_TRANSACTION_ACTIVE=0
  if ! install_transaction_clear; then
    warn "系统设置已经提交，但事务日志未能清理；下次启动会仅重试清理：$INSTALL_TRANSACTION_DIR"
  fi
  trap - EXIT
}

system_bbr_action() {
  acquire_manager_lock
  system_mutation_transaction_begin system_bbr || return 1
  configure_bbr || return 1
  system_mutation_transaction_commit || return 1
}

system_tfo_action() {
  acquire_manager_lock
  system_mutation_transaction_begin system_tfo || return 1
  configure_tcp_fast_open_kernel || return 1
  if [[ -x "$SING_BOX_BINARY" ]]; then singbox_config_supports_tfo || return 1; fi
  apply_state_transaction "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" 'system-tfo-update' || return 1
  system_mutation_transaction_commit || return 1
}

system_refresh_interfaces_action() {
  acquire_manager_lock
  traffic_collect_no_lock || return 1
  system_mutation_transaction_begin system_interfaces || return 1
  detect_traffic_interfaces || return 1
  bandwidth_apply_and_check "$NODES_FILE" || return 1
  traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE" || return 1
  system_mutation_transaction_commit || return 1
  success '已刷新流量接口，并重新验证统计/限速规则。'
}

remove_manager_service_files() {
  remove_manager_maintenance_service_files
}

remove_rem_command() {
  if [[ -e /usr/local/bin/rem || -L /usr/local/bin/rem ]]; then
    is_command_from_manager /usr/local/bin/rem || return 0
    rm -f -- /usr/local/bin/rem || return 1
  fi
}

uninstall_validate_managed_runtime() {
  local managed_binary
  if [[ -e "$SING_BOX_CONFIG" || -L "$SING_BOX_CONFIG" ]]; then
    singbox_config_matches_managed_state || {
      error '当前 sing-box 配置与 Ss2022 节点状态生成结果不一致；拒绝把可能由用户修改的配置当作本项目文件删除。'
      return 1
    }
  fi
  managed_binary=$(manager_state_get sing_box_binary_managed false) || return 1
  if [[ "$managed_binary" == true && ( -e "$SING_BOX_BINARY" || -L "$SING_BOX_BINARY" ) ]]; then
    [[ -f "$SING_BOX_BINARY" && ! -L "$SING_BOX_BINARY" && -x "$SING_BOX_BINARY" && -O "$SING_BOX_BINARY" ]] || {
      error '记录为本项目管理的 sing-box 现存路径类型或所有者发生变化；拒绝删除。'
      return 1
    }
    validate_managed_singbox_binary_identity || return 1
  fi
}

uninstall_flow() {
  require_root
  assert_standard_destructive_paths
  local mode managed_binary presence_status
  printf '\n卸载模式：\n1. 仅删除程序，保留配置和数据\n2. 删除程序和运行配置，保留备份\n3. 完全卸载\n0. 返回\n> '
  IFS= read -r mode || die '读取输入失败。'
  [[ "$mode" == 1 || "$mode" == 2 || "$mode" == 3 ]] || return 0
  prompt_yes_no "确认执行卸载模式 $mode？本项目不会修改任何防火墙规则" n || return 0
  acquire_manager_lock
  if [[ "$mode" != 1 ]]; then
    uninstall_validate_managed_runtime || die '卸载所有权预检失败，尚未删除项目运行配置或 sing-box 二进制。'
  fi
  remove_manager_service_files || die '流量维护服务无法确认停止/禁用，卸载已停止，尚未删除 manager 程序。'
  if [[ "$mode" != 1 ]]; then
    if service_definition_path_present "$SING_BOX_SERVICE"; then
      service_definition_is_managed "$SING_BOX_SERVICE" \
        || die 'sing-box 服务定义已被外部替换；拒绝停止、禁用或删除它。'
    else
      presence_status=0
      service_exists "$SING_BOX_SERVICE" || presence_status=$?
      (( presence_status != 2 )) || die '无法可靠查询同名 sing-box 服务是否存在；卸载已停止。'
      (( presence_status != 0 )) || die '检测到同名但不受 Ss2022 管理的 sing-box 服务；卸载已停止。'
    fi
    local active_status=0 enabled_status=0
    singbox_is_active || active_status=$?
    (( active_status != 2 )) || die '无法可靠查询 sing-box 运行状态；卸载已停止。'
    if (( active_status == 0 )); then
      singbox_stop >/dev/null 2>&1 || die 'sing-box 停止失败；拒绝在进程仍运行时删除二进制或配置。'
      singbox_confirm_inactive || die '无法确认 sing-box 已停止；卸载已安全停止。'
    fi
    service_is_enabled "$SING_BOX_SERVICE" || enabled_status=$?
    (( enabled_status != 2 )) || die '无法可靠查询 sing-box 启用状态；卸载已停止。'
    if (( enabled_status == 0 )); then
      service_disable "$SING_BOX_SERVICE" >/dev/null 2>&1 || die 'sing-box 服务禁用失败；卸载已停止。'
      service_confirm_disabled "$SING_BOX_SERVICE" || die '无法确认 sing-box 服务已禁用；卸载已停止。'
    fi
  fi
  bandwidth_remove_manager_rules || die '无法证明并清理全部 Ss2022 tc 规则；卸载已停止。'
  remove_rem_command || die 'rem 命令清理失败；卸载已停止。'
  if [[ "$mode" != 1 ]]; then
    service_remove_managed_definition "$SING_BOX_SERVICE" || die 'sing-box 服务定义清理失败；卸载已停止。'
    managed_binary=$(manager_state_get sing_box_binary_managed false) || die '无法读取 sing-box 二进制所有权状态。'
    if [[ "$managed_binary" == true ]]; then
      rm -f -- "$SING_BOX_BINARY" || die 'sing-box 二进制删除失败；卸载未完成。'
    fi
    rm -f -- "$SING_BOX_CONFIG" || die 'sing-box 配置删除失败；卸载未完成。'
    # Both destructive modes remove the state that records the original
    # kernel values, so restore them before deleting manager.json.
    restore_kernel_settings_on_uninstall || die '安装前内核参数恢复失败；已保留 manager 状态以便重试。'
    if [[ "$mode" == 2 ]]; then
      rm -f -- "$MANAGER_STATE" "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" "$COUNTERS_FILE" "$INTERFACES_FILE" "$DATA_DIR/bandwidth-plan.json" \
        || die '运行状态文件删除失败；卸载未完成。'
      find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf -- {} + 2>/dev/null \
        || die '配置目录清理失败；备份仍保留，卸载未完成。'
      rm -rf -- "$DATA_DIR" || die '数据目录删除失败；卸载未完成。'
    else
      rm -rf -- "$CONFIG_DIR" "$DATA_DIR" || die '配置或数据目录删除失败；完全卸载未完成。'
    fi
  fi
  rm -rf -- "$PROGRAM_DIR" || die 'manager 程序目录删除失败；卸载未完成。'
  durable_sync_path /opt || die 'manager 程序目录删除未能持久同步。'
  release_manager_lock
  if [[ "$mode" != 1 ]]; then
    rm -rf -- "$RUNTIME_DIR" || die '运行目录删除失败；卸载未完整结束。'
  fi
  success '卸载流程完成。本项目没有修改或删除 iptables/nftables/UFW/firewalld/ipset 规则。'
  exit 0
}

main_menu() {
  initialize_state_files
  while true; do
    local count total singbox_summary total_text
    count=$(node_count) || die '无法读取节点数量。'
    total=$(jq -n --slurpfile nodes "$NODES_FILE" --slurpfile traffic "$TRAFFIC_FILE" '
      reduce ($nodes[0].nodes[]?.node_id) as $id (0; . + (($traffic[0].nodes[$id].current_upload_bytes // 0) + ($traffic[0].nodes[$id].current_download_bytes // 0)))') \
      || die '无法汇总节点流量。'
    singbox_summary=$(singbox_status_summary) || die '无法查询 sing-box 状态。'
    total_text=$(format_bytes "$total") || die '无法格式化节点流量。'
    printf '\n================================\n       REM Proxy Manager\n================================\n\nSing-box：%s\n节点数量：%s\n本周期总流量：%s\n\n' "$singbox_summary" "$count" "$total_text"
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
