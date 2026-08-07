#!/usr/bin/env bash
# Per-node tc accounting and hard rate policing. No firewall tables are touched.

DEFAULT_TC_PREF=49100

bandwidth_pref() {
  local value
  value=$(manager_state_get tc_pref "$DEFAULT_TC_PREF")
  [[ "$value" =~ ^[0-9]+$ ]] || value=$DEFAULT_TC_PREF
  printf '%s' "$value"
}

tc_pref_is_free() {
  local pref=$1 interface
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    if tc filter show dev "$interface" ingress pref "$pref" 2>/dev/null | grep -q .; then return 1; fi
    if tc filter show dev "$interface" egress pref "$pref" 2>/dev/null | grep -q .; then return 1; fi
  done < <(traffic_interfaces)
  return 0
}

ensure_bandwidth_pref() {
  local existing pref
  existing=$(manager_state_get tc_pref '')
  if [[ "$existing" =~ ^[0-9]+$ ]] && (( existing >= 100 && existing <= 65500 )); then
    printf '%s' "$existing"
    return 0
  fi
  for pref in $(seq 49100 49200); do
    if tc_pref_is_free "$pref"; then
      manager_state_set_json tc_pref "$pref"
      printf '%s' "$pref"
      return 0
    fi
  done
  die '无法找到不占用现有 tc 过滤器的管理优先级。'
}

ensure_clsact() {
  local interface=$1
  if ! tc qdisc show dev "$interface" 2>/dev/null | grep -q 'clsact'; then
    tc qdisc add dev "$interface" clsact
    manager_state_set_json tc_clsact_created true
  fi
}

delete_manager_tc_filters() {
  local pref=$1 interface
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    tc filter del dev "$interface" ingress pref "$pref" 2>/dev/null || true
    tc filter del dev "$interface" egress pref "$pref" 2>/dev/null || true
  done < <(traffic_interfaces)
}

tc_add_flower_rule() {
  local interface=$1 direction=$2 family=$3 protocol=$4 port=$5 limit=$6 pref=$7
  local -a args=(filter add dev "$interface" "$direction" pref "$pref" protocol "$family" flower ip_proto "$protocol")
  if [[ "$direction" == ingress ]]; then args+=(dst_port "$port"); else args+=(src_port "$port"); fi
  if [[ "$limit" != 0 && "$limit" != 0.0 ]]; then
    args+=(action police rate "${limit}mbit" burst 64kb mtu 64kb conform-exceed drop)
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
  pref=$(ensure_bandwidth_pref)
  local interface node port upload_limit download_limit protocol family direction
  delete_manager_tc_filters "$pref"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    ensure_clsact "$interface"
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      port=$(jq -er '.port' <<<"$node")
      upload_limit=$(jq -r '.upload_limit_mbps // 0' <<<"$node")
      download_limit=$(jq -r '.download_limit_mbps // 0' <<<"$node")
      for family in ip ipv6; do
        for protocol in tcp udp; do
          tc_add_flower_rule "$interface" ingress "$family" "$protocol" "$port" "$upload_limit" "$pref"
          tc_add_flower_rule "$interface" egress "$family" "$protocol" "$port" "$download_limit" "$pref"
        done
      done
    done < <(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source")
  done < <(traffic_interfaces)
  jq -n --argjson pref "$pref" --arg updated_at "$(timestamp_iso)" \
    '{schema_version:1,pref:$pref,updated_at:$updated_at}' \
    | atomic_json_from_stdin "$DATA_DIR/bandwidth-plan.json" 600
}

bandwidth_check_nodes() {
  local nodes_source=$1 pref interface node port
  pref=$(bandwidth_pref)
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      port=$(jq -er '.port' <<<"$node")
      if ! tc filter show dev "$interface" ingress pref "$pref" 2>/dev/null | grep -Eq "dst_port[[:space:]]+$port"; then
        error "tc ingress 规则缺失：接口 $interface，端口 $port"
        return 1
      fi
      if ! tc filter show dev "$interface" egress pref "$pref" 2>/dev/null | grep -Eq "src_port[[:space:]]+$port"; then
        error "tc egress 规则缺失：接口 $interface，端口 $port"
        return 1
      fi
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
  local pref interface
  pref=$(bandwidth_pref)
  printf 'tc 管理优先级：%s\n' "$pref"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    printf '\n接口：%s\n' "$interface"
    tc -s filter show dev "$interface" ingress pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress pref "$pref" 2>/dev/null || true
  done < <(traffic_interfaces)
}

bandwidth_remove_manager_rules() {
  local pref
  pref=$(bandwidth_pref)
  delete_manager_tc_filters "$pref"
  rm -f -- "$DATA_DIR/bandwidth-plan.json"
}
