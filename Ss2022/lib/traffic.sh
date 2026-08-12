#!/usr/bin/env bash
# Persistent per-node traffic accounting and monthly settlement.

calculate_next_reset_at() {
  local base_iso=$1
  local reset_day=$2
  validate_reset_day "$reset_day" || return 1
  local base_epoch year month candidate_epoch candidate
  base_epoch=$(date -u -d "$base_iso" +%s 2>/dev/null) || return 1
  year=$(date -u -d "@$base_epoch" +%Y) || return 1
  month=$(date -u -d "@$base_epoch" +%m) || return 1
  candidate=$(date -u -d "$year-$month-$reset_day 00:00:00" '+%Y-%m-%dT%H:%M:%SZ') || return 1
  candidate_epoch=$(date -u -d "$candidate" +%s) || return 1
  if (( candidate_epoch <= base_epoch )); then
    candidate=$(date -u -d "$candidate +1 month" '+%Y-%m-01T00:00:00Z') || return 1
    candidate=$(date -u -d "$candidate +$((reset_day - 1)) days" '+%Y-%m-%dT%H:%M:%SZ') || return 1
  fi
  printf '%s' "$candidate"
}

traffic_new_entry() {
  local quota=$1 reset_day=$2
  local now next
  now=$(timestamp_iso) || return 1
  next=$(calculate_next_reset_at "$now" "$reset_day") || return 1
  jq -n --arg now "$now" --arg next "$next" --argjson quota "$quota" --argjson reset_day "$reset_day" \
    '{current_upload_bytes:0,current_download_bytes:0,total_upload_bytes:0,total_download_bytes:0,upload_kernel_bytes:0,download_kernel_bytes:0,quota_bytes:$quota,reset_day:$reset_day,last_reset_at:$now,next_reset_at:$next,updated_at:$now}'
}

traffic_legacy_file_semantic() {
  local source=$1 nodes_source=${2:-}
  jq -e --argjson max "$MAX_SAFE_JSON_INTEGER" '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    def uint: type == "number" and . >= 0 and . <= $max and floor == .;
    .schema_version == 1 and (.nodes | type == "object")
    and all(.nodes | to_entries[];
      (.key | test("^[a-f0-9]{32}$"))
      and (.value | type == "object")
      and (.value as $entry |
        all(["current_upload_bytes","current_download_bytes","total_upload_bytes","total_download_bytes","quota_bytes"][];
          . as $key | ($entry[$key] | uint))
        and ($entry.reset_day | type == "number" and floor == . and . >= 1 and . <= 28)
        and ($entry.last_reset_at | iso)
        and ($entry.next_reset_at | iso)
        and ($entry.last_reset_at < $entry.next_reset_at)
        and ((($entry.updated_at // $entry.last_reset_at) | iso))
        and ((($entry.upload_kernel_bytes // 0) | uint))
        and ((($entry.download_kernel_bytes // 0) | uint)))
    )
  ' "$source" >/dev/null 2>&1 || return 1
  if [[ -n "$nodes_source" ]]; then
    jq -e --slurpfile nodes "$nodes_source" '
      ([.nodes | keys[]] | sort) == ([$nodes[0].nodes[].node_id] | sort)
    ' "$source" >/dev/null 2>&1 || return 1
  fi
}

traffic_migrate_legacy_state() {
  [[ "${LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION:-0}" == 1 ]] || return 0
  traffic_legacy_file_semantic "$TRAFFIC_FILE" "$NODES_FILE" || return 1

  local counters_json='{"schema_version":1,"nodes":{}}'
  if [[ -e "$COUNTERS_FILE" || -L "$COUNTERS_FILE" ]]; then
    if [[ -f "$COUNTERS_FILE" && ! -L "$COUNTERS_FILE" ]] \
      && jq -e --argjson max "$MAX_SAFE_JSON_INTEGER" '
        (.schema_version == 1 and (.nodes | type == "object"))
        and all(.nodes | to_entries[];
          (.key | test("^[a-f0-9]{32}$"))
          and (.value | type == "object")
          and ((.value.upload_kernel_bytes // 0) | type == "number" and . >= 0 and . <= $max and floor == .)
          and ((.value.download_kernel_bytes // 0) | type == "number" and . >= 0 and . <= $max and floor == .))
      ' "$COUNTERS_FILE" >/dev/null 2>&1; then
      counters_json=$(jq -c . "$COUNTERS_FILE") || return 1
    else
      warn '旧版 tc-counters.json 无法安全读取；将保留累计流量并从零建立新的内核计数基线。'
    fi
  fi

  local temporary
  temporary=$(runtime_temp_file traffic-migration) || return 1
  if ! jq --argjson counters "$counters_json" '
    .nodes |= with_entries(
      .key as $id
      | .value as $entry
      | .value = ($entry + {
          upload_kernel_bytes: ($entry.upload_kernel_bytes // $counters.nodes[$id].upload_kernel_bytes // 0),
          download_kernel_bytes: ($entry.download_kernel_bytes // $counters.nodes[$id].download_kernel_bytes // 0),
          updated_at: ($entry.updated_at // $entry.last_reset_at)
        })
    )
  ' "$TRAFFIC_FILE" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! validate_traffic_file_semantic "$temporary" "$NODES_FILE"; then
    rm -f -- "$temporary"
    return 1
  fi
  atomic_json_write "$temporary" "$TRAFFIC_FILE" 600 || {
    rm -f -- "$temporary"
    return 1
  }
  rm -f -- "$temporary" || warn '旧版 traffic.json 已迁移，但迁移暂存文件清理失败。'
  LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION=0
  info '旧版 traffic.json 已安全迁移，累计流量和节点关联保持不变。'
}

traffic_candidate_add_node() {
  local node_id=$1 quota=$2 reset_day=$3
  local entry
  entry=$(traffic_new_entry "$quota" "$reset_day") || return 1
  jq --arg id "$node_id" --argjson entry "$entry" '.nodes[$id] = $entry' "$TRAFFIC_FILE"
}

traffic_candidate_remove_node() {
  local node_id=$1
  jq --arg id "$node_id" 'del(.nodes[$id])' "$TRAFFIC_FILE"
}

traffic_candidate_archive_deleted_node() {
  local history_source=$1 node_id=$2 node_name=$3 traffic_source=$4
  local snapshot deleted_at
  snapshot=$(jq -c --arg id "$node_id" '.nodes[$id] // {}' "$traffic_source") || return 1
  deleted_at=$(timestamp_iso) || return 1
  jq --arg id "$node_id" --arg name "$node_name" --arg deleted_at "$deleted_at" --argjson snapshot "$snapshot" \
    '.deleted_nodes[$id] = {node_name:$name,deleted_at:$deleted_at,traffic:$snapshot}' "$history_source"
}

traffic_candidate_purge_deleted_node() {
  local history_source=$1 node_id=$2
  jq --arg id "$node_id" 'del(.cycles[$id], .deleted_nodes[$id])' "$history_source"
}

traffic_value() {
  local node_id=$1 filter=$2
  jq -er --arg id "$node_id" "(.nodes[\$id] // {} | ($filter) // 0)" "$TRAFFIC_FILE" 2>/dev/null
}

traffic_history_for_node() {
  local node_id=$1
  # HISTORY_FILE is initialized by common.sh before this library is sourced.
  # shellcheck disable=SC2153
  jq -c --arg id "$node_id" '(.cycles[$id].entries // [])' "$HISTORY_FILE"
}

tc_counter_from_json() {
  local output=$1 pref=$2 direction=$3 port=$4
  local port_field
  [[ "$pref" =~ ^[0-9]+$ ]] || return 1
  validate_port "$port" || return 1
  case "$direction" in
    ingress) port_field=dst_port ;;
    egress) port_field=src_port ;;
    *) return 1 ;;
  esac

  jq -r --argjson pref "$pref" --argjson port "$port" --arg port_field "$port_field" '
    [ .[]
      | select((((.pref // 0) | tonumber?) // -1) == $pref)
      | (.options // {}) as $options
      | ($options.keys // $options) as $keys
      | select(((($keys[$port_field] // 0) | tonumber?) // -1) == $port)
      | ($options.actions // []) as $actions
      | select(($actions | length) == 0 or any($actions[]; (.kind // "") == "police" or (.kind // "") == "gact"))
      | if ($actions | length) > 0
        then (((($actions[0].stats.bytes // 0) | tonumber?) // 0))
        else ((((.bytes // 0) | tonumber?) // 0))
        end
    ] | add // 0
  ' <<<"$output"
}

tc_counter_json() {
  local interface=$1 direction=$2 port=$3 pref=$4
  local output family_pref value total=0
  if [[ "$direction" == ingress ]]; then
    output=$(tc -s -j filter show dev "$interface" ingress 2>/dev/null) || return 1
  else
    output=$(tc -s -j filter show dev "$interface" egress 2>/dev/null) || return 1
  fi
  [[ -n "$output" ]] || return 1
  output=$(tc_filter_normalize_json "$output") || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$output" || return 1
  local ipv6_pref
  ipv6_pref=$(tc_family_pref "$pref" ipv6) || return 1
  for family_pref in "$pref" "$ipv6_pref"; do
    value=$(tc_counter_from_json "$output" "$family_pref" "$direction" "$port" 2>/dev/null) || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    total=$((total + value))
  done
  printf '%s' "$total"
}

tc_action_counter_from_json() {
  local output=$1 kind=$2 index=$3 cookie=$4
  [[ "$kind" == gact || "$kind" == police ]] || return 1
  [[ "$index" =~ ^[0-9]+$ ]] || return 1
  [[ "$cookie" =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
  output=$(tc_action_normalize_json "$output" "$kind" "$index") || return 1
  jq -er --arg kind "$kind" --argjson index "$index" --arg cookie "${cookie,,}" --argjson max "$MAX_SAFE_JSON_INTEGER" '
    def norm_cookie:
      tostring | ascii_downcase | sub("^0x"; "") | gsub("[:-]"; "");
    [ .. | objects
      | select((.kind? // "") == $kind)
      | select((((.index? // -1) | tonumber?) // -1) == $index)
      | select(((.cookie? // "") | norm_cookie) == $cookie)
    ] as $matches
    | if ($matches | length) != 1 then error("owned tc action missing or duplicated")
      else (($matches[0].stats.bytes | tonumber?) // error("tc action bytes missing")) as $bytes
        | if ($bytes >= 0 and $bytes <= $max and ($bytes | floor) == $bytes) then $bytes else error("unsafe tc action bytes") end
      end
  ' <<<"$output"
}

quota_billable_bytes() {
  local upload=$1 download=$2 include_upload
  validate_safe_uint "$upload" && validate_safe_uint "$download" || return 1
  include_upload=$(manager_state_get quota_include_unauthenticated_upload false) || return 1
  [[ "$include_upload" == true || "$include_upload" == false ]] || return 1
  if [[ "$include_upload" == true ]]; then
    safe_add_bytes "$upload" "$download"
  else
    printf '%s' "$download"
  fi
}

quota_policy_description() {
  local include_upload
  include_upload=$(manager_state_get quota_include_unauthenticated_upload false) || return 1
  case "$include_upload" in
    false) printf '仅下载（全局默认策略）' ;;
    true) printf '上传 + 下载（全局策略）' ;;
    *) return 1 ;;
  esac
}

traffic_sync_quota_status() {
  local nodes_source=$1 traffic_source=$2 node_id=$3 quota=$4 output_file=$5
  validate_safe_uint "$quota" || return 1
  local status upload download billable desired reason
  status=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .status' "$nodes_source") || return 1
  upload=$(jq -er --arg id "$node_id" '.nodes[$id].current_upload_bytes' "$traffic_source") || return 1
  download=$(jq -er --arg id "$node_id" '.nodes[$id].current_download_bytes' "$traffic_source") || return 1
  billable=$(quota_billable_bytes "$upload" "$download") || return 1
  desired=$status
  reason=$(jq -er --arg id "$node_id" '.nodes[] | select(.node_id == $id) | .status_reason' "$nodes_source") || return 1
  if [[ "$status" == enabled && "$quota" -gt 0 && "$billable" -ge "$quota" ]]; then
    desired=disabled_quota
    reason='月流量已达到限额'
  elif [[ "$status" == disabled_quota && ( "$quota" -eq 0 || "$billable" -lt "$quota" ) ]]; then
    desired=enabled
    reason=''
  fi
  jq --arg id "$node_id" --arg status "$desired" --arg reason "$reason" '
    .nodes[] |= if .node_id == $id
      then .status=$status | .status_reason=$reason | .updated_at=(now|todateiso8601)
      else . end
  ' "$nodes_source" >"$output_file" || return 1
  chmod 600 -- "$output_file" || return 1
}

tc_action_counter_json() {
  local kind=$1 index=$2 cookie=$3 output status=0
  output=$(tc -s -j actions get action "$kind" index "$index" 2>&1) || status=$?
  if (( status != 0 )); then
    # Ubuntu 18.04's iproute2 has no usable `actions get action` parser, but
    # its list operation still returns the same cookie and statistics fields
    # (in legacy text form, normalized by tc_action_legacy_json).
    grep -qi 'command "action" is unknown' <<<"$output" || return 1
    output=$(tc -s -j actions ls action "$kind" 2>/dev/null) || return 1
  fi
  [[ -n "$output" ]] || return 1
  tc_action_counter_from_json "$output" "$kind" "$index" "$cookie"
}

tc_node_counter() {
  local node_id=$1 port=$2 direction=$3 status=${4:-enabled}
  [[ "$status" == enabled ]] || { printf '0'; return 0; }
  local action kind index cookie action_port
  action=$(bandwidth_plan_action "$node_id" "$direction") || return 1
  kind=$(jq -er '.kind' <<<"$action") || return 1
  index=$(jq -er '.index' <<<"$action") || return 1
  cookie=$(jq -er '.cookie' <<<"$action") || return 1
  action_port=$(jq -er '.port' <<<"$action") || return 1
  [[ "$action_port" == "$port" ]] || return 1
  tc_action_counter_json "$kind" "$index" "$cookie"
}

traffic_interface_refresh_rollback() {
  install_transaction_set_phase rolling_back >/dev/null 2>&1 || true
  if install_transaction_restore && install_transaction_clear; then
    warn '默认路由接口刷新失败，已恢复刷新前的接口、tc 规则和流量基线。'
    return 0
  fi
  error "默认路由接口刷新自动回滚未完成；恢复证据保留在 $INSTALL_TRANSACTION_DIR。"
  return 1
}

traffic_refresh_interfaces_transactionally() {
  local owns_transaction=0
  if [[ "${INSTALL_TRANSACTION_RUNTIME_ACTIVE:-0}" != 1 ]]; then
    [[ ! -e "$INSTALL_TRANSACTION_DIR" && ! -L "$INSTALL_TRANSACTION_DIR" ]] || {
      error '检测到未恢复的安装事务，拒绝开始默认路由接口刷新。'
      return 1
    }
    install_transaction_begin || return 1
    owns_transaction=1
    if ! install_transaction_set_phase traffic_interfaces; then
      traffic_interface_refresh_rollback || true
      return 1
    fi
  fi

  if ! detect_traffic_interfaces \
    || ! bandwidth_apply_and_check "$NODES_FILE" \
    || ! traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE"; then
    if (( owns_transaction == 1 )); then traffic_interface_refresh_rollback || true; fi
    return 1
  fi

  if (( owns_transaction == 1 )); then
    if ! install_transaction_set_phase committed; then
      traffic_interface_refresh_rollback || true
      return 1
    fi
    if ! install_transaction_clear; then
      warn "默认路由接口刷新已提交，但事务日志未能清理；下次启动只会重试清理：$INSTALL_TRANSACTION_DIR"
    fi
  fi
  return 0
}

traffic_ensure_tc_rules_no_lock() {
  # tc state is not persistent across a server reboot. Validate before every
  # sample so a reboot or external rule removal cannot silently stop traffic
  # accounting. Recreated rules start at zero, therefore persisted kernel
  # baselines must be reset before the next delta is calculated.
  local route_state=0 boot_state=0 family_state=0
  traffic_interfaces_match_current_routes || route_state=$?
  if (( route_state == 2 )); then
    error '无法可靠查询当前默认路由接口，本次不会修改 tc 规则或流量基线。'
    return 1
  fi
  bandwidth_plan_matches_current_boot || boot_state=$?
  if (( boot_state == 0 )); then
    bandwidth_plan_matches_current_families || family_state=$?
    if (( family_state == 2 )); then
      error '无法可靠查询当前默认路由地址族，本次不会修改 tc 规则或流量基线。'
      return 1
    fi
  fi
  if (( boot_state != 0 || route_state == 1 || family_state == 1 )); then
    # On a same-boot route change the shared actions still contain traffic
    # accumulated on the previous interfaces.  Commit those readable counters
    # before the refresh transaction removes the old filter bindings.  After a
    # reboot the kernel actions are gone, so no pre-refresh sample is expected.
    if (( boot_state == 0 && (route_state == 1 || family_state == 1) )); then
      if traffic_collect_actions_no_rule_check; then
        info '默认出口变化前已保存旧 tc action 计数。'
      else
        warn '默认出口已变化，但旧 tc action 计数无法完整读取；继续事务化刷新接口。'
      fi
    fi
    if ! traffic_refresh_interfaces_transactionally; then
      error '默认出口或服务器启动状态变化后的接口/tc 刷新未能安全提交，本次不会写入流量增量。'
      return 1
    fi
    return 0
  fi
  if bandwidth_check_nodes "$NODES_FILE" >/dev/null 2>&1; then
    return 0
  fi
  warn '检测到 tc 统计/限速规则缺失或不完整，正在安全重建。'
  if traffic_collect_actions_no_rule_check; then
    info '重建前已保存仍然完整的 tc action 计数。'
  else
    warn '部分 tc action 也已缺失，无法完整保存其尚未采样的计数；继续重建其余规则。'
  fi
  if ! bandwidth_apply_and_check "$NODES_FILE"; then
    error 'tc 统计/限速规则重建失败，本次不会写入流量增量。'
    return 1
  fi
  if ! traffic_reset_kernel_baselines "$NODES_FILE" "$TRAFFIC_FILE"; then
    error 'tc 规则已重建，但计数基线保存失败，本次不会写入流量增量。'
    return 1
  fi
  return 0
}

traffic_collect_actions_no_rule_check() {
  [[ -f "$TRAFFIC_FILE" ]] || return 0
  local interface_count
  interface_count=$(traffic_interfaces | awk 'NF {count++} END {print count+0}') || return 1
  if (( interface_count == 0 )); then
    warn '没有默认路由接口，本次流量采样未写入；接口恢复后会自动重建 tc 规则。'
    return 0
  fi
  local traffic_tmp
  traffic_tmp=$(runtime_temp_file traffic.collect) || return 1
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp" || { rm -f -- "$traffic_tmp"; return 1; }
  local node node_id port status upload_now download_now upload_prev download_prev upload_delta download_delta node_lines
  local current_upload current_download total_upload total_download
  node_lines=$(jq -c '.nodes[]' "$NODES_FILE") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    port=$(jq -er '.port' <<<"$node") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    status=$(jq -er '.status' <<<"$node") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    if ! upload_now=$(tc_node_counter "$node_id" "$port" ingress "$status"); then
      error "读取节点 $node_id 上传 tc 计数失败；本次流量与基线均不写入。"
      rm -f -- "$traffic_tmp" "$traffic_tmp.next"
      return 1
    fi
    if ! download_now=$(tc_node_counter "$node_id" "$port" egress "$status"); then
      error "读取节点 $node_id 下载 tc 计数失败；本次流量与基线均不写入。"
      rm -f -- "$traffic_tmp" "$traffic_tmp.next"
      return 1
    fi
    if [[ ! "$upload_now" =~ ^[0-9]+$ || ! "$download_now" =~ ^[0-9]+$ ]]; then
      error "节点 $node_id 的 tc 计数不是非负整数；本次流量与基线均不写入。"
      rm -f -- "$traffic_tmp" "$traffic_tmp.next"
      return 1
    fi
    if ! validate_safe_uint "$upload_now" || ! validate_safe_uint "$download_now"; then
      error "节点 $node_id 的 tc 计数超过安全 JSON 整数范围；本次流量与基线均不写入。"
      rm -f -- "$traffic_tmp" "$traffic_tmp.next"
      return 1
    fi
    upload_prev=$(jq -r --arg id "$node_id" '.nodes[$id].upload_kernel_bytes // null' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    download_prev=$(jq -r --arg id "$node_id" '.nodes[$id].download_kernel_bytes // null' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    if [[ ! "$upload_prev" =~ ^[0-9]+$ && -f "$COUNTERS_FILE" && ! -L "$COUNTERS_FILE" ]]; then
      upload_prev=$(jq -r --arg id "$node_id" '.nodes[$id].upload_kernel_bytes // null' "$COUNTERS_FILE" 2>/dev/null || printf 'null')
    fi
    if [[ ! "$download_prev" =~ ^[0-9]+$ && -f "$COUNTERS_FILE" && ! -L "$COUNTERS_FILE" ]]; then
      download_prev=$(jq -r --arg id "$node_id" '.nodes[$id].download_kernel_bytes // null' "$COUNTERS_FILE" 2>/dev/null || printf 'null')
    fi
    if [[ "$upload_prev" =~ ^[0-9]+$ && "$upload_now" -ge "$upload_prev" ]]; then upload_delta=$((upload_now - upload_prev)); else upload_delta=$upload_now; fi
    if [[ "$download_prev" =~ ^[0-9]+$ && "$download_now" -ge "$download_prev" ]]; then download_delta=$((download_now - download_prev)); else download_delta=$download_now; fi
    current_upload=$(jq -er --arg id "$node_id" '.nodes[$id].current_upload_bytes // 0' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    current_download=$(jq -er --arg id "$node_id" '.nodes[$id].current_download_bytes // 0' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    total_upload=$(jq -er --arg id "$node_id" '.nodes[$id].total_upload_bytes // 0' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    total_download=$(jq -er --arg id "$node_id" '.nodes[$id].total_download_bytes // 0' "$traffic_tmp") || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    if ! safe_add_bytes "$current_upload" "$upload_delta" >/dev/null \
      || ! safe_add_bytes "$current_download" "$download_delta" >/dev/null \
      || ! safe_add_bytes "$total_upload" "$upload_delta" >/dev/null \
      || ! safe_add_bytes "$total_download" "$download_delta" >/dev/null; then
      error "节点 $node_id 的累计流量将超过安全 JSON 整数上限；拒绝写入近似或溢出值。"
      rm -f -- "$traffic_tmp" "$traffic_tmp.next"
      return 1
    fi
    jq --arg id "$node_id" --argjson up_delta "$upload_delta" --argjson down_delta "$download_delta" --argjson up_now "$upload_now" --argjson down_now "$download_now" '
      .nodes[$id] = ((.nodes[$id] // {})
        | .current_upload_bytes = ((.current_upload_bytes // 0) + $up_delta)
        | .current_download_bytes = ((.current_download_bytes // 0) + $down_delta)
        | .total_upload_bytes = ((.total_upload_bytes // 0) + $up_delta)
        | .total_download_bytes = ((.total_download_bytes // 0) + $down_delta)
        | .upload_kernel_bytes = $up_now
        | .download_kernel_bytes = $down_now
        | .updated_at = (now | todateiso8601))
    ' "$traffic_tmp" >"$traffic_tmp.next" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
    mv -f -- "$traffic_tmp.next" "$traffic_tmp" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  done <<<"$node_lines"
  validate_traffic_file_semantic "$traffic_tmp" "$NODES_FILE" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  atomic_json_write "$traffic_tmp" "$TRAFFIC_FILE" 600 || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  # Successful collection commits both totals and kernel baselines in one
  # file. Remove the pre-1.0.4 baseline file only after that atomic commit.
  rm -f -- "$COUNTERS_FILE" || warn '流量已提交，但旧版 tc 基线文件清理失败。'
  rm -f -- "$traffic_tmp" "$traffic_tmp.next" || warn '流量已提交，但采样暂存文件清理失败。'
}

traffic_collect_no_lock() {
  [[ -f "$TRAFFIC_FILE" ]] || return 0
  local interface_count
  interface_count=$(traffic_interfaces | awk 'NF {count++} END {print count+0}') || return 1
  if (( interface_count == 0 )); then
    warn '没有默认路由接口，本次流量采样未写入；接口恢复后会自动重建 tc 规则。'
    return 0
  fi
  traffic_ensure_tc_rules_no_lock || return 1
  traffic_collect_actions_no_rule_check
}

traffic_reset_kernel_baselines() {
  local nodes_source=$1 traffic_source=${2:-$TRAFFIC_FILE}
  local traffic_tmp
  traffic_tmp=$(runtime_temp_file traffic.baseline) || return 1
  install -m 600 -- "$traffic_source" "$traffic_tmp" || { rm -f -- "$traffic_tmp"; return 1; }
  jq --slurpfile nodes "$nodes_source" '
    .nodes |= reduce ($nodes[0].nodes[]?.node_id) as $id (.;
      .[$id] = ((.[$id] // {}) + {upload_kernel_bytes:0,download_kernel_bytes:0,updated_at:(now|todateiso8601)})
    )
  ' "$traffic_tmp" >"$traffic_tmp.next" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  install -m 600 -- "$traffic_tmp.next" "$traffic_tmp" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  atomic_json_write "$traffic_tmp" "$traffic_source" 600 || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  rm -f -- "$traffic_tmp" "$traffic_tmp.next" || warn '内核计数基线已提交，但暂存文件清理失败。'
}

traffic_append_history() {
  local history_file=$1 node_id=$2 node_name=$3 period=$4 upload=$5 download=$6 closed_at=$7 period_start=$8 period_end=$9
  local entry total
  total=$(safe_add_bytes "$upload" "$download") || return 1
  entry=$(jq -n --arg period "$period" --arg closed_at "$closed_at" --arg period_start "$period_start" --arg period_end "$period_end" --argjson upload "$upload" --argjson download "$download" --argjson total "$total" \
    '{period:$period,period_start_at:$period_start,period_end_at:$period_end,upload_bytes:$upload,download_bytes:$download,total_bytes:$total,closed_at:$closed_at}') || return 1
  jq --arg id "$node_id" --arg name "$node_name" --argjson entry "$entry" --argjson retention "$DEFAULT_HISTORY_RETENTION" \
    '.cycles[$id] = ((.cycles[$id] // {node_name:$name,entries:[]}) + {node_name:$name}) | .cycles[$id].entries = ((.cycles[$id].entries | map(select(.period != $entry.period))) + [$entry] | sort_by(.period) | .[-$retention:])' \
    "$history_file" >"$history_file.next" || return 1
  mv -f -- "$history_file.next" "$history_file" || return 1
}

settlement_period_label() {
  local period_end=$1 end_epoch
  end_epoch=$(date -u -d "$period_end" +%s 2>/dev/null) || return 1
  (( end_epoch > 0 )) || return 1
  # Label a cycle by the month containing its final billable second.  This
  # keeps reset-day 1 intuitive (August traffic is "2026-08") and prevents a
  # newly-created partial cycle from colliding with the next full cycle when
  # a node resets on another day of the month.
  date -u -d "@$((end_epoch - 1))" '+%Y-%m'
}

traffic_maintenance_no_lock() {
  traffic_collect_no_lock || return 1
  local now_epoch
  now_epoch=$(timestamp_epoch) || return 1
  local nodes_tmp traffic_tmp history_tmp
  nodes_tmp=$(runtime_temp_file nodes.maintenance) || return 1
  traffic_tmp=$(runtime_temp_file traffic.maintenance) || { rm -f -- "$nodes_tmp"; return 1; }
  history_tmp=$(runtime_temp_file history.maintenance) || { rm -f -- "$nodes_tmp" "$traffic_tmp"; return 1; }
  install -m 600 -- "$NODES_FILE" "$nodes_tmp" || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp" || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
  install -m 600 -- "$HISTORY_FILE" "$history_tmp" || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
  local changed=0 node node_id name status quota current_u current_d total reset_day last_reset next_reset next_epoch period node_lines
  node_lines=$(jq -c '.nodes[]' "$NODES_FILE") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    name=$(jq -er '.name' <<<"$node") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    status=$(jq -er '.status' <<<"$node") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    quota=$(jq -er '.quota_bytes' <<<"$node") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    reset_day=$(jq -er '.reset_day' <<<"$node") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    while true; do
      last_reset=$(jq -r --arg id "$node_id" '.nodes[$id].last_reset_at // empty' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      next_reset=$(jq -r --arg id "$node_id" '.nodes[$id].next_reset_at // empty' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      [[ -n "$next_reset" ]] || break
      next_epoch=$(date -u -d "$next_reset" +%s 2>/dev/null) \
        || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      (( next_epoch > 0 && next_epoch <= now_epoch )) || break
      period=$(settlement_period_label "$next_reset") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      current_u=$(jq -er --arg id "$node_id" '.nodes[$id].current_upload_bytes // 0' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      current_d=$(jq -er --arg id "$node_id" '.nodes[$id].current_download_bytes // 0' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      traffic_append_history "$history_tmp" "$node_id" "$name" "$period" "$current_u" "$current_d" "$(timestamp_iso)" "$last_reset" "$next_reset" \
        || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      local new_next
      new_next=$(calculate_next_reset_at "$next_reset" "$reset_day") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
      jq --arg id "$node_id" --arg last "$next_reset" --arg next "$new_next" \
        '.nodes[$id].current_upload_bytes=0 | .nodes[$id].current_download_bytes=0 | .nodes[$id].last_reset_at=$last | .nodes[$id].next_reset_at=$next | .nodes[$id].updated_at=(now|todateiso8601)' \
        "$traffic_tmp" >"$traffic_tmp.next" || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$traffic_tmp.next" "$history_tmp"; return 1; }
      mv -f -- "$traffic_tmp.next" "$traffic_tmp" || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$traffic_tmp.next" "$history_tmp"; return 1; }
      jq --arg id "$node_id" --arg last "$next_reset" --arg next "$new_next" \
        '.nodes |= map(if .node_id == $id then .last_reset_at=$last | .next_reset_at=$next | .updated_at=(now|todateiso8601) else . end)' \
        "$nodes_tmp" >"$nodes_tmp.next" || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
      mv -f -- "$nodes_tmp.next" "$nodes_tmp" || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
      changed=1
      if [[ "$status" == disabled_quota ]]; then
        jq --arg id "$node_id" '.nodes[] |= if .node_id == $id then .status="enabled" | .status_reason="" | .updated_at=(now|todateiso8601) else . end' "$nodes_tmp" >"$nodes_tmp.next" \
          || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
        mv -f -- "$nodes_tmp.next" "$nodes_tmp" || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
        status=enabled
        changed=1
      fi
    done
    current_u=$(jq -er --arg id "$node_id" '.nodes[$id].current_upload_bytes // 0' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    current_d=$(jq -er --arg id "$node_id" '.nodes[$id].current_download_bytes // 0' "$traffic_tmp") || { rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"; return 1; }
    total=$(quota_billable_bytes "$current_u" "$current_d") || {
      error "节点 $node_id 的配额计数超出安全范围，已停止本次维护。"
      rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"
      return 1
    }
    if (( quota > 0 && total >= quota )) && [[ "$status" == enabled ]]; then
      jq --arg id "$node_id" --arg reason "月流量已达到限额" '.nodes[] |= if .node_id == $id then .status="disabled_quota" | .status_reason=$reason | .updated_at=(now|todateiso8601) else . end' "$nodes_tmp" >"$nodes_tmp.next" \
        || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
      mv -f -- "$nodes_tmp.next" "$nodes_tmp" || { rm -f -- "$nodes_tmp" "$nodes_tmp.next" "$traffic_tmp" "$history_tmp"; return 1; }
      changed=1
    fi
  done <<<"$node_lines"

  if (( changed == 1 )); then
    if ! apply_state_transaction "$nodes_tmp" "$traffic_tmp" "$history_tmp" 'traffic-maintenance' 0; then
      warn "流量结算或配额停用未能提交，已保留上一个有效配置。"
      rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"
      return 1
    fi
  fi
  rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp" \
    || warn '流量维护状态已经提交，但运行时副本清理失败。'
}

traffic_maintenance_flow() {
  require_root
  acquire_manager_lock
  traffic_maintenance_no_lock || return 1
}

traffic_collect_flow() {
  require_root
  acquire_manager_lock
  traffic_collect_no_lock || return 1
  success '已采样并保存节点流量。'
}

traffic_update_node_settings() {
  local node_id=$1 quota=$2 reset_day=$3
  validate_reset_day "$reset_day" || die '流量重置日必须为 1-28。'
  validate_safe_uint "$quota" || die "流量限额必须是 0-$MAX_SAFE_JSON_INTEGER 的安全整数（字节）。"
  local traffic_tmp
  traffic_tmp=$(runtime_temp_file traffic.settings) || return 1
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp" || { rm -f -- "$traffic_tmp"; return 1; }
  local last_reset next now
  last_reset=$(jq -r --arg id "$node_id" '.nodes[$id].last_reset_at // empty' "$traffic_tmp") || { rm -f -- "$traffic_tmp"; return 1; }
  if [[ -z "$last_reset" ]]; then
    last_reset=$(timestamp_iso) || { rm -f -- "$traffic_tmp"; return 1; }
  fi
  # Changing a reset day must choose the next occurrence after now; deriving
  # it from an old last_reset_at could produce a date already in the past.
  now=$(timestamp_iso) || { rm -f -- "$traffic_tmp"; return 1; }
  next=$(calculate_next_reset_at "$now" "$reset_day") || { rm -f -- "$traffic_tmp"; return 1; }
  jq --arg id "$node_id" --argjson quota "$quota" --argjson reset_day "$reset_day" --arg last "$last_reset" --arg next "$next" \
    '.nodes[$id].quota_bytes=$quota | .nodes[$id].reset_day=$reset_day | .nodes[$id].last_reset_at=($last // .nodes[$id].last_reset_at) | .nodes[$id].next_reset_at=$next | .nodes[$id].updated_at=(now|todateiso8601)' \
    "$traffic_tmp" >"$traffic_tmp.next" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  mv -f -- "$traffic_tmp.next" "$traffic_tmp" || { rm -f -- "$traffic_tmp" "$traffic_tmp.next"; return 1; }
  printf '%s' "$traffic_tmp"
}

traffic_sync_nodes_schedule() {
  local nodes_source=$1
  local traffic_source=$2
  local output_file=$3
  jq --slurpfile traffic "$traffic_source" '
    .nodes |= map(
      .node_id as $id
      | if ($traffic[0].nodes[$id] // null) == null then .
        else
          .last_reset_at = ($traffic[0].nodes[$id].last_reset_at // .last_reset_at)
          | .next_reset_at = ($traffic[0].nodes[$id].next_reset_at // .next_reset_at)
        end
    )
  ' "$nodes_source" >"$output_file" || return 1
  chmod 600 -- "$output_file" || return 1
}
