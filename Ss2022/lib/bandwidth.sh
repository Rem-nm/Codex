#!/usr/bin/env bash
# Per-node tc accounting and aggregate hard rate policing. No firewall tables are touched.

DEFAULT_TC_PREF=49100
TC_ACTION_INDEX_BASE=1000000000

kernel_boot_id() {
  local boot_id=''
  [[ -r /proc/sys/kernel/random/boot_id ]] || return 1
  IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 1
  [[ "$boot_id" =~ ^[A-Fa-f0-9-]{36}$ ]] || return 1
  printf '%s' "$boot_id"
}

bandwidth_plan_path() { printf '%s/bandwidth-plan.json' "$DATA_DIR"; }

bandwidth_plan_matches_current_boot() {
  local plan_file boot_id
  plan_file=$(bandwidth_plan_path)
  [[ -f "$plan_file" ]] || return 1
  boot_id=$(kernel_boot_id) || boot_id=unknown
  jq -e --arg boot_id "$boot_id" '.schema_version == 2 and .boot_id == $boot_id and (.actions | type == "array")' "$plan_file" >/dev/null 2>&1
}

bandwidth_plan_interfaces() {
  local plan_file
  plan_file=$(bandwidth_plan_path)
  [[ -f "$plan_file" ]] || return 0
  jq -r '.interfaces[]?' "$plan_file" 2>/dev/null || true
}

bandwidth_known_interfaces() {
  {
    traffic_interfaces
    bandwidth_plan_interfaces
  } | awk 'NF && !seen[$0]++'
}

bandwidth_plan_action() {
  local node_id=$1 direction=$2 plan_file
  plan_file=$(bandwidth_plan_path)
  [[ -f "$plan_file" ]] || return 1
  jq -ce --arg id "$node_id" --arg direction "$direction" '
    [.actions[]? | select(.node_id == $id and .direction == $direction)]
    | if length == 1 then .[0] else empty end
  ' "$plan_file"
}

bandwidth_pref() {
  local value
  value=$(manager_state_get tc_pref "$DEFAULT_TC_PREF")
  [[ "$value" =~ ^[0-9]+$ ]] || value=$DEFAULT_TC_PREF
  printf '%s' "$value"
}

tc_family_pref() {
  local pref=$1 family=$2
  [[ "$pref" =~ ^[0-9]+$ ]] || return 1
  case "$family" in
    ip) printf '%s' "$pref" ;;
    ipv6)
      (( pref < 65535 )) || return 1
      printf '%s' "$((pref + 1))"
      ;;
    *) return 1 ;;
  esac
}

tc_interface_exists() {
  ip link show dev "$1" >/dev/null 2>&1
}

tc_filter_scoped_json() {
  local interface=$1 direction=$2 family=$3 pref=$4 raw
  tc_interface_exists "$interface" || { printf '[]'; return 0; }
  if ! tc qdisc show dev "$interface" 2>/dev/null | grep -q 'clsact'; then
    printf '[]'
    return 0
  fi
  raw=$(tc -j filter show dev "$interface" "$direction" 2>/dev/null) || return 1
  jq -ce --arg family "$family" --argjson pref "$pref" '
    [ .[]
      | select((((.pref // -1) | tonumber?) // -1) == $pref)
      | select(((.protocol // "") | tostring | ascii_downcase) == $family)
    ]
  ' <<<"$raw"
}

tc_pref_is_free() {
  local pref=$1 interface family direction rules
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$pref") || return 1
        [[ "$(jq -r 'length' <<<"$rules")" == 0 ]] || return 1
      done
    done
  done < <(traffic_interfaces)
  return 0
}

ensure_bandwidth_pref() {
  local existing pref ipv6_pref
  existing=$(manager_state_get tc_pref '')
  if [[ "$existing" =~ ^[0-9]+$ ]] && (( existing >= 100 && existing <= 65500 )) \
    && tc_pref_is_free "$existing" && tc_pref_is_free "$((existing + 1))"; then
    pref=$existing
  else
    pref=''
    local candidate
    for candidate in $(seq 49100 49200); do
      if tc_pref_is_free "$candidate" && tc_pref_is_free "$((candidate + 1))"; then
        pref=$candidate
        break
      fi
    done
    [[ -n "$pref" ]] || { error '无法找到不占用现有 tc 过滤器的管理优先级。'; return 1; }
  fi
  ipv6_pref=$(tc_family_pref "$pref" ipv6) || return 1
  manager_state_set_json tc_pref "$pref" || return 1
  manager_state_set_json tc_ipv6_pref "$ipv6_pref" || return 1
  printf '%s' "$pref"
}

record_manager_clsact_interface() {
  local interface=$1 current updated
  current=$(jq -c '.tc_clsact_interfaces // [] | if type == "array" then . else [] end' "$MANAGER_STATE") || return 1
  updated=$(jq -nc --argjson current "$current" --arg interface "$interface" '$current + [$interface] | unique') || return 1
  manager_state_set_json tc_clsact_interfaces "$updated"
}

ensure_clsact() {
  local interface=$1
  if ! tc qdisc show dev "$interface" 2>/dev/null | grep -q 'clsact'; then
    tc qdisc add dev "$interface" clsact || return 1
    if ! record_manager_clsact_interface "$interface"; then
      tc qdisc del dev "$interface" clsact >/dev/null 2>&1 || true
      error "无法记录本项目创建的 clsact：$interface"
      return 1
    fi
  fi
}

bandwidth_action_identity() {
  local node_id=$1 direction=$2 digest index
  [[ "$node_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  [[ "$direction" == ingress || "$direction" == egress ]] || return 1
  digest=$(printf 'ss2022:%s:%s' "$node_id" "$direction" | sha256sum | awk '{print $1}') || return 1
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  index=$((TC_ACTION_INDEX_BASE + 16#${digest:0:7}))
  printf '%s\t%s' "$index" "${digest:0:32}"
}

bandwidth_action_kind() {
  local limit=$1
  if [[ "$limit" == 0 || "$limit" == 0.0 ]]; then printf 'gact'; else printf 'police'; fi
}

bandwidth_build_actions() {
  local nodes_source=$1 output_file=$2 node node_id port direction limit identity index cookie kind
  jq -n '[]' >"$output_file"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node")
    port=$(jq -er '.port' <<<"$node")
    for direction in ingress egress; do
      if [[ "$direction" == ingress ]]; then
        limit=$(jq -er '.upload_limit_mbps // 0' <<<"$node")
      else
        limit=$(jq -er '.download_limit_mbps // 0' <<<"$node")
      fi
      identity=$(bandwidth_action_identity "$node_id" "$direction") || return 1
      index=${identity%%$'\t'*}
      cookie=${identity#*$'\t'}
      kind=$(bandwidth_action_kind "$limit")
      jq --arg node_id "$node_id" --arg direction "$direction" --arg kind "$kind" --arg cookie "$cookie" \
        --argjson port "$port" --argjson index "$index" --argjson limit "$limit" \
        '. += [{node_id:$node_id,direction:$direction,port:$port,kind:$kind,index:$index,cookie:$cookie,limit_mbps:$limit}]' \
        "$output_file" >"$output_file.next" || return 1
      mv -f -- "$output_file.next" "$output_file"
    done
  done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  jq -e '([.[].index] | length) == ([.[].index] | unique | length) and all(.[]; (.cookie | test("^[a-f0-9]{32}$")))' "$output_file" >/dev/null
}

tc_action_entry_from_json() {
  local output=$1 kind=$2 index=$3
  jq -ce --arg kind "$kind" --argjson index "$index" '
    [ .. | objects
      | select((.kind? // "") == $kind)
      | select((((.index? // -1) | tonumber?) // -1) == $index)
    ] as $matches
    | if ($matches | length) == 1 then $matches[0]
      elif ($matches | length) == 0 then empty
      else error("duplicate tc action index") end
  ' <<<"$output"
}

tc_action_lookup() {
  local kind=$1 index=$2 output count
  output=$(tc -j actions list action "$kind" 2>/dev/null) || return 2
  jq -e . >/dev/null 2>&1 <<<"$output" || return 2
  count=$(jq -r --arg kind "$kind" --argjson index "$index" '
    [ .. | objects | select((.kind? // "") == $kind) | select((((.index? // -1) | tonumber?) // -1) == $index) ] | length
  ' <<<"$output") || return 2
  [[ "$count" == 0 ]] && return 1
  [[ "$count" == 1 ]] || return 2
  tc_action_entry_from_json "$output" "$kind" "$index"
}

tc_action_cookie_matches() {
  local entry=$1 cookie=${2,,}
  jq -e --arg cookie "$cookie" '
    def norm_cookie: tostring | ascii_downcase | sub("^0x"; "") | gsub("[:-]"; "");
    ((.cookie? // "") | norm_cookie) == $cookie
  ' >/dev/null <<<"$entry"
}

tc_delete_owned_action() {
  local kind=$1 index=$2 cookie=$3 entry status
  if entry=$(tc_action_lookup "$kind" "$index"); then
    tc_action_cookie_matches "$entry" "$cookie" || {
      error "tc action $kind/$index 已被其他程序占用，拒绝删除。"
      return 1
    }
  else
    status=$?
    (( status == 1 )) && return 0
    error "无法检查 tc action $kind/$index 的所有权。"
    return 1
  fi
  tc actions delete action "$kind" index "$index" >/dev/null || return 1
}

tc_create_shared_action() {
  local kind=$1 index=$2 cookie=$3 limit=$4 entry status other_kind
  for other_kind in gact police; do
    if entry=$(tc_action_lookup "$other_kind" "$index"); then
      if tc_action_cookie_matches "$entry" "$cookie"; then
        tc actions delete action "$other_kind" index "$index" >/dev/null || return 1
      elif [[ "$other_kind" == "$kind" ]]; then
        error "tc action $kind/$index 已由其他程序使用，拒绝覆盖。"
        return 1
      fi
    else
      status=$?
      (( status == 1 )) || { error "无法检查 tc action $other_kind/$index。"; return 1; }
    fi
  done
  if [[ "$kind" == police ]]; then
    tc actions add action police rate "${limit}mbit" burst 64kb mtu 64kb conform-exceed drop/pass index "$index" cookie "$cookie"
  else
    tc actions add action gact pass index "$index" cookie "$cookie"
  fi
}

bandwidth_preflight_actions() {
  local actions_file=$1 action kind index cookie entry status
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || return 1
    index=$(jq -er '.index' <<<"$action") || return 1
    cookie=$(jq -er '.cookie' <<<"$action") || return 1
    if entry=$(tc_action_lookup "$kind" "$index"); then
      tc_action_cookie_matches "$entry" "$cookie" || {
        error "tc action $kind/$index 已由其他程序使用，未创建任何候选 action。"
        return 1
      }
    else
      status=$?
      (( status == 1 )) || { error "无法预检 tc action $kind/$index。"; return 1; }
    fi
  done < <(jq -c '.[]' "$actions_file")
}

tc_add_flower_rule() {
  local interface=$1 direction=$2 family=$3 protocol=$4 port=$5 pref=$6 kind=$7 index=$8
  local -a args=(filter add dev "$interface" "$direction" pref "$pref" protocol "$family" flower ip_proto "$protocol")
  if [[ "$direction" == ingress ]]; then args+=(dst_port "$port"); else args+=(src_port "$port"); fi
  args+=(action "$kind" index "$index")
  tc "${args[@]}"
}

tc_rule_json_match_count() {
  local rules_json=$1 pref=$2 family=$3 protocol=$4 direction=$5 port=$6 expected_action=$7 expected_index=${8:-}
  local port_field protocol_number
  case "$direction" in
    ingress) port_field=dst_port ;;
    egress) port_field=src_port ;;
    *) return 1 ;;
  esac
  case "$protocol" in
    tcp) protocol_number=6 ;;
    udp) protocol_number=17 ;;
    *) return 1 ;;
  esac
  jq -r --argjson pref "$pref" --arg family "$family" --arg protocol "$protocol" --arg protocol_number "$protocol_number" \
    --arg port_field "$port_field" --argjson port "$port" --arg expected_action "$expected_action" --arg expected_index "$expected_index" '
      [ .[]
        | select(if has("pref") then (((.pref | tonumber?) // -1) == $pref) else true end)
        | select(if has("protocol") then ((.protocol | tostring | ascii_downcase) == $family) else true end)
        | (.options // {}) as $options
        | ($options.keys // $options) as $keys
        | (($keys.ip_proto // "") | tostring | ascii_downcase) as $actual_protocol
        | select($actual_protocol == $protocol or $actual_protocol == $protocol_number)
        | select(((($keys[$port_field] // 0) | tonumber?) // -1) == $port)
        | select(any(($options.actions // [])[];
            (((.kind // "") | tostring | ascii_downcase) == $expected_action)
            and (($expected_index | length) == 0 or (((.index // -1) | tostring) == $expected_index))))
      ] | length
    ' <<<"$rules_json"
}

tc_rule_json_matches() {
  local match_count
  match_count=$(tc_rule_json_match_count "$@") || return 1
  [[ "$match_count" == 1 ]]
}

tc_rule_json_handles() {
  local rules_json=$1 pref=$2 family=$3 protocol=$4 direction=$5 port=$6 expected_action=$7 expected_index=$8
  local port_field protocol_number
  case "$direction" in ingress) port_field=dst_port ;; egress) port_field=src_port ;; *) return 1 ;; esac
  case "$protocol" in tcp) protocol_number=6 ;; udp) protocol_number=17 ;; *) return 1 ;; esac
  jq -r --argjson pref "$pref" --arg family "$family" --arg protocol "$protocol" --arg protocol_number "$protocol_number" \
    --arg port_field "$port_field" --argjson port "$port" --arg expected_action "$expected_action" --argjson expected_index "$expected_index" '
      .[]
      | select(if has("pref") then (((.pref | tonumber?) // -1) == $pref) else true end)
      | select(if has("protocol") then ((.protocol | tostring | ascii_downcase) == $family) else true end)
      | (.options // {}) as $options
      | ($options.keys // $options) as $keys
      | (($keys.ip_proto // "") | tostring | ascii_downcase) as $actual_protocol
      | select($actual_protocol == $protocol or $actual_protocol == $protocol_number)
      | select(((($keys[$port_field] // 0) | tonumber?) // -1) == $port)
      | select(any(($options.actions // [])[];
          (((.kind // "") | tostring | ascii_downcase) == $expected_action)
          and ((((.index // -1) | tonumber?) // -1) == $expected_index)))
      | .handle // empty
    ' <<<"$rules_json"
}

tc_rule_owned_action_count() {
  local rules_json=$1 actions_json=$2
  jq -r --argjson expected "$actions_json" '
    [ .[]
      | (.options.actions // []) as $actual_actions
      | select(any($actual_actions[]; . as $actual |
          any($expected[];
            (.kind == (($actual.kind // "") | tostring | ascii_downcase))
            and ((.index | tonumber) == ((($actual.index // -1) | tonumber?) // -1)))))
    ] | length
  ' <<<"$rules_json"
}

bandwidth_legacy_filter_state() {
  local nodes_source=$1 pref=$2 interface family direction family_pref rules actual=0 matched=0 count node port limit kind protocol
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        actual=$((actual + $(jq -r 'length' <<<"$rules")))
        while IFS= read -r node; do
          [[ -n "$node" ]] || continue
          port=$(jq -er '.port' <<<"$node")
          if [[ "$direction" == ingress ]]; then limit=$(jq -er '.upload_limit_mbps // 0' <<<"$node"); else limit=$(jq -er '.download_limit_mbps // 0' <<<"$node"); fi
          kind=$(bandwidth_action_kind "$limit")
          for protocol in tcp udp; do
            count=$(tc_rule_json_match_count "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind") || return 1
            (( count <= 1 )) || { printf 'mixed'; return 0; }
            matched=$((matched + count))
          done
        done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
      done
    done
  done < <(bandwidth_known_interfaces)
  if (( actual == 0 )); then printf 'empty'
  elif (( matched == 0 )); then printf 'foreign'
  elif (( actual == matched )); then printf 'managed'
  else printf 'mixed'
  fi
}

bandwidth_delete_legacy_filters() {
  local pref=$1 interface family direction family_pref rules
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        if (( $(jq -r 'length' <<<"$rules") > 0 )); then
          tc filter del dev "$interface" "$direction" protocol "$family" pref "$family_pref" >/dev/null || return 1
        fi
      done
    done
  done < <(bandwidth_known_interfaces)
}

bandwidth_remove_plan() {
  local plan_file=$1 pref action entry status expected_bind bind interface family direction family_pref rules actions_json owned_count
  local node_id port kind index cookie protocol handles handle
  local -a deletions=()
  jq -e '.schema_version == 2 and (.pref | type == "number") and (.interfaces | type == "array") and (.actions | type == "array")' "$plan_file" >/dev/null || return 1
  pref=$(jq -er '.pref' "$plan_file")
  expected_bind=$(( $(jq -r '.interfaces | length' "$plan_file") * 4 ))
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action")
    index=$(jq -er '.index' <<<"$action")
    cookie=$(jq -er '.cookie' <<<"$action")
    if entry=$(tc_action_lookup "$kind" "$index"); then
      tc_action_cookie_matches "$entry" "$cookie" || { error "tc action $kind/$index 所有权不匹配，拒绝清理。"; return 1; }
      bind=$(jq -er '(.bind | tonumber?) // error("missing bind count")' <<<"$entry") || return 1
      (( bind <= expected_bind )) || { error "tc action $kind/$index 存在额外绑定，拒绝影响其他规则。"; return 1; }
    else
      status=$?
      (( status == 1 )) || return 1
    fi
  done < <(jq -c '.actions[]' "$plan_file")

  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        actions_json=$(jq -c --arg direction "$direction" '[.actions[] | select(.direction == $direction)]' "$plan_file") || return 1
        local matched_count=0
        while IFS= read -r action; do
          [[ -n "$action" ]] || continue
          node_id=$(jq -er '.node_id' <<<"$action")
          : "$node_id"
          port=$(jq -er '.port' <<<"$action")
          kind=$(jq -er '.kind' <<<"$action")
          index=$(jq -er '.index' <<<"$action")
          for protocol in tcp udp; do
            handles=$(tc_rule_json_handles "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind" "$index") || return 1
            local handle_count
            handle_count=$(awk 'NF {count++} END {print count+0}' <<<"$handles")
            (( handle_count <= 1 )) || { error "检测到重复的 Ss2022 tc 规则，拒绝模糊清理。"; return 1; }
            if (( handle_count == 1 )); then
              handle=$(awk 'NF {print; exit}' <<<"$handles")
              [[ "$handle" =~ ^(0x)?[A-Fa-f0-9]+$ ]] || { error "tc filter handle 无效：$handle"; return 1; }
              deletions+=("$interface"$'\t'"$direction"$'\t'"$family"$'\t'"$family_pref"$'\t'"$handle")
              matched_count=$((matched_count + 1))
            fi
          done
        done < <(jq -c --arg direction "$direction" '.actions[] | select(.direction == $direction)' "$plan_file")
        owned_count=$(tc_rule_owned_action_count "$rules" "$actions_json") || return 1
        (( owned_count == matched_count )) || { error "tc 优先级包含使用 Ss2022 action 的未知规则，拒绝删除。"; return 1; }
      done
    done
  done < <(jq -r '.interfaces[]?' "$plan_file")

  local deletion
  for deletion in "${deletions[@]}"; do
    IFS=$'\t' read -r interface direction family family_pref handle <<<"$deletion"
    tc filter del dev "$interface" "$direction" protocol "$family" pref "$family_pref" handle "$handle" flower >/dev/null || return 1
  done
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action")
    index=$(jq -er '.index' <<<"$action")
    cookie=$(jq -er '.cookie' <<<"$action")
    tc_delete_owned_action "$kind" "$index" "$cookie" || return 1
  done < <(jq -c '.actions[]' "$plan_file")
}

delete_manager_tc_filters() {
  local pref=${1:-$(bandwidth_pref)} nodes_source=${2:-$NODES_FILE} plan_file state
  plan_file=$(bandwidth_plan_path)
  if [[ -f "$plan_file" ]]; then
    if jq -e '.schema_version == 2 and (.actions | type == "array")' "$plan_file" >/dev/null 2>&1; then
      bandwidth_remove_plan "$plan_file" || return 1
      rm -f -- "$plan_file"
      return 0
    fi
    if jq -e '.schema_version == 1 and (.pref | type == "number")' "$plan_file" >/dev/null 2>&1; then
      pref=$(jq -er '.pref' "$plan_file") || return 1
    else
      error "tc 规则计划损坏或版本未知：$plan_file。无法证明所有权，拒绝清理。"
      return 1
    fi
  fi
  state=$(bandwidth_legacy_filter_state "$nodes_source" "$pref") || return 1
  case "$state" in
    empty|foreign) ;;
    managed) bandwidth_delete_legacy_filters "$pref" || return 1 ;;
    mixed)
      error "tc 优先级 $pref 同时包含 Ss2022 与其他规则，拒绝整组删除。"
      return 1
      ;;
    *) return 1 ;;
  esac
  rm -f -- "$plan_file"
}

bandwidth_candidate_cleanup() {
  local plan_file=$1
  bandwidth_remove_plan "$plan_file" >/dev/null 2>&1 || warn '候选 tc 规则清理不完整，请通过 rem 查看 tc 状态。'
}

bandwidth_apply_nodes() {
  local nodes_source=$1 interfaces_count has_limit=0 node
  delete_manager_tc_filters "$(bandwidth_pref)" "$NODES_FILE" || return 1
  interfaces_count=$(traffic_interfaces | awk 'NF {count++} END {print count+0}')
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$(jq -r '.upload_limit_mbps // 0' <<<"$node")" != 0 || "$(jq -r '.download_limit_mbps // 0' <<<"$node")" != 0 ]]; then
      has_limit=1
      break
    fi
  done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  if (( interfaces_count == 0 )); then
    if (( has_limit == 1 )); then
      error '没有默认路由接口，无法安全应用节点限速。'
      return 1
    fi
    warn '没有默认路由接口，已保留节点配置；流量统计/限速等待接口配置。'
    return 0
  fi

  local pref ipv6_pref actions_file plan_candidate interfaces_json boot_id
  pref=$(ensure_bandwidth_pref) || return 1
  ipv6_pref=$(tc_family_pref "$pref" ipv6) || return 1
  : "$ipv6_pref"
  actions_file="$RUNTIME_DIR/bandwidth-actions.$$.json"
  plan_candidate="$RUNTIME_DIR/bandwidth-plan.$$.json"
  bandwidth_build_actions "$nodes_source" "$actions_file" || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }
  interfaces_json=$(traffic_interfaces | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || return 1
  boot_id=$(kernel_boot_id) || boot_id=unknown
  jq -n --argjson pref "$pref" --arg boot_id "$boot_id" --arg updated_at "$(timestamp_iso)" --argjson interfaces "$interfaces_json" \
    --slurpfile actions "$actions_file" \
    '{schema_version:2,pref:$pref,boot_id:$boot_id,interfaces:$interfaces,actions:$actions[0],updated_at:$updated_at}' >"$plan_candidate" || return 1

  if ! bandwidth_preflight_actions "$actions_file"; then
    rm -f -- "$actions_file" "$actions_file.next" "$plan_candidate"
    return 1
  fi

  local interface action kind index cookie limit port direction family family_pref protocol
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    ensure_clsact "$interface" || { error "无法在接口 $interface 上准备 clsact。"; rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  done < <(traffic_interfaces)
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action")
    index=$(jq -er '.index' <<<"$action")
    cookie=$(jq -er '.cookie' <<<"$action")
    limit=$(jq -er '.limit_mbps' <<<"$action")
    if ! tc_create_shared_action "$kind" "$index" "$cookie" "$limit"; then
      error "无法创建聚合 tc action：$kind/$index"
      bandwidth_candidate_cleanup "$plan_candidate"
      rm -f -- "$actions_file" "$plan_candidate"
      return 1
    fi
  done < <(jq -c '.[]' "$actions_file")
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r action; do
      [[ -n "$action" ]] || continue
      port=$(jq -er '.port' <<<"$action")
      direction=$(jq -er '.direction' <<<"$action")
      kind=$(jq -er '.kind' <<<"$action")
      index=$(jq -er '.index' <<<"$action")
      for family in ip ipv6; do
        family_pref=$(tc_family_pref "$pref" "$family") || return 1
        for protocol in tcp udp; do
          if ! tc_add_flower_rule "$interface" "$direction" "$family" "$protocol" "$port" "$family_pref" "$kind" "$index"; then
            error "tc 规则创建失败：接口 $interface，$direction，$family/$protocol，端口 $port"
            bandwidth_candidate_cleanup "$plan_candidate"
            rm -f -- "$actions_file" "$plan_candidate"
            return 1
          fi
        done
      done
    done < <(jq -c '.[]' "$actions_file")
  done < <(traffic_interfaces)
  atomic_json_write "$plan_candidate" "$(bandwidth_plan_path)" 600 || {
    bandwidth_candidate_cleanup "$plan_candidate"
    rm -f -- "$actions_file" "$plan_candidate"
    return 1
  }
  rm -f -- "$actions_file" "$actions_file.next" "$plan_candidate"
}

bandwidth_check_nodes() {
  local nodes_source=$1 interfaces_count has_limit=0 node plan_file expected_actions current_interfaces plan_interfaces
  interfaces_count=$(traffic_interfaces | awk 'NF {count++} END {print count+0}')
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$(jq -r '.upload_limit_mbps // 0' <<<"$node")" != 0 || "$(jq -r '.download_limit_mbps // 0' <<<"$node")" != 0 ]]; then has_limit=1; break; fi
  done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  if (( interfaces_count == 0 )); then (( has_limit == 0 )); return; fi
  plan_file=$(bandwidth_plan_path)
  bandwidth_plan_matches_current_boot || return 1
  expected_actions="$RUNTIME_DIR/bandwidth-check-actions.$$.json"
  bandwidth_build_actions "$nodes_source" "$expected_actions" || { rm -f -- "$expected_actions"; return 1; }
  jq -e --slurpfile expected "$expected_actions" '(.actions | sort_by(.node_id,.direction)) == ($expected[0] | sort_by(.node_id,.direction))' "$plan_file" >/dev/null || {
    rm -f -- "$expected_actions"
    return 1
  }
  current_interfaces=$(traffic_interfaces | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort') || return 1
  plan_interfaces=$(jq -c '.interfaces | unique | sort' "$plan_file") || return 1
  [[ "$current_interfaces" == "$plan_interfaces" ]] || { rm -f -- "$expected_actions"; return 1; }

  local action kind index cookie entry status expected_bind bind
  expected_bind=$((interfaces_count * 4))
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action")
    index=$(jq -er '.index' <<<"$action")
    cookie=$(jq -er '.cookie' <<<"$action")
    if ! entry=$(tc_action_lookup "$kind" "$index"); then rm -f -- "$expected_actions"; return 1; fi
    tc_action_cookie_matches "$entry" "$cookie" || { rm -f -- "$expected_actions"; return 1; }
    bind=$(jq -er '(.bind | tonumber?) // error("missing bind count")' <<<"$entry") || { rm -f -- "$expected_actions"; return 1; }
    (( bind == expected_bind )) || { rm -f -- "$expected_actions"; return 1; }
  done < <(jq -c '.[]' "$expected_actions")

  local pref interface family family_pref direction rules actions_json owned_count expected_owned port protocol match_count
  pref=$(jq -er '.pref' "$plan_file")
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || { rm -f -- "$expected_actions"; return 1; }
        actions_json=$(jq -c --arg direction "$direction" '[.[] | select(.direction == $direction)]' "$expected_actions") || return 1
        expected_owned=$(jq -r 'length * 2' <<<"$actions_json")
        owned_count=$(tc_rule_owned_action_count "$rules" "$actions_json") || return 1
        [[ "$owned_count" == "$expected_owned" ]] || { rm -f -- "$expected_actions"; return 1; }
        while IFS= read -r action; do
          [[ -n "$action" ]] || continue
          port=$(jq -er '.port' <<<"$action")
          kind=$(jq -er '.kind' <<<"$action")
          index=$(jq -er '.index' <<<"$action")
          for protocol in tcp udp; do
            match_count=$(tc_rule_json_match_count "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind" "$index") || return 1
            [[ "$match_count" == 1 ]] || { rm -f -- "$expected_actions"; return 1; }
          done
        done < <(jq -c '.[]' <<<"$actions_json")
      done
    done
  done < <(traffic_interfaces)
  rm -f -- "$expected_actions" "$expected_actions.next"
}

bandwidth_apply_and_check() {
  local nodes_source=$1
  bandwidth_apply_nodes "$nodes_source" || return 1
  bandwidth_check_nodes "$nodes_source"
}

bandwidth_status() {
  local pref interface ipv6_pref plan_file action kind index
  pref=$(bandwidth_pref)
  ipv6_pref=$(tc_family_pref "$pref" ipv6 2>/dev/null || printf '%s' "$pref")
  printf 'tc 管理优先级：IPv4 %s，IPv6 %s\n' "$pref" "$ipv6_pref"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    printf '\n接口：%s\n' "$interface"
    tc -s filter show dev "$interface" ingress protocol ip pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress protocol ip pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" ingress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
  done < <(traffic_interfaces)
  plan_file=$(bandwidth_plan_path)
  if [[ -f "$plan_file" ]]; then
    printf '\n聚合 action：\n'
    while IFS= read -r action; do
      kind=$(jq -er '.kind' <<<"$action")
      index=$(jq -er '.index' <<<"$action")
      tc -s actions get action "$kind" index "$index" 2>/dev/null || true
    done < <(jq -c '.actions[]?' "$plan_file")
  fi
}

bandwidth_remove_manager_clsact() {
  local interfaces interface ingress egress remaining='[]'
  interfaces=$(jq -c '.tc_clsact_interfaces // [] | if type == "array" then . else [] end' "$MANAGER_STATE" 2>/dev/null || printf '[]')
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    tc_interface_exists "$interface" || continue
    ingress=$(tc -j filter show dev "$interface" ingress 2>/dev/null || printf '[]')
    egress=$(tc -j filter show dev "$interface" egress 2>/dev/null || printf '[]')
    if jq -e 'type == "array" and length == 0' >/dev/null <<<"$ingress" \
      && jq -e 'type == "array" and length == 0' >/dev/null <<<"$egress"; then
      tc qdisc del dev "$interface" clsact >/dev/null 2>&1 || true
    else
      warn "接口 $interface 的 clsact 仍有其他规则，已保留。"
      remaining=$(jq -nc --argjson current "$remaining" --arg interface "$interface" '$current + [$interface] | unique')
    fi
  done < <(jq -r '.[]' <<<"$interfaces")
  [[ -f "$MANAGER_STATE" ]] && manager_state_set_json tc_clsact_interfaces "$remaining" >/dev/null 2>&1 || true
}

bandwidth_remove_manager_rules() {
  delete_manager_tc_filters "$(bandwidth_pref)" "$NODES_FILE" || return 1
  bandwidth_remove_manager_clsact
  rm -f -- "$(bandwidth_plan_path)"
}
