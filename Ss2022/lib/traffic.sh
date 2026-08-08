#!/usr/bin/env bash
# Persistent per-node traffic accounting and monthly settlement.

calculate_next_reset_at() {
  local base_iso=$1
  local reset_day=$2
  validate_reset_day "$reset_day" || return 1
  local base_epoch year month candidate_epoch candidate
  base_epoch=$(date -u -d "$base_iso" +%s 2>/dev/null) || return 1
  year=$(date -u -d "@$base_epoch" +%Y)
  month=$(date -u -d "@$base_epoch" +%m)
  candidate=$(date -u -d "$year-$month-$reset_day 00:00:00" '+%Y-%m-%dT%H:%M:%SZ')
  candidate_epoch=$(date -u -d "$candidate" +%s)
  if (( candidate_epoch <= base_epoch )); then
    candidate=$(date -u -d "$candidate +1 month" '+%Y-%m-01T00:00:00Z')
    candidate=$(date -u -d "$candidate +$((reset_day - 1)) days" '+%Y-%m-%dT%H:%M:%SZ')
  fi
  printf '%s' "$candidate"
}

traffic_new_entry() {
  local quota=$1 reset_day=$2
  local now next
  now=$(timestamp_iso)
  next=$(calculate_next_reset_at "$now" "$reset_day")
  jq -n --arg now "$now" --arg next "$next" --argjson quota "$quota" --argjson reset_day "$reset_day" \
    '{current_upload_bytes:0,current_download_bytes:0,total_upload_bytes:0,total_download_bytes:0,quota_bytes:$quota,reset_day:$reset_day,last_reset_at:$now,next_reset_at:$next,updated_at:$now}'
}

traffic_candidate_add_node() {
  local node_id=$1 quota=$2 reset_day=$3
  local entry
  entry=$(traffic_new_entry "$quota" "$reset_day")
  jq --arg id "$node_id" --argjson entry "$entry" '.nodes[$id] = $entry' "$TRAFFIC_FILE"
}

traffic_candidate_remove_node() {
  local node_id=$1
  jq --arg id "$node_id" 'del(.nodes[$id])' "$TRAFFIC_FILE"
}

traffic_candidate_archive_deleted_node() {
  local history_source=$1 node_id=$2 node_name=$3 traffic_source=$4
  local snapshot
  snapshot=$(jq -c --arg id "$node_id" '.nodes[$id] // {}' "$traffic_source")
  jq --arg id "$node_id" --arg name "$node_name" --arg deleted_at "$(timestamp_iso)" --argjson snapshot "$snapshot" \
    '.deleted_nodes[$id] = {node_name:$name,deleted_at:$deleted_at,traffic:$snapshot}' "$history_source"
}

traffic_candidate_purge_deleted_node() {
  local history_source=$1 node_id=$2
  jq --arg id "$node_id" 'del(.cycles[$id], .deleted_nodes[$id])' "$history_source"
}

traffic_value() {
  local node_id=$1 filter=$2
  jq -r --arg id "$node_id" "(.nodes[\$id] // {} | ($filter) // 0)" "$TRAFFIC_FILE" 2>/dev/null || printf '0\n'
}

traffic_history_for_node() {
  local node_id=$1
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
      | select(((($options[$port_field] // 0) | tonumber?) // -1) == $port)
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
    output=$(tc -s -j filter show dev "$interface" ingress 2>/dev/null || true)
  else
    output=$(tc -s -j filter show dev "$interface" egress 2>/dev/null || true)
  fi
  [[ -n "$output" ]] || { printf '0'; return 0; }
  for family_pref in "$pref" "$(tc_family_pref "$pref" ipv6 2>/dev/null || printf '%s' "$pref")"; do
    value=$(tc_counter_from_json "$output" "$family_pref" "$direction" "$port" 2>/dev/null || printf '0')
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    total=$((total + value))
  done
  printf '%s' "$total"
}

tc_node_counter() {
  local node_id=$1 port=$2 direction=$3
  : "$node_id"
  local interface value pref sum=0
  pref=$(manager_state_get tc_pref '49100')
  [[ "$pref" =~ ^[0-9]+$ ]] || pref=49100
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    value=$(tc_counter_json "$interface" "$direction" "$port" "$pref")
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    sum=$((sum + value))
  done < <(traffic_interfaces)
  printf '%s' "$sum"
}

traffic_ensure_tc_rules_no_lock() {
  # tc state is not persistent across a server reboot. Validate before every
  # sample so a reboot or external rule removal cannot silently stop traffic
  # accounting. Recreated rules start at zero, therefore persisted kernel
  # baselines must be reset before the next delta is calculated.
  local boot_changed=0
  if ! bandwidth_plan_matches_current_boot; then
    boot_changed=1
    if ! (detect_traffic_interfaces); then
      error '服务器重启后无法刷新流量接口，本次不会写入流量增量。'
      return 1
    fi
  fi
  if (( boot_changed == 0 )) && (bandwidth_check_nodes "$NODES_FILE" >/dev/null 2>&1); then
    return 0
  fi
  warn '检测到 tc 统计/限速规则缺失或不完整，正在安全重建。'
  if ! (bandwidth_apply_and_check "$NODES_FILE"); then
    error 'tc 统计/限速规则重建失败，本次不会写入流量增量。'
    return 1
  fi
  if ! (traffic_reset_kernel_baselines "$NODES_FILE"); then
    error 'tc 规则已重建，但计数基线保存失败，本次不会写入流量增量。'
    return 1
  fi
  return 0
}

traffic_collect_no_lock() {
  [[ -f "$TRAFFIC_FILE" ]] || return 0
  traffic_ensure_tc_rules_no_lock || return 1
  local traffic_tmp="$RUNTIME_DIR/traffic.collect.$$.json"
  local counters_tmp="$RUNTIME_DIR/counters.collect.$$.json"
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp"
  install -m 600 -- "$COUNTERS_FILE" "$counters_tmp"
  local node node_id port upload_now download_now upload_prev download_prev upload_delta download_delta
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    port=$(jq -er '.port' <<<"$node")
    upload_now=$(tc_node_counter "$node_id" "$port" ingress)
    download_now=$(tc_node_counter "$node_id" "$port" egress)
    upload_prev=$(jq -r --arg id "$node_id" '.nodes[$id].upload_kernel_bytes // null' "$counters_tmp")
    download_prev=$(jq -r --arg id "$node_id" '.nodes[$id].download_kernel_bytes // null' "$counters_tmp")
    if [[ "$upload_prev" =~ ^[0-9]+$ && "$upload_now" -ge "$upload_prev" ]]; then upload_delta=$((upload_now - upload_prev)); else upload_delta=$upload_now; fi
    if [[ "$download_prev" =~ ^[0-9]+$ && "$download_now" -ge "$download_prev" ]]; then download_delta=$((download_now - download_prev)); else download_delta=$download_now; fi
    if (( upload_delta > 0 || download_delta > 0 )); then
      jq --arg id "$node_id" --argjson up "$upload_delta" --argjson down "$download_delta" \
        '.nodes[$id].current_upload_bytes = ((.nodes[$id].current_upload_bytes // 0) + $up) | .nodes[$id].current_download_bytes = ((.nodes[$id].current_download_bytes // 0) + $down) | .nodes[$id].total_upload_bytes = ((.nodes[$id].total_upload_bytes // 0) + $up) | .nodes[$id].total_download_bytes = ((.nodes[$id].total_download_bytes // 0) + $down) | .nodes[$id].updated_at = (now | todateiso8601)' \
        "$traffic_tmp" >"$traffic_tmp.next"
      mv -f -- "$traffic_tmp.next" "$traffic_tmp"
    fi
    jq --arg id "$node_id" --argjson up "$upload_now" --argjson down "$download_now" \
      '.nodes[$id] = ((.nodes[$id] // {}) + {upload_kernel_bytes:$up,download_kernel_bytes:$down,updated_at:(now|todateiso8601)})' \
      "$counters_tmp" >"$counters_tmp.next"
    mv -f -- "$counters_tmp.next" "$counters_tmp"
  done < <(jq -c '.nodes[]' "$NODES_FILE")
  atomic_json_write "$traffic_tmp" "$TRAFFIC_FILE" 600
  atomic_json_write "$counters_tmp" "$COUNTERS_FILE" 600
  rm -f -- "$traffic_tmp" "$counters_tmp"
}

traffic_reset_kernel_baselines() {
  local nodes_source=$1
  local counters_tmp="$RUNTIME_DIR/counters.baseline.$$.json"
  install -m 600 -- "$COUNTERS_FILE" "$counters_tmp"
  jq --slurpfile nodes "$nodes_source" '
    .nodes |= reduce ($nodes[0].nodes[]?.node_id) as $id (.;
      .[$id] = ((.[$id] // {}) + {upload_kernel_bytes:0,download_kernel_bytes:0,updated_at:(now|todateiso8601)})
    )
  ' "$counters_tmp" >"$counters_tmp.next"
  install -m 600 -- "$counters_tmp.next" "$counters_tmp"
  atomic_json_write "$counters_tmp" "$COUNTERS_FILE" 600
  rm -f -- "$counters_tmp" "$counters_tmp.next"
}

traffic_append_history() {
  local history_file=$1 node_id=$2 node_name=$3 period=$4 upload=$5 download=$6 closed_at=$7 period_start=$8 period_end=$9
  local entry
  entry=$(jq -n --arg period "$period" --arg closed_at "$closed_at" --arg period_start "$period_start" --arg period_end "$period_end" --argjson upload "$upload" --argjson download "$download" \
    '{period:$period,period_start_at:$period_start,period_end_at:$period_end,upload_bytes:$upload,download_bytes:$download,total_bytes:($upload+$download),closed_at:$closed_at}')
  jq --arg id "$node_id" --arg name "$node_name" --argjson entry "$entry" --argjson retention "$DEFAULT_HISTORY_RETENTION" \
    '.cycles[$id] = ((.cycles[$id] // {node_name:$name,entries:[]}) + {node_name:$name}) | .cycles[$id].entries = ((.cycles[$id].entries | map(select(.period != $entry.period))) + [$entry] | sort_by(.period) | .[-$retention:])' \
    "$history_file" >"$history_file.next"
  mv -f -- "$history_file.next" "$history_file"
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
  traffic_collect_no_lock
  local now_epoch
  now_epoch=$(timestamp_epoch)
  local nodes_tmp="$RUNTIME_DIR/nodes.maintenance.$$.json"
  local traffic_tmp="$RUNTIME_DIR/traffic.maintenance.$$.json"
  local history_tmp="$RUNTIME_DIR/history.maintenance.$$.json"
  install -m 600 -- "$NODES_FILE" "$nodes_tmp"
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp"
  install -m 600 -- "$HISTORY_FILE" "$history_tmp"
  local changed=0 node node_id name status quota current_u current_d total reset_day last_reset next_reset next_epoch period
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    name=$(jq -er '.name' <<<"$node")
    status=$(jq -er '.status' <<<"$node")
    quota=$(jq -er '.quota_bytes' <<<"$node")
    reset_day=$(jq -er '.reset_day' <<<"$node")
    while true; do
      last_reset=$(jq -r --arg id "$node_id" '.nodes[$id].last_reset_at // empty' "$traffic_tmp")
      next_reset=$(jq -r --arg id "$node_id" '.nodes[$id].next_reset_at // empty' "$traffic_tmp")
      [[ -n "$next_reset" ]] || break
      next_epoch=$(date -u -d "$next_reset" +%s 2>/dev/null || printf 0)
      (( next_epoch > 0 && next_epoch <= now_epoch )) || break
      period=$(settlement_period_label "$next_reset")
      current_u=$(jq -r --arg id "$node_id" '.nodes[$id].current_upload_bytes // 0' "$traffic_tmp")
      current_d=$(jq -r --arg id "$node_id" '.nodes[$id].current_download_bytes // 0' "$traffic_tmp")
      traffic_append_history "$history_tmp" "$node_id" "$name" "$period" "$current_u" "$current_d" "$(timestamp_iso)" "$last_reset" "$next_reset"
      local new_next
      new_next=$(calculate_next_reset_at "$next_reset" "$reset_day")
      jq --arg id "$node_id" --arg last "$next_reset" --arg next "$new_next" \
        '.nodes[$id].current_upload_bytes=0 | .nodes[$id].current_download_bytes=0 | .nodes[$id].last_reset_at=$last | .nodes[$id].next_reset_at=$next | .nodes[$id].updated_at=(now|todateiso8601)' \
        "$traffic_tmp" >"$traffic_tmp.next"
      mv -f -- "$traffic_tmp.next" "$traffic_tmp"
      jq --arg id "$node_id" --arg last "$next_reset" --arg next "$new_next" \
        '.nodes |= map(if .node_id == $id then .last_reset_at=$last | .next_reset_at=$next | .updated_at=(now|todateiso8601) else . end)' \
        "$nodes_tmp" >"$nodes_tmp.next"
      mv -f -- "$nodes_tmp.next" "$nodes_tmp"
      changed=1
      if [[ "$status" == disabled_quota ]]; then
        jq --arg id "$node_id" '.nodes[] |= if .node_id == $id then .status="enabled" | .status_reason="" | .updated_at=(now|todateiso8601) else . end' "$nodes_tmp" >"$nodes_tmp.next"
        mv -f -- "$nodes_tmp.next" "$nodes_tmp"
        status=enabled
        changed=1
      fi
    done
    current_u=$(jq -r --arg id "$node_id" '.nodes[$id].current_upload_bytes // 0' "$traffic_tmp")
    current_d=$(jq -r --arg id "$node_id" '.nodes[$id].current_download_bytes // 0' "$traffic_tmp")
    total=$((current_u + current_d))
    if (( quota > 0 && total >= quota )) && [[ "$status" == enabled ]]; then
      jq --arg id "$node_id" --arg reason "月流量已达到限额" '.nodes[] |= if .node_id == $id then .status="disabled_quota" | .status_reason=$reason | .updated_at=(now|todateiso8601) else . end' "$nodes_tmp" >"$nodes_tmp.next"
      mv -f -- "$nodes_tmp.next" "$nodes_tmp"
      changed=1
    fi
  done < <(jq -c '.nodes[]' "$NODES_FILE")

  if (( changed == 1 )); then
    if ! apply_state_transaction "$nodes_tmp" "$traffic_tmp" "$history_tmp" 'traffic-maintenance' 0; then
      warn "流量结算或配额停用未能提交，已保留上一个有效配置。"
    fi
  else
    atomic_json_write "$traffic_tmp" "$TRAFFIC_FILE" 600
    atomic_json_write "$history_tmp" "$HISTORY_FILE" 600
  fi
  rm -f -- "$nodes_tmp" "$traffic_tmp" "$history_tmp"
}

traffic_maintenance_flow() {
  require_root
  acquire_manager_lock
  traffic_maintenance_no_lock
}

traffic_collect_flow() {
  require_root
  acquire_manager_lock
  traffic_collect_no_lock
  success '已采样并保存节点流量。'
}

traffic_update_node_settings() {
  local node_id=$1 quota=$2 reset_day=$3
  validate_reset_day "$reset_day" || die '流量重置日必须为 1-28。'
  [[ "$quota" =~ ^[0-9]+$ ]] || die '流量限额必须是非负整数（字节）。'
  local traffic_tmp="$RUNTIME_DIR/traffic.settings.$$.json"
  install -m 600 -- "$TRAFFIC_FILE" "$traffic_tmp"
  local last_reset next
  last_reset=$(jq -r --arg id "$node_id" '.nodes[$id].last_reset_at // empty' "$traffic_tmp")
  [[ -n "$last_reset" ]] || last_reset=$(timestamp_iso)
  # Changing a reset day must choose the next occurrence after now; deriving
  # it from an old last_reset_at could produce a date already in the past.
  next=$(calculate_next_reset_at "$(timestamp_iso)" "$reset_day")
  jq --arg id "$node_id" --argjson quota "$quota" --argjson reset_day "$reset_day" --arg last "$last_reset" --arg next "$next" \
    '.nodes[$id].quota_bytes=$quota | .nodes[$id].reset_day=$reset_day | .nodes[$id].last_reset_at=($last // .nodes[$id].last_reset_at) | .nodes[$id].next_reset_at=$next | .nodes[$id].updated_at=(now|todateiso8601)' \
    "$traffic_tmp" >"$traffic_tmp.next"
  mv -f -- "$traffic_tmp.next" "$traffic_tmp"
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
  ' "$nodes_source" >"$output_file"
  chmod 600 -- "$output_file"
}
