#!/usr/bin/env bash
# Configuration snapshots and transactional state changes.

validate_candidate_nodes() {
  local nodes_source=$1
  validate_nodes_file_semantic "$nodes_source" || die '候选节点数据库语义无效。'

  local current_id current_port current_status current_protocol live_port live_status live_protocol port_state node_lines
  node_lines=$(jq -c '.nodes[]' "$nodes_source") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    current_id=$(jq -er '.node_id' <<<"$node") || return 1
    current_port=$(jq -er '.port' <<<"$node") || return 1
    current_status=$(jq -er '.status' <<<"$node") || return 1
    current_protocol=$(node_protocol "$node") || return 1
    live_protocol=$(jq -er --arg id "$current_id" '
      [.nodes[] | select(.node_id == $id)]
      | if length == 0 then ""
        elif length == 1 then (.[0].protocol // "shadowsocks")
        else error("duplicate live node id") end
    ' "$NODES_FILE") || return 1
    if [[ -n "$live_protocol" && "$live_protocol" != "$current_protocol" ]]; then
      die "Node ID $current_id 的协议不能从 $(protocol_label "$live_protocol") 转换为 $(protocol_label "$current_protocol")。"
    fi
    # Disabled nodes do not bind their reserved port.  Do not let a service
    # that started after such a node was disabled block unrelated changes.
    [[ "$current_status" == enabled ]] || continue
    port_state=0
    if [[ "$current_protocol" == shadowsocks ]]; then
      system_port_in_use "$current_port" || port_state=$?
    else
      system_port_in_use_for_protocol "$current_port" "$current_protocol" || port_state=$?
    fi
    (( port_state != 2 )) || die "无法可靠查询候选端口 $current_port 的协议监听状态。"
    if (( port_state == 0 )); then
      live_port=$(jq -r --arg id "$current_id" '.nodes[] | select(.node_id == $id) | .port' "$NODES_FILE") || return 1
      live_status=$(jq -r --arg id "$current_id" '.nodes[] | select(.node_id == $id) | .status' "$NODES_FILE") || return 1
      if [[ "$live_status" != enabled || "$live_port" != "$current_port" ]]; then
        die "候选端口 $current_port 已被系统其他服务占用。"
      fi
      if ! singbox_is_active || ! singbox_owns_node_port "$current_port" '' "$current_protocol"; then
        die "候选端口 $current_port 虽与原节点相同，但当前监听者不是唯一的 sing-box 进程。"
      fi
    fi
  done <<<"$node_lines"
}

backup_create_snapshot() {
  local reason=$1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ && ${#reason} -le 160 ]] || {
    error '备份原因包含不安全字符或过长。'
    return 1
  }
  ensure_dir "$BACKUP_DIR" 700 || return 1
  local timestamp backup_path created_at sing_box_version
  timestamp=$(timestamp_compact) || return 1
  backup_path="$BACKUP_DIR/$timestamp-$reason"
  local suffix=1
  while [[ -e "$backup_path" || -L "$backup_path" ]]; do
    backup_path="$BACKUP_DIR/$timestamp-$reason-$suffix"
    ((suffix++))
  done
  local preparing
  preparing=$(mktemp -d "$BACKUP_DIR/.snapshot.prepare.XXXXXXXX") || return 1
  [[ -d "$preparing" && ! -L "$preparing" ]] || { rm -rf -- "$preparing"; return 1; }
  chmod 700 -- "$preparing" || { rm -rf -- "$preparing"; return 1; }
  if [[ ! -f "$NODES_FILE" || -L "$NODES_FILE" || ! -f "$TRAFFIC_FILE" || -L "$TRAFFIC_FILE" \
    || ! -f "$HISTORY_FILE" || -L "$HISTORY_FILE" ]]; then
    error '节点、流量或历史状态缺失/为符号链接，拒绝创建不可恢复的备份。'
    rm -rf -- "$preparing"
    return 1
  fi
  if ! validate_nodes_file_semantic "$NODES_FILE" \
    || ! validate_traffic_file_semantic "$TRAFFIC_FILE" "$NODES_FILE" \
    || ! validate_history_file_semantic "$HISTORY_FILE"; then
    error '当前节点、流量或历史状态语义无效，拒绝发布损坏备份。'
    rm -rf -- "$preparing"
    return 1
  fi
  install -m 600 -- "$NODES_FILE" "$preparing/nodes.json" || { rm -rf -- "$preparing"; return 1; }
  install -m 600 -- "$TRAFFIC_FILE" "$preparing/traffic.json" || { rm -rf -- "$preparing"; return 1; }
  install -m 600 -- "$HISTORY_FILE" "$preparing/traffic-history.json" || { rm -rf -- "$preparing"; return 1; }
  if [[ -e "$MANAGER_STATE" || -L "$MANAGER_STATE" ]]; then
    [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]] \
      && validate_manager_state_semantic "$MANAGER_STATE" \
      || { error 'manager 状态不是可备份的常规有效文件。'; rm -rf -- "$preparing"; return 1; }
    install -m 600 -- "$MANAGER_STATE" "$preparing/manager.json" \
      || { rm -rf -- "$preparing"; return 1; }
  fi
  if [[ -e "$SING_BOX_CONFIG" || -L "$SING_BOX_CONFIG" ]]; then
    [[ -f "$SING_BOX_CONFIG" && ! -L "$SING_BOX_CONFIG" ]] || {
      error 'sing-box 配置不是常规文件或为符号链接，拒绝在常规备份中跟随。'
      rm -rf -- "$preparing"
      return 1
    }
    install -m 600 -- "$SING_BOX_CONFIG" "$preparing/config.json" \
      || { rm -rf -- "$preparing"; return 1; }
  fi
  if [[ -e "$SING_BOX_BINARY" || -L "$SING_BOX_BINARY" ]]; then
    [[ -f "$SING_BOX_BINARY" && ! -L "$SING_BOX_BINARY" ]] || {
      error 'sing-box 二进制不是常规文件或为符号链接，拒绝在常规备份中跟随。'
      rm -rf -- "$preparing"
      return 1
    }
  fi
  if [[ -x "$SING_BOX_BINARY" ]]; then
    install -m 755 -- "$SING_BOX_BINARY" "$preparing/sing-box" \
      || { rm -rf -- "$preparing"; return 1; }
  fi
  created_at=$(timestamp_iso) || { rm -rf -- "$preparing"; return 1; }
  # Snapshot metadata is informational.  Read the already-validated manager
  # record instead of executing the binary here: during an install takeover,
  # schema migration can run before a foreign sing-box file has been replaced
  # and had its ownership/digest established.
  sing_box_version=''
  if [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]]; then
    sing_box_version=$(manager_state_get sing_box_version '') || { rm -rf -- "$preparing"; return 1; }
  fi
  jq -n \
    --arg reason "$reason" \
    --arg created_at "$created_at" \
    --arg manager_version "$MANAGER_VERSION" \
    --arg sing_box_version "$sing_box_version" \
    '{schema_version:1,artifact:"ss2022-state-snapshot",reason:$reason,created_at:$created_at,manager_version:$manager_version,sing_box_version:$sing_box_version}' \
    >"$preparing/metadata.json" || { rm -rf -- "$preparing"; return 1; }
  chmod 600 -- "$preparing"/* || { rm -rf -- "$preparing"; return 1; }
  durable_sync_tree "$preparing" || { rm -rf -- "$preparing"; return 1; }
  atomic_move_directory_to_absent_path "$preparing" "$backup_path" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$BACKUP_DIR" || return 1
  printf '%s' "$backup_path"
}

backup_snapshot_is_managed() {
  local backup=$1 name
  [[ "$backup" == "$BACKUP_DIR/"* && "$backup" != "$BACKUP_DIR/" ]] || return 1
  name=${backup##*/}
  [[ "$name" =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9._-]+$ ]] || return 1
  [[ -d "$backup" && ! -L "$backup" ]] || return 1
  local required
  for required in metadata.json nodes.json traffic.json traffic-history.json; do
    [[ -f "$backup/$required" && ! -L "$backup/$required" ]] || return 1
  done
  local optional
  for optional in config.json sing-box manager.json; do
    if [[ -e "$backup/$optional" || -L "$backup/$optional" ]]; then
      [[ -f "$backup/$optional" && ! -L "$backup/$optional" ]] || return 1
    fi
  done
  jq -e '
    type == "object"
    and ((.schema_version // 1) == 1)
    and ((.artifact // "ss2022-state-snapshot") == "ss2022-state-snapshot")
    and (.reason | type == "string" and length >= 1 and length <= 160 and test("^[A-Za-z0-9._-]+$"))
    and (.created_at | type == "string" and ((try fromdateiso8601 catch null) != null))
    and (.manager_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$"))
    and (.sing_box_version | type == "string")
  ' "$backup/metadata.json" >/dev/null 2>&1 || return 1
  validate_nodes_file_semantic "$backup/nodes.json" || return 1
  validate_traffic_file_semantic "$backup/traffic.json" "$backup/nodes.json" || return 1
  validate_history_file_semantic "$backup/traffic-history.json" || return 1
  if [[ -f "$backup/manager.json" ]]; then
    validate_manager_state_semantic "$backup/manager.json" || return 1
  fi
}

backup_managed_names() {
  local backup list_file
  list_file=$(runtime_temp_file backup-directories) || return 1
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 >"$list_file" 2>/dev/null \
    || { rm -f -- "$list_file"; return 1; }
  while IFS= read -r -d '' backup; do
    backup_snapshot_is_managed "$backup" || continue
    printf '%s\n' "${backup##*/}"
  done <"$list_file"
  rm -f -- "$list_file" || return 1
}

backup_restore_reason() {
  local backup_name=$1 digest
  [[ "$backup_name" =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9._-]+$ ]] || return 1
  digest=$(printf '%s' "$backup_name" | sha256sum | awk '{print substr($1,1,20)}') || return 1
  [[ "$digest" =~ ^[a-f0-9]{20}$ ]] || return 1
  printf 'restore-%s' "$digest"
}

backup_prune() {
  local -a backups=()
  local names sorted=''
  names=$(backup_managed_names) || return 1
  if [[ -n "$names" ]]; then
    sorted=$(printf '%s\n' "$names" | sort) || return 1
  fi
  [[ -z "$sorted" ]] || mapfile -t backups <<<"$sorted"
  local count=${#backups[@]}
  local remove_count=$((count - DEFAULT_CONFIG_BACKUP_RETENTION))
  local index target
  (( remove_count > 0 )) || return 0
  for ((index=0; index<remove_count; index++)); do
    target="$BACKUP_DIR/${backups[$index]}"
    [[ "$target" == "$BACKUP_DIR/"* && "$target" != "$BACKUP_DIR/" ]] || die '备份清理目标不安全。'
    rm -rf -- "$target" || return 1
  done
  durable_sync_path "$BACKUP_DIR" || return 1
}

state_transaction_begin() {
  local reason=$1 service_was_active=$2
  [[ "$reason" =~ ^[A-Za-z0-9._:-]{1,160}$ ]] || return 1
  [[ "$service_was_active" == 0 || "$service_was_active" == 1 ]] || return 1
  [[ ! -e "$STATE_TRANSACTION_DIR" && ! -L "$STATE_TRANSACTION_DIR" ]] \
    || { error '存在尚未恢复的状态事务，拒绝开始新事务。'; return 1; }
  local path preparing
  for path in "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE"; do
    [[ -f "$path" && ! -L "$path" ]] || {
      error "状态事务源不是常规文件或为符号链接：$path"
      return 1
    }
  done
  if [[ -e "$SING_BOX_CONFIG" || -L "$SING_BOX_CONFIG" ]]; then
    [[ -f "$SING_BOX_CONFIG" && ! -L "$SING_BOX_CONFIG" ]] || {
      error 'sing-box 配置不是常规文件或为符号链接，拒绝建立状态事务。'
      return 1
    }
  fi
  preparing=$(mktemp -d "${STATE_TRANSACTION_DIR}.prepare.XXXXXXXX") || return 1
  [[ -d "$preparing" && ! -L "$preparing" ]] || { rm -rf -- "$preparing"; return 1; }
  chmod 700 -- "$preparing" || { rm -rf -- "$preparing"; return 1; }
  install -m 600 -- "$NODES_FILE" "$preparing/nodes.json" || { rm -rf -- "$preparing"; return 1; }
  install -m 600 -- "$TRAFFIC_FILE" "$preparing/traffic.json" || { rm -rf -- "$preparing"; return 1; }
  install -m 600 -- "$HISTORY_FILE" "$preparing/traffic-history.json" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$preparing/nodes.json" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$preparing/traffic.json" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$preparing/traffic-history.json" || { rm -rf -- "$preparing"; return 1; }
  local had_config=false
  if [[ -f "$SING_BOX_CONFIG" ]]; then
    install -m 600 -- "$SING_BOX_CONFIG" "$preparing/config.json" || { rm -rf -- "$preparing"; return 1; }
    durable_sync_path "$preparing/config.json" || { rm -rf -- "$preparing"; return 1; }
    had_config=true
  fi
  local journal_tmp created_at
  journal_tmp=$(runtime_temp_file state-transaction-journal) || { rm -rf -- "$preparing"; return 1; }
  created_at=$(timestamp_iso) || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  jq -n --arg reason "$reason" --arg created_at "$created_at" --argjson active "$service_was_active" --argjson had_config "$had_config" \
    '{schema_version:1,phase:"prepared",reason:$reason,created_at:$created_at,service_was_active:($active == 1),had_config:$had_config}' \
    >"$journal_tmp" || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  install -m 600 -- "$journal_tmp" "$preparing/journal.json" || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  rm -f -- "$journal_tmp" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$preparing/journal.json" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$preparing" || { rm -rf -- "$preparing"; return 1; }
  atomic_move_directory_to_absent_path "$preparing" "$STATE_TRANSACTION_DIR" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_path "$CONFIG_DIR" || return 1
}

state_transaction_set_phase() {
  local phase=$1 journal="$STATE_TRANSACTION_DIR/journal.json" temporary updated_at
  [[ "$phase" =~ ^[a-z_]+$ && -f "$journal" ]] || return 1
  [[ ! -L "$journal" ]] || return 1
  temporary=$(runtime_temp_file state-transaction-phase) || return 1
  updated_at=$(timestamp_iso) || { rm -f -- "$temporary"; return 1; }
  jq --arg phase "$phase" --arg updated_at "$updated_at" '.phase=$phase | .updated_at=$updated_at' "$journal" >"$temporary" \
    || { rm -f -- "$temporary"; return 1; }
  atomic_json_write "$temporary" "$journal" 600 || { rm -f -- "$temporary"; return 1; }
  rm -f -- "$temporary" || warn '状态事务阶段已持久写入，但阶段暂存文件清理失败。'
}

state_transaction_clear() {
  [[ "$STATE_TRANSACTION_DIR" == "$CONFIG_DIR/state-transaction" && "$STATE_TRANSACTION_DIR" != '/' ]] || return 1
  rm -rf -- "$STATE_TRANSACTION_DIR" || return 1
  durable_sync_path "$CONFIG_DIR" || return 1
}

state_transaction_restore() {
  local journal="$STATE_TRANSACTION_DIR/journal.json"
  [[ -d "$STATE_TRANSACTION_DIR" && ! -L "$STATE_TRANSACTION_DIR" \
    && -f "$journal" && ! -L "$journal" \
    && -f "$STATE_TRANSACTION_DIR/nodes.json" && ! -L "$STATE_TRANSACTION_DIR/nodes.json" \
    && -f "$STATE_TRANSACTION_DIR/traffic.json" && ! -L "$STATE_TRANSACTION_DIR/traffic.json" \
    && -f "$STATE_TRANSACTION_DIR/traffic-history.json" && ! -L "$STATE_TRANSACTION_DIR/traffic-history.json" ]] || return 1
  jq -e '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    .schema_version == 1
    and (.phase | type == "string" and test("^[a-z_]+$") and . != "committed")
    and (.reason | type == "string" and length >= 1 and length <= 160)
    and (.created_at | iso)
    and ((has("updated_at") | not) or (.updated_at | iso))
    and (.service_was_active | type == "boolean")
    and (.had_config | type == "boolean")
  ' "$journal" >/dev/null 2>&1 || return 1
  validate_nodes_file_semantic "$STATE_TRANSACTION_DIR/nodes.json" || return 1
  validate_traffic_file_semantic "$STATE_TRANSACTION_DIR/traffic.json" "$STATE_TRANSACTION_DIR/nodes.json" || return 1
  validate_history_file_semantic "$STATE_TRANSACTION_DIR/traffic-history.json" || return 1
  local service_was_active had_config
  # jq -e deliberately exits non-zero when the selected value is false.  The
  # journal schema was validated above, so stringify both booleans before using
  # -e and preserve false as a valid recovery state.
  service_was_active=$(jq -er '.service_was_active | tostring' "$journal") || return 1
  had_config=$(jq -er '.had_config | tostring' "$journal") || return 1
  if [[ "$had_config" == true ]]; then
    [[ -f "$STATE_TRANSACTION_DIR/config.json" && ! -L "$STATE_TRANSACTION_DIR/config.json" ]] || return 1
    # Validate every durable snapshot before the first live state file is
    # replaced.  A corrupt config journal must not leave a half-restored set of
    # nodes/traffic files before the official parser reports the damage.
    singbox_check_config "$STATE_TRANSACTION_DIR/config.json" >/dev/null 2>&1 || return 1
  fi
  atomic_json_write "$STATE_TRANSACTION_DIR/nodes.json" "$NODES_FILE" 600 || return 1
  atomic_json_write "$STATE_TRANSACTION_DIR/traffic.json" "$TRAFFIC_FILE" 600 || return 1
  atomic_json_write "$STATE_TRANSACTION_DIR/traffic-history.json" "$HISTORY_FILE" 600 || return 1
  if [[ "$had_config" == true ]]; then
    atomic_json_write "$STATE_TRANSACTION_DIR/config.json" "$SING_BOX_CONFIG" 600 || return 1
  else
    rm -f -- "$SING_BOX_CONFIG" || return 1
    durable_sync_path "$(dirname -- "$SING_BOX_CONFIG")" || return 1
  fi
  if [[ "$service_was_active" == true ]]; then
    singbox_restart >/dev/null 2>&1 || return 1
  else
    singbox_stop >/dev/null 2>&1 || return 1
    singbox_confirm_inactive || return 1
  fi
  bandwidth_apply_and_check "$NODES_FILE" >/dev/null 2>&1 || return 1
  traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE" >/dev/null 2>&1 || return 1
  if [[ "$service_was_active" == true ]]; then
    singbox_health_check "$NODES_FILE" >/dev/null 2>&1 || return 1
  elif [[ "$had_config" == true ]]; then
    singbox_confirm_inactive || return 1
    singbox_check_config "$SING_BOX_CONFIG" >/dev/null 2>&1 || return 1
  else
    singbox_confirm_inactive || return 1
    [[ ! -e "$SING_BOX_CONFIG" ]] || return 1
  fi
}

recover_incomplete_state_transaction() {
  [[ -e "$STATE_TRANSACTION_DIR" || -L "$STATE_TRANSACTION_DIR" ]] || return 0
  local journal="$STATE_TRANSACTION_DIR/journal.json" phase
  [[ -d "$STATE_TRANSACTION_DIR" && ! -L "$STATE_TRANSACTION_DIR" && -f "$journal" && ! -L "$journal" ]] \
    || die "状态事务日志不完整或路径类型不安全；恢复证据保留在 $STATE_TRANSACTION_DIR，请勿继续修改配置。"
  phase=$(jq -er '.phase | select(type == "string")' "$journal" 2>/dev/null) \
    || die "状态事务日志无效；恢复证据保留在 $STATE_TRANSACTION_DIR，请勿继续修改配置。"
  if [[ "$phase" == committed ]]; then
    warn '检测到已提交但尚未清理的状态事务；仅清理提交日志，不回滚已生效状态。'
    state_transaction_clear || die "已提交状态有效，但无法清理事务日志：$STATE_TRANSACTION_DIR"
    return 0
  fi
  warn '检测到上次操作未完成，正在从持久事务日志恢复提交前状态。'
  if ! state_transaction_restore; then
    die "持久事务恢复失败；恢复证据保留在 $STATE_TRANSACTION_DIR，请勿继续修改配置。"
  fi
  state_transaction_clear || die "旧状态已恢复，但无法清理事务日志：$STATE_TRANSACTION_DIR"
  success '未完成的状态事务已完整回滚。'
}

state_transaction_rollback_after_failure() {
  state_transaction_set_phase rolling_back >/dev/null 2>&1 || true
  if ! state_transaction_restore; then
    error "自动回滚未能完成；持久恢复证据保留在 $STATE_TRANSACTION_DIR。下次启动会再次恢复。"
    return 1
  fi
  if ! state_transaction_clear; then
    error "旧状态已经恢复，但事务日志无法清理：$STATE_TRANSACTION_DIR"
    return 1
  fi
  return 0
}

install_transaction_target_names() {
  printf '%s\t%s\n' \
    program "$PROGRAM_DIR" \
    manager-state "$MANAGER_STATE" \
    nodes "$NODES_FILE" \
    traffic "$TRAFFIC_FILE" \
    history "$HISTORY_FILE" \
    interfaces "$INTERFACES_FILE" \
    bandwidth-plan "$DATA_DIR/bandwidth-plan.json" \
    sing-box-binary "$SING_BOX_BINARY" \
    sing-box-config "$SING_BOX_CONFIG" \
    rem /usr/local/bin/rem \
    sysctl "$MANAGED_SYSCTL_FILE"
}

install_transaction_service_names() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    printf '%s\n' "$SING_BOX_SERVICE" "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"
  else
    printf '%s\n' "$SING_BOX_SERVICE" "$OPENRC_TRAFFIC_SERVICE"
  fi
}

install_transaction_sync_path_state() {
  local path=$1 parent
  if [[ -d "$path" && ! -L "$path" ]]; then
    durable_sync_tree "$path" || return 1
  elif [[ -f "$path" && ! -L "$path" ]]; then
    durable_sync_path "$path" || return 1
  fi
  parent=$(dirname -- "$path") || return 1
  [[ -d "$parent" ]] || return 1
  durable_sync_path "$parent"
}

install_transaction_sync_current_targets() {
  # The committed journal is the point after which startup will no longer
  # roll back. Flush every mutable target (and deletion-bearing parent) first,
  # so that marker can never outrun the data it declares committed.
  local name path index=0
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    install_transaction_sync_path_state "$path" || return 1
  done < <(install_transaction_target_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=$(service_definition_path "$name") || return 1
    install_transaction_sync_path_state "$path" || return 1
    index=$((index + 1))
  done < <(install_transaction_service_names)
  : "$index"

  local enablement_dir
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for enablement_dir in "$SYSTEMD_DIR" "$SYSTEMD_DIR/multi-user.target.wants" "$SYSTEMD_DIR/timers.target.wants"; do
      [[ ! -d "$enablement_dir" ]] || durable_sync_path "$enablement_dir" || return 1
    done
  else
    for enablement_dir in /etc/runlevels /etc/runlevels/default; do
      [[ ! -d "$enablement_dir" ]] || durable_sync_path "$enablement_dir" || return 1
    done
  fi
}

install_transaction_snapshot_target() {
  local preparing=$1 name=$2 path=$3
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -f "$path" || -d "$path" || -L "$path" ]] || {
      error "拒绝快照设备、套接字或其他特殊路径：$path"
      return 1
    }
    cp -a -- "$path" "$preparing/$name.present" || return 1
  else
    : >"$preparing/$name.absent" || return 1
  fi
}

install_transaction_transient_path_is_safe() {
  local path=$1
  [[ "$path" =~ ^/opt/ss-manager\.(install|update)-(new|old|invalid)\.[0-9]+$ ]]
}

install_transaction_cleanup_transient_paths() {
  local journal=$1 path paths
  paths=$(jq -r '.transient_paths // [] | .[]' "$journal") || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    install_transaction_transient_path_is_safe "$path" || return 1
    rm -rf -- "$path" || return 1
  done <<<"$paths"
  durable_sync_path /opt || return 1
}

install_transaction_begin() {
  assert_standard_destructive_paths
  [[ ! -e "$INSTALL_TRANSACTION_DIR" && ! -L "$INSTALL_TRANSACTION_DIR" ]] \
    || { error '存在尚未恢复的安装事务，拒绝开始新的安装/修复。'; return 1; }
  [[ ! -e "$STATE_TRANSACTION_DIR" && ! -L "$STATE_TRANSACTION_DIR" ]] \
    || { error '存在尚未恢复的状态事务，拒绝在其上建立安装事务。'; return 1; }
  local preparing name path service_path index=0 transient transient_json='[]'
  local active_status enabled_status
  for transient in "$@"; do
    install_transaction_transient_path_is_safe "$transient" || return 1
    transient_json=$(jq -c --arg path "$transient" '. + [$path]' <<<"$transient_json") || return 1
  done
  preparing=$(mktemp -d "${INSTALL_TRANSACTION_DIR}.prepare.XXXXXXXX") || return 1
  [[ -d "$preparing" && ! -L "$preparing" ]] || { rm -rf -- "$preparing"; return 1; }
  chmod 700 -- "$preparing" || { rm -rf -- "$preparing"; return 1; }
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    install_transaction_snapshot_target "$preparing" "$name" "$path" || { rm -rf -- "$preparing"; return 1; }
  done < <(install_transaction_target_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    service_path=$(service_definition_path "$name") || { rm -rf -- "$preparing"; return 1; }
    install_transaction_snapshot_target "$preparing" "service-$index" "$service_path" || { rm -rf -- "$preparing"; return 1; }
    enabled_status=0
    service_is_enabled "$name" || enabled_status=$?
    (( enabled_status != 2 )) || { rm -rf -- "$preparing"; return 1; }
    if (( enabled_status == 0 )); then : >"$preparing/service-$index.enabled" || { rm -rf -- "$preparing"; return 1; }; fi
    active_status=0
    service_is_active "$name" || active_status=$?
    (( active_status != 2 )) || { rm -rf -- "$preparing"; return 1; }
    if (( active_status == 0 )); then : >"$preparing/service-$index.active" || { rm -rf -- "$preparing"; return 1; }; fi
    index=$((index + 1))
  done < <(install_transaction_service_names)
  local active=false
  active_status=0
  singbox_is_active || active_status=$?
  (( active_status != 2 )) || { rm -rf -- "$preparing"; return 1; }
  if (( active_status == 0 )); then active=true; fi
  local bbr_current tfo_current journal_tmp created_at
  bbr_current=$(sysctl_read net.ipv4.tcp_congestion_control) || { rm -rf -- "$preparing"; return 1; }
  tfo_current=$(sysctl_read net.ipv4.tcp_fastopen) || { rm -rf -- "$preparing"; return 1; }
  journal_tmp=$(runtime_temp_file install-transaction-journal) || { rm -rf -- "$preparing"; return 1; }
  created_at=$(timestamp_iso) || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  jq -n --arg created_at "$created_at" --arg init_system "$INIT_SYSTEM" --argjson active "$active" \
    --argjson transient_paths "$transient_json" \
    --arg bbr "$bbr_current" --arg tfo "$tfo_current" \
    '{schema_version:1,phase:"prepared",created_at:$created_at,init_system:$init_system,service_was_active:$active,bbr_previous:$bbr,tfo_previous:$tfo,transient_paths:$transient_paths}' \
    >"$journal_tmp" || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  install -m 600 -- "$journal_tmp" "$preparing/journal.json" || { rm -rf -- "$preparing"; rm -f -- "$journal_tmp"; return 1; }
  rm -f -- "$journal_tmp" || { rm -rf -- "$preparing"; return 1; }
  durable_sync_tree "$preparing" || { rm -rf -- "$preparing"; return 1; }
  atomic_move_directory_to_absent_path "$preparing" "$INSTALL_TRANSACTION_DIR" || { rm -rf -- "$preparing"; return 1; }
  INSTALL_TRANSACTION_RUNTIME_ACTIVE=1
  durable_sync_path "$CONFIG_DIR" || return 1
}

install_transaction_set_phase() {
  local phase=$1 journal="$INSTALL_TRANSACTION_DIR/journal.json" temporary updated_at
  [[ "$phase" =~ ^[a-z_]+$ && -f "$journal" ]] || return 1
  [[ ! -L "$journal" ]] || return 1
  if [[ "$phase" == committed ]]; then
    install_transaction_sync_current_targets || return 1
  fi
  temporary=$(runtime_temp_file install-transaction-phase) || return 1
  updated_at=$(timestamp_iso) || { rm -f -- "$temporary"; return 1; }
  jq --arg phase "$phase" --arg updated_at "$updated_at" '.phase=$phase | .updated_at=$updated_at' "$journal" >"$temporary" \
    || { rm -f -- "$temporary"; return 1; }
  atomic_json_write "$temporary" "$journal" 600 || { rm -f -- "$temporary"; return 1; }
  rm -f -- "$temporary" || warn '安装事务阶段已持久写入，但阶段暂存文件清理失败。'
}

install_transaction_restore_target() {
  local name=$1 path=$2
  local present="$INSTALL_TRANSACTION_DIR/$name.present" absent="$INSTALL_TRANSACTION_DIR/$name.absent"
  if [[ -e "$present" || -L "$present" ]]; then
    if [[ "$path" == "$PROGRAM_DIR" ]]; then
      [[ "$path" == /opt/ss-manager ]] || return 1
      rm -rf -- "$path" || return 1
    else
      rm -rf -- "$path" || return 1
    fi
    local parent
    parent=$(dirname -- "$path") || return 1
    [[ -d "$parent" ]] || install -d -m 755 -- "$parent" || return 1
    cp -a -- "$present" "$path" || return 1
    if [[ -d "$path" && ! -L "$path" ]]; then
      durable_sync_tree "$path" || return 1
    elif [[ -f "$path" && ! -L "$path" ]]; then
      durable_sync_path "$path" || return 1
    fi
    durable_sync_path "$parent" || return 1
  elif [[ -f "$absent" ]]; then
    if [[ "$path" == "$PROGRAM_DIR" ]]; then
      [[ "$path" == /opt/ss-manager ]] || return 1
    fi
    rm -rf -- "$path" || return 1
    durable_sync_path "$(dirname -- "$path")" || return 1
  else
    return 1
  fi
}

install_transaction_validate_snapshot() {
  local name path index=0 present absent present_count absent_count
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    present="$INSTALL_TRANSACTION_DIR/$name.present"
    absent="$INSTALL_TRANSACTION_DIR/$name.absent"
    present_count=0
    absent_count=0
    if [[ -e "$present" || -L "$present" ]]; then
      [[ -f "$present" || -d "$present" || -L "$present" ]] || return 1
      present_count=1
    fi
    [[ -f "$absent" && ! -L "$absent" ]] && absent_count=1
    (( present_count + absent_count == 1 )) || return 1
  done < <(install_transaction_target_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    present="$INSTALL_TRANSACTION_DIR/service-$index.present"
    absent="$INSTALL_TRANSACTION_DIR/service-$index.absent"
    present_count=0
    absent_count=0
    if [[ -e "$present" || -L "$present" ]]; then
      [[ -f "$present" || -d "$present" || -L "$present" ]] || return 1
      present_count=1
    fi
    [[ -f "$absent" && ! -L "$absent" ]] && absent_count=1
    (( present_count + absent_count == 1 )) || return 1
    for path in "$INSTALL_TRANSACTION_DIR/service-$index.enabled" "$INSTALL_TRANSACTION_DIR/service-$index.active"; do
      if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || return 1
      fi
    done
    index=$((index + 1))
  done < <(install_transaction_service_names)
}

install_transaction_restore() {
  assert_standard_destructive_paths
  local journal="$INSTALL_TRANSACTION_DIR/journal.json"
  [[ -d "$INSTALL_TRANSACTION_DIR" && ! -L "$INSTALL_TRANSACTION_DIR" && -f "$journal" && ! -L "$journal" ]] || return 1
  jq -e --arg init_system "$INIT_SYSTEM" '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    .schema_version == 1
    and (.phase | type == "string" and test("^[a-z_]+$") and . != "committed")
    and (.created_at | iso)
    and ((has("updated_at") | not) or (.updated_at | iso))
    and .init_system == $init_system
    and (.service_was_active | type == "boolean")
    and (.bbr_previous | type == "string" and test("^[A-Za-z0-9_.-]+$"))
    and (.tfo_previous | type == "string" and test("^[0-9]{1,10}$"))
    and ((.transient_paths // []) | type == "array")
    and all((.transient_paths // [])[]; type == "string")
  ' "$journal" >/dev/null 2>&1 || return 1
  install_transaction_validate_snapshot || {
    error '安装事务快照缺失、重复或路径类型不安全；尚未开始恢复。'
    return 1
  }
  local name path service_path index=0 active_status enabled_status
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    active_status=0
    service_is_active "$name" || active_status=$?
    (( active_status != 2 )) || return 1
    if (( active_status == 0 )); then
      service_stop "$name" >/dev/null 2>&1 || return 1
      service_confirm_inactive "$name" || return 1
    fi
    enabled_status=0
    service_is_enabled "$name" || enabled_status=$?
    (( enabled_status != 2 )) || return 1
    if (( enabled_status == 0 )); then
      service_disable "$name" >/dev/null 2>&1 || return 1
      service_confirm_disabled "$name" || return 1
    fi
  done < <(install_transaction_service_names)
  # Remove the currently installed tc generation while its matching durable
  # plan and manager ownership record are still present.  Restoring an older
  # plan first would make partial/new bindings impossible to identify safely.
  local live_plan live_pref remaining_clsact='[]' previous_clsact='[]' extra_clsact='[]'
  live_plan=$(bandwidth_plan_path) || return 1
  if [[ -f "$live_plan" ]]; then
    live_pref=$(bandwidth_pref) || return 1
    delete_manager_tc_filters "$live_pref" "$NODES_FILE" || return 1
  fi
  if [[ -f "$MANAGER_STATE" ]]; then
    bandwidth_remove_manager_clsact || return 1
    remaining_clsact=$(jq -ce '.tc_clsact_interfaces // []' "$MANAGER_STATE") || return 1
    if [[ -f "$INSTALL_TRANSACTION_DIR/manager-state.present" ]]; then
      previous_clsact=$(jq -ce '.tc_clsact_interfaces // []' "$INSTALL_TRANSACTION_DIR/manager-state.present") || return 1
    fi
    extra_clsact=$(jq -nc --argjson remaining "$remaining_clsact" --argjson previous "$previous_clsact" \
      '$remaining - $previous') || return 1
    jq -e 'length == 0' >/dev/null <<<"$extra_clsact" || {
      error '新建 clsact 上出现外部规则或查询失败，拒绝丢失其所有权恢复证据。'
      return 1
    }
  fi
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    install_transaction_restore_target "$name" "$path" || return 1
  done < <(install_transaction_target_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    service_path=$(service_definition_path "$name") || return 1
    install_transaction_restore_target "service-$index" "$service_path" || return 1
    index=$((index + 1))
  done < <(install_transaction_service_names)
  service_manager_reload || return 1
  index=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -f "$INSTALL_TRANSACTION_DIR/service-$index.enabled" ]]; then
      service_enable "$name" >/dev/null 2>&1 || return 1
      enabled_status=0
      service_is_enabled "$name" || enabled_status=$?
      (( enabled_status == 0 )) || return 1
    fi
    index=$((index + 1))
  done < <(install_transaction_service_names)
  local previous
  previous=$(jq -r '.bbr_previous' "$journal") || return 1
  [[ -z "$previous" ]] || sysctl -w "net.ipv4.tcp_congestion_control=$previous" >/dev/null 2>&1 || return 1
  previous=$(jq -r '.tfo_previous' "$journal") || return 1
  [[ -z "$previous" ]] || sysctl -w "net.ipv4.tcp_fastopen=$previous" >/dev/null 2>&1 || return 1
  if [[ -f "$live_plan" ]]; then
    bandwidth_apply_and_check "$NODES_FILE" || return 1
    traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE" || return 1
  fi
  index=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -f "$INSTALL_TRANSACTION_DIR/service-$index.active" ]]; then
      service_start "$name" >/dev/null 2>&1 || return 1
      active_status=0
      service_is_active "$name" || active_status=$?
      (( active_status == 0 )) || return 1
    else
      active_status=0
      service_is_active "$name" || active_status=$?
      (( active_status != 2 )) || return 1
      if (( active_status == 0 )); then
        service_stop "$name" >/dev/null 2>&1 || return 1
        service_confirm_inactive "$name" || return 1
      fi
    fi
    index=$((index + 1))
  done < <(install_transaction_service_names)
  # An install-scoped operation may legitimately open a nested state
  # transaction (for example the TFO config update). The outer snapshot is
  # authoritative during outer rollback, so discard that newer journal only
  # after all outer state and runtime targets have been restored.
  if [[ -e "$STATE_TRANSACTION_DIR" || -L "$STATE_TRANSACTION_DIR" ]]; then
    state_transaction_clear || return 1
  fi
  install_transaction_cleanup_transient_paths "$journal" || return 1
}

install_transaction_clear() {
  [[ "$INSTALL_TRANSACTION_DIR" == "$CONFIG_DIR/install-transaction" && "$INSTALL_TRANSACTION_DIR" != '/' ]] || return 1
  rm -rf -- "$INSTALL_TRANSACTION_DIR" || return 1
  # Consumed by traffic.sh to distinguish an outer persistent transaction.
  # shellcheck disable=SC2034
  INSTALL_TRANSACTION_RUNTIME_ACTIVE=0
  durable_sync_path "$CONFIG_DIR" || return 1
}

recover_incomplete_install_transaction() {
  [[ -e "$INSTALL_TRANSACTION_DIR" || -L "$INSTALL_TRANSACTION_DIR" ]] || return 0
  local journal="$INSTALL_TRANSACTION_DIR/journal.json" phase
  [[ -d "$INSTALL_TRANSACTION_DIR" && ! -L "$INSTALL_TRANSACTION_DIR" && -f "$journal" && ! -L "$journal" ]] \
    || die "安装事务日志不完整或路径类型不安全；证据保留在 $INSTALL_TRANSACTION_DIR，请勿继续安装。"
  phase=$(jq -er '.phase | select(type == "string")' "$journal" 2>/dev/null) \
    || die "安装事务日志无效；证据保留在 $INSTALL_TRANSACTION_DIR，请勿继续安装。"
  if [[ "$phase" == committed ]]; then
    warn '检测到已提交但尚未清理的安装事务；仅清理提交日志，不回滚已安装版本。'
    install_transaction_clear || die "已提交安装有效，但无法清理安装事务日志：$INSTALL_TRANSACTION_DIR"
    return 0
  fi
  warn '检测到上次安装/修复未完成，正在恢复安装前的程序、状态、服务、内核设置和二进制。'
  # A failed sing-box download from older manager versions may have filled
  # the small /run tmpfs.  Free only our exact stale artifacts before the
  # rollback reloads systemd; otherwise systemd can reject daemon-reload for
  # being below its safety buffer and the transaction cannot recover.
  if [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]] \
    && declare -F singbox_cleanup_stale_runtime_artifacts >/dev/null 2>&1; then
    singbox_cleanup_stale_runtime_artifacts \
      || die '无法在安装事务恢复前清理 sing-box 运行时暂存文件；证据保留在安装事务目录。'
  fi
  install_transaction_restore || die "安装事务恢复失败；证据保留在 $INSTALL_TRANSACTION_DIR，请勿继续安装。"
  install_transaction_clear || die "安装前状态已恢复，但无法清理安装事务日志：$INSTALL_TRANSACTION_DIR"
  success '未完成的安装/修复已完整回滚。'
}

restore_runtime_and_state() {
  local old_nodes=$1 old_traffic=$2 old_history=$3 old_config=$4 service_was_active=${5:-1}
  if [[ -f "$old_nodes" ]]; then atomic_json_write "$old_nodes" "$NODES_FILE" 600 || return 1; fi
  if [[ -f "$old_traffic" ]]; then atomic_json_write "$old_traffic" "$TRAFFIC_FILE" 600 || return 1; fi
  if [[ -f "$old_history" ]]; then atomic_json_write "$old_history" "$HISTORY_FILE" 600 || return 1; fi
  if [[ -f "$old_config" ]]; then
    atomic_json_write "$old_config" "$SING_BOX_CONFIG" 600 || return 1
  else
    rm -f -- "$SING_BOX_CONFIG" || return 1
  fi
  if (( service_was_active == 1 )); then
    singbox_restart >/dev/null 2>&1 || return 1
  else
    singbox_stop >/dev/null 2>&1 || return 1
    singbox_confirm_inactive || return 1
  fi
  if ! bandwidth_apply_and_check "$NODES_FILE" >/dev/null 2>&1; then
    error '旧配置已恢复，但旧 tc 流控规则恢复失败，请立即检查 tc 状态。'
    return 1
  fi
  if ! traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE" >/dev/null 2>&1; then
    error '旧配置已恢复，但 tc 计数基线恢复失败。'
    return 1
  fi
  return 0
}

transaction_runtime_health_check() {
  local nodes_source=$1 service_was_active=$2
  if (( service_was_active == 1 )); then
    singbox_health_check "$nodes_source"
  else
    # A user-stopped service must stay stopped.  The installed configuration
    # still receives the official parser check, while process/port checks are
    # intentionally skipped because no process is expected.
    singbox_confirm_inactive || { error 'sing-box 在保持停止的事务中被意外启动或状态无法确认。'; return 1; }
    singbox_check_config "$SING_BOX_CONFIG" >/dev/null 2>&1
  fi
}

apply_state_transaction() {
  local candidate_nodes=$1
  local candidate_traffic=$2
  local candidate_history=$3
  local reason=$4
  local collect_traffic=${5:-1}
  ensure_runtime_dirs || return 1
  initialize_state_files || return 1
  local merged_traffic
  merged_traffic=$(runtime_temp_file traffic.txn-merge) || return 1
  if [[ "$collect_traffic" == 1 ]]; then
    traffic_collect_no_lock || { rm -f -- "$merged_traffic"; return 1; }
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
    ' "$candidate_traffic" >"$merged_traffic" || { rm -f -- "$merged_traffic"; return 1; }
  else
    install -m 600 -- "$candidate_traffic" "$merged_traffic" || { rm -f -- "$merged_traffic"; return 1; }
  fi
  candidate_traffic="$merged_traffic"
  validate_candidate_nodes "$candidate_nodes" || { rm -f -- "$merged_traffic"; return 1; }
  validate_traffic_file_semantic "$candidate_traffic" "$candidate_nodes" \
    || { rm -f -- "$merged_traffic"; error '候选流量数据库语义或节点关联无效。'; return 1; }
  validate_history_file_semantic "$candidate_history" \
    || { rm -f -- "$merged_traffic"; error '候选流量历史语义无效。'; return 1; }

  local candidate_config
  candidate_config=$(runtime_temp_file config.candidate) || { rm -f -- "$merged_traffic"; return 1; }
  local service_was_active=0 active_status=0
  singbox_is_active || active_status=$?
  (( active_status != 2 )) || { rm -f -- "$merged_traffic"; return 1; }
  if (( active_status == 0 )); then service_was_active=1; fi
  generate_singbox_config "$candidate_nodes" "$candidate_config" || { rm -f -- "$merged_traffic" "$candidate_config"; return 1; }
  if ! singbox_check_config "$candidate_config" >/dev/null 2>&1; then
    error '新配置未通过 sing-box 官方配置检查；未重启服务，也未修改节点数据库。'
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  local backup_path
  backup_path=$(backup_create_snapshot "$reason") || { rm -f -- "$candidate_config" "$merged_traffic"; return 1; }
  if ! state_transaction_begin "$reason" "$service_was_active"; then
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  if ! state_transaction_set_phase switching_config \
    || ! atomic_json_write "$candidate_config" "$SING_BOX_CONFIG" 600; then
    error '候选配置无法持久提交，正在恢复事务前状态。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi
  if (( service_was_active == 1 )) && ! singbox_restart; then
    error 'sing-box 重启失败，正在恢复上一版本配置。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi
  if ! transaction_runtime_health_check "$candidate_nodes" "$service_was_active"; then
    error '新配置健康检查失败，正在恢复上一版本配置。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  if ! state_transaction_set_phase applying_tc \
    || ! bandwidth_apply_and_check "$candidate_nodes"; then
    error '新 tc 流控规则应用/检查失败，正在恢复上一版本配置和规则。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  # tc rules are recreated during every transaction, so their byte counters
  # start from zero. Reset persisted baselines to prevent the next sample
  # from comparing a new port/rule counter with an old one.
  if ! traffic_reset_kernel_baselines "$candidate_nodes" "$candidate_traffic"; then
    error '新的 tc 计数基线无法保存，正在恢复上一版本配置和规则。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi
  validate_traffic_file_semantic "$candidate_traffic" "$candidate_nodes" || {
    error '重置后的候选流量数据库无效，正在回滚。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  }

  if ! state_transaction_set_phase committing_state \
    || ! atomic_json_write "$candidate_nodes" "$NODES_FILE" 600 \
    || ! atomic_json_write "$candidate_traffic" "$TRAFFIC_FILE" 600 \
    || ! atomic_json_write "$candidate_history" "$HISTORY_FILE" 600; then
    error '节点数据库提交失败，正在回滚运行配置和数据。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  if ! transaction_runtime_health_check "$NODES_FILE" "$service_was_active"; then
    error '提交后最终健康检查失败，正在回滚上一版本。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi

  if ! state_transaction_set_phase committed; then
    error '事务完成标记无法持久提交；为保证一致性，将恢复事务前状态。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$candidate_config" "$merged_traffic"
    return 1
  fi
  if ! state_transaction_clear; then
    warn "状态已经提交，但事务日志未能清理；下次启动会识别 committed 标记并仅重试清理：$STATE_TRANSACTION_DIR"
  fi
  backup_prune || warn '配置已经提交，但旧备份自动清理失败；可稍后从备份菜单重试。'
  rm -f -- "$candidate_config" "$merged_traffic" || warn '配置已经提交，但运行时候选文件清理失败。'
  success "配置事务已提交，备份：$backup_path"
  return 0
}

backup_list() {
  local names
  names=$(backup_managed_names) || return 1
  [[ -z "$names" ]] || printf '%s\n' "$names" | sort -r
}

backup_create_manual_flow() {
  acquire_manager_lock
  traffic_collect_no_lock || return 1
  local backup_path
  backup_path=$(backup_create_snapshot manual) || return 1
  backup_prune || warn '手动备份已创建，但旧备份自动清理失败。'
  success "手动备份已创建：$backup_path"
}

backup_restore_flow() {
  acquire_manager_lock
  local -a backups=()
  local backup_names
  backup_names=$(backup_list) || die '无法可靠枚举可恢复备份。'
  [[ -z "$backup_names" ]] || mapfile -t backups <<<"$backup_names"
  ((${#backups[@]} > 0)) || { info '暂无可恢复备份。'; return 0; }
  local index=1 item
  printf '\n可恢复备份：\n'
  for item in "${backups[@]}"; do printf '%s. %s\n' "$index" "$item"; ((index++)); done
  local choice
  printf '请选择备份序号（0 返回）：\n> '
  IFS= read -r choice || die '读取输入失败。'
  [[ "$choice" == 0 ]] && return 0
  [[ "$choice" =~ ^[1-9][0-9]*$ && choice -ge 1 && choice -le ${#backups[@]} ]] || die '无效的备份序号。'
  local selected_name=${backups[$((choice-1))]}
  local selected="$BACKUP_DIR/$selected_name" restore_reason restore_nodes
  backup_snapshot_is_managed "$selected" || die '备份不完整、语义无效或不属于 Ss2022。'
  restore_reason=$(backup_restore_reason "$selected_name") || die '无法生成安全的恢复事务标识。'
  prompt_yes_no "确认恢复备份 $selected_name？当前状态会先自动再备份" n || return 0
  traffic_collect_no_lock || return 1
  restore_nodes=$(runtime_temp_file nodes.restore) || die '无法创建恢复节点候选文件。'
  nodes_schema_upgrade_copy "$selected/nodes.json" "$restore_nodes" || {
    rm -f -- "$restore_nodes"
    die '备份节点数据库无法安全迁移到当前 schema。'
  }
  apply_state_transaction "$restore_nodes" "$selected/traffic.json" "$selected/traffic-history.json" "$restore_reason" 0 || {
    rm -f -- "$restore_nodes"
    die '恢复失败，已自动回滚。'
  }
  rm -f -- "$restore_nodes" || warn '备份已恢复，但节点候选暂存文件清理失败。'
  success '备份恢复完成。'
}

backup_management_flow() {
  local choice
  while true; do
    printf '\n备份与恢复\n1. 立即创建备份\n2. 从历史备份恢复\n0. 返回\n> '
    IFS= read -r choice || die '读取输入失败。'
    case "$choice" in
      1) run_menu_action backup_create_manual_flow ;;
      2) run_menu_action backup_restore_flow ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
