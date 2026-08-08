#!/usr/bin/env bash
# Per-node tc accounting and hard rate policing. No firewall tables are touched.

DEFAULT_TC_PREF=49100

kernel_boot_id() {
  local boot_id=''
  [[ -r /proc/sys/kernel/random/boot_id ]] || return 1
  IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 1
  [[ "$boot_id" =~ ^[A-Fa-f0-9-]{36}$ ]] || return 1
  printf '%s' "$boot_id"
}

bandwidth_plan_matches_current_boot() {
  local plan_file="$DATA_DIR/bandwidth-plan.json"
  [[ -f "$plan_file" ]] || return 1
  local boot_id
  boot_id=$(kernel_boot_id) || boot_id=unknown
  jq -e --arg boot_id "$boot_id" '.schema_version == 1 and .boot_id == $boot_id' "$plan_file" >/dev/null 2>&1
}

bandwidth_plan_interfaces() {
  local plan_file="$DATA_DIR/bandwidth-plan.json"
  [[ -f "$plan_file" ]] || return 0
  jq -r '.interfaces[]?' "$plan_file" 2>/dev/null || true
}

bandwidth_known_interfaces() {
  # Include the previous plan so route/interface changes cannot strand this
  # manager's old filters on an interface that is no longer the default.
  {
    traffic_interfaces
    bandwidth_plan_interfaces
  } | awk 'NF && !seen[$0]++'
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

tc_pref_is_free() {
  local pref=$1 interface family
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      if tc filter show dev "$interface" ingress protocol "$family" pref "$pref" 2>/dev/null | grep -q .; then return 1; fi
      if tc filter show dev "$interface" egress protocol "$family" pref "$pref" 2>/dev/null | grep -q .; then return 1; fi
    done
  done < <(traffic_interfaces)
  return 0
}

ensure_bandwidth_pref() {
  local existing pref expected_ipv6 remembered_ipv6
  existing=$(manager_state_get tc_pref '')
  if [[ "$existing" =~ ^[0-9]+$ ]] && (( existing >= 100 && existing <= 65500 )); then
    expected_ipv6=$(tc_family_pref "$existing" ipv6) || {
      error "已有 tc 管理优先级无法分配 IPv6 优先级：$existing"
      return 1
    }
    remembered_ipv6=$(manager_state_get tc_ipv6_pref '')
    if [[ "$remembered_ipv6" != "$expected_ipv6" ]] && ! tc_pref_is_free "$expected_ipv6"; then
      error "tc 优先级 $expected_ipv6 已被其他规则占用，无法安全添加 IPv6 流控规则。"
      return 1
    fi
    printf '%s' "$existing"
    return 0
  fi
  for pref in $(seq 49100 49200); do
    if tc_pref_is_free "$pref" && tc_pref_is_free "$((pref + 1))"; then
      if ! (manager_state_set_json tc_pref "$pref"); then
        error '无法保存 tc 管理优先级。'
        return 1
      fi
      printf '%s' "$pref"
      return 0
    fi
  done
  error '无法找到不占用现有 tc 过滤器的管理优先级。'
  return 1
}

ensure_clsact() {
  local interface=$1
  if ! tc qdisc show dev "$interface" 2>/dev/null | grep -q 'clsact'; then
    tc qdisc add dev "$interface" clsact || return 1
    if ! (manager_state_set_json tc_clsact_created true); then
      error "无法记录本项目创建的 clsact：$interface"
      return 1
    fi
  fi
}

delete_manager_tc_filters() {
  local pref=$1 interface family family_pref
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || continue
      tc filter del dev "$interface" ingress protocol "$family" pref "$family_pref" 2>/dev/null || true
      tc filter del dev "$interface" egress protocol "$family" pref "$family_pref" 2>/dev/null || true
    done
  done < <(bandwidth_known_interfaces)
}

tc_add_flower_rule() {
  local interface=$1 direction=$2 family=$3 protocol=$4 port=$5 limit=$6 pref=$7
  local -a args=(filter add dev "$interface" "$direction" pref "$pref" protocol "$family" flower ip_proto "$protocol")
  if [[ "$direction" == ingress ]]; then args+=(dst_port "$port"); else args+=(src_port "$port"); fi
  if [[ "$limit" != 0 && "$limit" != 0.0 ]]; then
    args+=(action police rate "${limit}mbit" burst 64kb mtu 64kb conform-exceed drop/pass)
  else
    # Every node needs an action counter even when no rate limit is set.
    args+=(action gact pass)
  fi
  tc "${args[@]}"
}

bandwidth_apply_nodes() {
  local nodes_source=$1
  local interfaces_count
  interfaces_count=$(traffic_interfaces | awk 'NF {count++} END {print count+0}')
  local has_limit=0 node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$(jq -r '.upload_limit_mbps // 0' <<<"$node")" != 0 || "$(jq -r '.download_limit_mbps // 0' <<<"$node")" != 0 ]]; then
      has_limit=1
      break
    fi
  done < <(jq -c '.nodes[]' "$nodes_source")

  if (( interfaces_count == 0 )); then
    if (( has_limit == 1 )); then
      error '没有默认路由接口，无法安全应用节点限速。'
      return 1
    fi
    warn '没有默认路由接口，已保留节点配置；流量统计/限速等待接口配置。'
    return 0
  fi

  local pref
  pref=$(ensure_bandwidth_pref) || return 1
  local family_pref
  family_pref=$(tc_family_pref "$pref" ipv6) || {
    error "无法为 IPv6 规则计算 tc 优先级：$pref"
    return 1
  }
  if ! (manager_state_set_json tc_ipv6_pref "$family_pref"); then
    error '无法保存 IPv6 tc 管理优先级。'
    return 1
  fi
  local interface node port upload_limit download_limit protocol family
  delete_manager_tc_filters "$pref"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    if ! ensure_clsact "$interface"; then
      error "无法在接口 $interface 上准备 clsact。"
      return 1
    fi
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      port=$(jq -er '.port' <<<"$node")
      upload_limit=$(jq -r '.upload_limit_mbps // 0' <<<"$node")
      download_limit=$(jq -r '.download_limit_mbps // 0' <<<"$node")
      for family in ip ipv6; do
        family_pref=$(tc_family_pref "$pref" "$family") || return 1
        for protocol in tcp udp; do
          if ! tc_add_flower_rule "$interface" ingress "$family" "$protocol" "$port" "$upload_limit" "$family_pref"; then
            error "tc 规则创建失败：接口 $interface，ingress，$family/$protocol，端口 $port"
            return 1
          fi
          if ! tc_add_flower_rule "$interface" egress "$family" "$protocol" "$port" "$download_limit" "$family_pref"; then
            error "tc 规则创建失败：接口 $interface，egress，$family/$protocol，端口 $port"
            return 1
          fi
        done
      done
    done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  done < <(traffic_interfaces)
  local boot_id
  boot_id=$(kernel_boot_id) || boot_id=unknown
  if ! (
    jq -n --argjson pref "$pref" --arg boot_id "$boot_id" --arg updated_at "$(timestamp_iso)" --slurpfile detected "$INTERFACES_FILE" \
      '{schema_version:1,pref:$pref,boot_id:$boot_id,interfaces:($detected[0].interfaces // []),updated_at:$updated_at}' \
      | atomic_json_from_stdin "$DATA_DIR/bandwidth-plan.json" 600
  ); then
    error '无法保存 tc 流控计划。'
    return 1
  fi
  return 0
}

tc_rule_json_match_count() {
  local rules_json=$1 pref=$2 family=$3 protocol=$4 direction=$5 port=$6 expected_action=$7
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
  jq -r \
    --argjson pref "$pref" \
    --arg family "$family" \
    --arg protocol "$protocol" \
    --arg protocol_number "$protocol_number" \
    --arg port_field "$port_field" \
    --argjson port "$port" \
    --arg expected_action "$expected_action" '
      [ .[]
        # When `tc filter show` is already scoped by protocol and preference,
        # iproute2 6.1 omits those matching top-level fields from its JSON.
        # Validate them when present, but trust the scoped query when absent.
        | select(if has("pref") then (((.pref | tonumber?) // -1) == $pref) else true end)
        | select(if has("protocol") then ((.protocol | tostring | ascii_downcase) == $family) else true end)
        | (.options // {}) as $options
        | ($options.keys // $options) as $keys
        | (($keys.ip_proto // "") | tostring | ascii_downcase) as $actual_protocol
        | select($actual_protocol == $protocol or $actual_protocol == $protocol_number)
        | select(((($keys[$port_field] // 0) | tonumber?) // -1) == $port)
        | select(any(($options.actions // [])[]; ((.kind // "") | tostring | ascii_downcase) == $expected_action))
      ] | length
    ' <<<"$rules_json"
}

tc_rule_json_matches() {
  local match_count
  match_count=$(tc_rule_json_match_count "$@") || return 1
  [[ "$match_count" == 1 ]]
}

bandwidth_check_nodes() {
  local nodes_source=$1 pref interface node port upload_limit download_limit
  local ingress_json egress_json family family_pref protocol expected_action rules_json direction limit match_count
  pref=$(bandwidth_pref)
  local ipv6_pref
  ipv6_pref=$(tc_family_pref "$pref" ipv6) || {
    error "无法为 IPv6 规则计算 tc 优先级：$pref"
    return 1
  }
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    if ! ingress_json=$(tc -j filter show dev "$interface" ingress protocol ip pref "$pref" 2>/dev/null); then
      error "无法读取 tc ingress 规则：接口 $interface"
      return 1
    fi
    if ! egress_json=$(tc -j filter show dev "$interface" egress protocol ip pref "$pref" 2>/dev/null); then
      error "无法读取 tc egress 规则：接口 $interface"
      return 1
    fi
    local ingress_ipv6_json egress_ipv6_json
    if ! ingress_ipv6_json=$(tc -j filter show dev "$interface" ingress protocol ipv6 pref "$ipv6_pref" 2>/dev/null); then
      error "无法读取 tc IPv6 ingress 规则：接口 $interface"
      return 1
    fi
    if ! egress_ipv6_json=$(tc -j filter show dev "$interface" egress protocol ipv6 pref "$ipv6_pref" 2>/dev/null); then
      error "无法读取 tc IPv6 egress 规则：接口 $interface"
      return 1
    fi
    if ! jq -e 'type == "array"' >/dev/null <<<"$ingress_json" \
      || ! jq -e 'type == "array"' >/dev/null <<<"$egress_json" \
      || ! jq -e 'type == "array"' >/dev/null <<<"$ingress_ipv6_json" \
      || ! jq -e 'type == "array"' >/dev/null <<<"$egress_ipv6_json"; then
      error "tc 返回了无效 JSON：接口 $interface"
      return 1
    fi
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      port=$(jq -er '.port' <<<"$node")
      upload_limit=$(jq -r '.upload_limit_mbps // 0' <<<"$node")
      download_limit=$(jq -r '.download_limit_mbps // 0' <<<"$node")
      for direction in ingress egress; do
        if [[ "$direction" == ingress ]]; then limit=$upload_limit; else limit=$download_limit; fi
        expected_action=gact
        if [[ "$limit" != 0 && "$limit" != 0.0 ]]; then expected_action=police; fi
        for family in ip ipv6; do
          family_pref=$(tc_family_pref "$pref" "$family") || return 1
          if [[ "$direction" == ingress ]]; then
            rules_json=$ingress_json
            [[ "$family" == ipv6 ]] && rules_json=$ingress_ipv6_json
          else
            rules_json=$egress_json
            [[ "$family" == ipv6 ]] && rules_json=$egress_ipv6_json
          fi
          for protocol in tcp udp; do
            if ! match_count=$(tc_rule_json_match_count "$rules_json" "$family_pref" "$family" "$protocol" "$direction" "$port" "$expected_action"); then
              error "无法解析 tc 规则 JSON：接口 $interface，$direction，$family/$protocol，端口 $port"
              return 1
            fi
            if [[ "$match_count" != 1 ]]; then
              error "tc 规则缺失或重复：接口 $interface，$direction，$family/$protocol，端口 $port，动作 $expected_action，匹配数 $match_count"
              return 1
            fi
          done
        done
      done
    done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  done < <(traffic_interfaces)
  return 0
}

bandwidth_apply_and_check() {
  local nodes_source=$1
  bandwidth_apply_nodes "$nodes_source" || return 1
  bandwidth_check_nodes "$nodes_source"
}

bandwidth_status() {
  local pref interface ipv6_pref
  pref=$(bandwidth_pref)
  ipv6_pref=$(tc_family_pref "$pref" ipv6 2>/dev/null || printf '%s' "$pref")
  printf 'tc 管理优先级：IPv4 %s，IPv6 %s\n' "$pref" "$ipv6_pref"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    printf '\n接口：%s\n' "$interface"
    tc -s filter show dev "$interface" ingress protocol ip pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress protocol ip pref "$pref" 2>/dev/null || true
    if [[ "$ipv6_pref" != "$pref" ]]; then
      tc -s filter show dev "$interface" ingress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
      tc -s filter show dev "$interface" egress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
    fi
  done < <(traffic_interfaces)
}

bandwidth_remove_manager_rules() {
  local pref
  pref=$(bandwidth_pref)
  delete_manager_tc_filters "$pref"
  rm -f -- "$DATA_DIR/bandwidth-plan.json"
}
