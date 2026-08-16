#!/usr/bin/env bash
# Hysteria2 UDP port-hopping reconcile layer.
#
# The manager owns only its namespaced NAT objects.  No filter policy, user
# chain, UFW/firewalld object, or cloud firewall is touched here.  The module
# is intentionally sourced by both install and runtime entry points; all
# functions fail closed when ownership or kernel capability cannot be proved.

PORTHOP_PLAN="${PORTHOP_PLAN:-$DATA_DIR/port-hopping-plan.json}"
PORTHOP_NFT_TABLE_V4="${PORTHOP_NFT_TABLE_V4:-ss_manager_hy2_v4}"
PORTHOP_NFT_TABLE_V6="${PORTHOP_NFT_TABLE_V6:-ss_manager_hy2_v6}"
PORTHOP_NFT_CHAIN="${PORTHOP_NFT_CHAIN:-prerouting}"
PORTHOP_IPTABLES_CHAIN="${PORTHOP_IPTABLES_CHAIN:-SSM_HY2_HOP}"
PORTHOP_MARKER_PREFIX='ss2022-hy2:'
PORTHOP_IPTABLES_OWNER='SSM-HY2-OWNER'
PORTHOP_IPTABLES_JUMP='SSM-HY2-JUMP'

port_hopping_plan_path() {
  printf '%s' "$PORTHOP_PLAN"
}

port_hopping_validate_interface() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]
}

port_hopping_validate_node_id() {
  [[ "$1" =~ ^[a-f0-9]{32}$ ]]
}

port_hopping_parse_range() {
  local value=${1:-} start end
  [[ "$value" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] || return 1
  # validate_port itself uses a regular expression and overwrites
  # BASH_REMATCH; copy both captures before validating either value.
  start=${BASH_REMATCH[1]}
  end=${BASH_REMATCH[2]}
  validate_port "$start" || return 1
  validate_port "$end" || return 1
  (( start <= end )) || return 1
  printf '%s\t%s' "$start" "$end"
}

port_hopping_ranges_intersect() {
  local start_a=$1 end_a=$2 start_b=$3 end_b=$4
  (( start_a <= end_b && start_b <= end_a ))
}

port_hopping_node_families() {
  local node=$1 address_type mode
  mode=$(manager_state_get listen_mode ipv4) || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  case "$mode" in
    dual) printf 'ip\nipv6\n' ;;
    ipv4) printf 'ip\n' ;;
    family-specific)
      case "$address_type" in
        ipv4) printf 'ip\n' ;;
        ipv6) printf 'ipv6\n' ;;
        domain) printf 'ip\nipv6\n' ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

port_hopping_system_udp_ports() {
  local output line endpoint port
  output=$(ss -H -lun 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # `ss -H -lun` puts the local endpoint in column 4 and the peer
    # endpoint in column 5.  Reading column 5 turns every wildcard listener
    # into `0.0.0.0:*` and makes a valid VPS snapshot fail closed.
    endpoint=$(awk '{print $4}' <<<"$line")
    [[ -n "$endpoint" ]] || return 1
    port=$(sed -nE 's/.*:([0-9]+)$/\1/p' <<<"$endpoint")
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$port"
  done <<<"$output"
}

port_hopping_validate_ranges() {
  local nodes_source=$1 node node_id actual start end other other_id other_start other_end
  local udp_ports port
  validate_nodes_file_semantic "$nodes_source" || return 1
  udp_ports=$(port_hopping_system_udp_ports) || {
    error '无法取得一致的系统 UDP 监听快照；端口跳跃已失败关闭。'
    return 1
  }
  local -a active_nodes=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    [[ "$(jq -r '.protocol' <<<"$node")" == hysteria2 ]] || continue
    [[ "$(jq -r '.port_hopping_enabled // false' <<<"$node")" == true ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    actual=$(jq -er '.port' <<<"$node") || return 1
    start=$(jq -er '.hop_port_start' <<<"$node") || return 1
    end=$(jq -er '.hop_port_end' <<<"$node") || return 1
    validate_port "$actual" || return 1
    validate_port "$start" || return 1
    validate_port "$end" || return 1
    (( start <= end )) || return 1
    (( start != end || start != actual )) || {
      error "Hysteria2 节点 $node_id 的跳跃范围只包含实际端口，拒绝启用无效规则。"
      return 1
    }
    active_nodes+=("$node")
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      [[ "$port" == "$actual" ]] && continue
      if (( port >= start && port <= end )); then
        error "Hysteria2 节点 $node_id 的跳跃范围 ${start}-${end} 覆盖了已监听 UDP 端口 $port。"
        return 1
      fi
    done <<<"$udp_ports"
  done < <(jq -c '.nodes[]' "$nodes_source")

  # All configured ranges, including disabled nodes, reserve their interval.
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    [[ "$(jq -r '.protocol' <<<"$node")" == hysteria2 ]] || continue
    [[ "$(jq -r '.port_hopping_enabled // false' <<<"$node")" == true ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    start=$(jq -er '.hop_port_start' <<<"$node") || return 1
    end=$(jq -er '.hop_port_end' <<<"$node") || return 1
    while IFS= read -r other; do
      [[ -n "$other" ]] || continue
      other_id=$(jq -er '.node_id' <<<"$other") || return 1
      [[ "$other_id" == "$node_id" ]] && continue
      [[ "$(jq -r '.protocol' <<<"$other")" == hysteria2 ]] || continue
      [[ "$(jq -r '.port_hopping_enabled // false' <<<"$other")" == true ]] || continue
      other_start=$(jq -er '.hop_port_start' <<<"$other") || return 1
      other_end=$(jq -er '.hop_port_end' <<<"$other") || return 1
      if port_hopping_ranges_intersect "$start" "$end" "$other_start" "$other_end"; then
        error "Hysteria2 节点 $node_id 的跳跃范围与节点 $other_id 冲突。"
        return 1
      fi
    done < <(jq -c '.nodes[]' "$nodes_source")
    # A different protocol's actual UDP port cannot be redirected by this
    # range.  Disabled nodes are included to preserve their reserved ports.
    while IFS= read -r other; do
      [[ -n "$other" ]] || continue
      other_id=$(jq -er '.node_id' <<<"$other") || return 1
      [[ "$other_id" == "$node_id" ]] && continue
      [[ "$(node_transport_protocols "$other" 2>/dev/null | grep -Fx udp || true)" == udp ]] || continue
      other=$(jq -er '.port' <<<"$other") || return 1
      if (( other >= start && other <= end )); then
        error "跳跃范围 ${start}-${end} 覆盖了其他 UDP 节点端口 $other。"
        return 1
      fi
    done < <(jq -c '.nodes[]' "$nodes_source")
  done < <(jq -c '.nodes[] | select(.protocol == "hysteria2" and (.port_hopping_enabled // false) == true)' "$nodes_source")
}

port_hopping_probe_nft_family() {
  local family=$1 table="ssm_probe_${BASHPID}_$RANDOM" chain=prerouting output
  [[ "$family" == ip || "$family" == ip6 ]] || return 1
  command -v nft >/dev/null 2>&1 || return 1
  nft add table "$family" "$table" >/dev/null 2>&1 || return 1
  nft add chain "$family" "$table" "$chain" '{ type nat hook prerouting priority -100; policy accept; }' >/dev/null 2>&1 || {
    nft delete table "$family" "$table" >/dev/null 2>&1 || true
    return 1
  }
  nft add rule "$family" "$table" "$chain" udp dport 49152-49153 redirect to :49154 comment 'ss2022-probe' >/dev/null 2>&1 || {
    nft delete table "$family" "$table" >/dev/null 2>&1 || true
    return 1
  }
  output=$(nft -j list chain "$family" "$table" "$chain" 2>/dev/null) || output=''
  nft delete table "$family" "$table" >/dev/null 2>&1 || return 1
  jq -e --arg family "$family" --arg table "$table" --arg chain "$chain" \
    'any(.nftables[]?; .rule? and .rule.family == $family and .rule.table == $table and .rule.chain == $chain)' \
    <<<"$output" >/dev/null 2>&1
}

port_hopping_probe_iptables_family() {
  local command_name=$1 chain="SSM_P_${BASHPID}_$RANDOM" output
  command -v "$command_name" >/dev/null 2>&1 || return 1
  "$command_name" -t nat -N "$chain" >/dev/null 2>&1 || return 1
  "$command_name" -t nat -A "$chain" -p udp --dport 49152:49153 -m comment --comment SSM-PROBE -j REDIRECT --to-ports 49154 >/dev/null 2>&1 || {
    "$command_name" -t nat -X "$chain" >/dev/null 2>&1 || true
    return 1
  }
  output=$("$command_name" -t nat -S "$chain" 2>/dev/null) || output=''
  "$command_name" -t nat -D "$chain" -p udp --dport 49152:49153 -m comment --comment SSM-PROBE -j REDIRECT --to-ports 49154 >/dev/null 2>&1 || true
  "$command_name" -t nat -X "$chain" >/dev/null 2>&1 || return 1
  grep -Fq -- '--dport 49152:49153' <<<"$output"
}

port_hopping_detect_backend() {
  local families=$1 family nft_ok=1 ipt_ok=1 command_name
  if command -v nft >/dev/null 2>&1; then
    while IFS= read -r family; do
      [[ -n "$family" ]] || continue
      port_hopping_probe_nft_family "$family" || { nft_ok=0; break; }
    done <<<"$families"
    (( nft_ok == 1 )) && { printf 'nftables'; return 0; }
  fi
  while IFS= read -r family; do
    [[ -n "$family" ]] || continue
    if [[ "$family" == ip ]]; then command_name=iptables; else command_name=ip6tables; fi
    port_hopping_probe_iptables_family "$command_name" || { ipt_ok=0; break; }
  done <<<"$families"
  (( ipt_ok == 1 )) && { printf 'iptables'; return 0; }
  error '当前系统没有通过端口跳跃所需的 NAT 范围匹配、REDIRECT、列出和清理能力探测。'
  return 1
}

port_hopping_plan_validate() {
  local plan=$1
  jq -e '
    .schema_version == 1
    and (.backend == "nftables" or .backend == "iptables" or .backend == "none")
    and (.updated_at | type == "string")
    and (.rules | type == "array")
    and all(.rules[];
      (.node_id | type == "string" and test("^[a-f0-9]{32}$"))
      and (.family == "ip" or .family == "ipv6")
      and (.interface | type == "string" and test("^[A-Za-z0-9_.-]{1,15}$"))
      and (.start | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.end | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.actual_port | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.start <= .end and (.actual_port < .start or .actual_port > .end))
    )
    and (([.rules[] | [.node_id,.family,.interface,.start,.end,.actual_port] | join(":")] | length)
      == ([.rules[] | [.node_id,.family,.interface,.start,.end,.actual_port] | join(":")] | unique | length))
  ' "$plan" >/dev/null 2>&1
}

port_hopping_build_desired() {
  local nodes_source=$1 output=$2 node node_id actual start end interface family families ranges range_start range_end backend interfaces
  validate_nodes_file_semantic "$nodes_source" || return 1
  local hop_count
  hop_count=$(jq -er '[.nodes[] | select(.protocol == "hysteria2" and (.port_hopping_enabled // false) == true)] | length' "$nodes_source") || return 1
  if (( hop_count == 0 )); then
    jq -n --arg updated_at "$(timestamp_iso)" '{schema_version:1,backend:"none",updated_at:$updated_at,rules:[]}' >"$output" || return 1
    port_hopping_plan_validate "$output"
    return
  fi
  port_hopping_validate_ranges "$nodes_source" || return 1
  interfaces=$(traffic_interfaces) || return 1
  [[ -n "$interfaces" ]] || {
    error '没有可证明的默认路由接口，无法安全安装 Hysteria2 端口跳跃规则。'
    return 1
  }
  # Determine the union of address families required by enabled hopping nodes.
  families=''
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    [[ "$(jq -r '.protocol' <<<"$node")" == hysteria2 ]] || continue
    [[ "$(jq -r '.port_hopping_enabled // false' <<<"$node")" == true ]] || continue
    families+=$(port_hopping_node_families "$node")$'\n'
  done < <(jq -c '.nodes[]' "$nodes_source")
  families=$(printf '%s' "$families" | awk 'NF && !seen[$0]++')
  backend=$(port_hopping_detect_backend "$families") || return 1
  jq -n --arg backend "$backend" --arg updated_at "$(timestamp_iso)" '{schema_version:1,backend:$backend,updated_at:$updated_at,rules:[]}' >"$output" || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    [[ "$(jq -r '.protocol' <<<"$node")" == hysteria2 ]] || continue
    [[ "$(jq -r '.port_hopping_enabled // false' <<<"$node")" == true ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    actual=$(jq -er '.port' <<<"$node") || return 1
    start=$(jq -er '.hop_port_start' <<<"$node") || return 1
    end=$(jq -er '.hop_port_end' <<<"$node") || return 1
    ranges=''
    # Exclude the actual listener only when it lies inside the configured
    # external range.  If it is outside, preserve the exact user range; using
    # `start < actual` alone incorrectly widened 30000-31000 to 30000-31585.
    if (( actual >= start && actual <= end )); then
      (( start < actual )) && ranges+="${start}\t$((actual - 1))\n"
      (( actual < end )) && ranges+="$((actual + 1))\t${end}\n"
    else
      ranges+="${start}\t${end}\n"
    fi
    families=$(port_hopping_node_families "$node") || return 1
    while IFS=$'\t' read -r range_start range_end; do
      [[ -n "$range_start" ]] || continue
      while IFS= read -r family; do
        [[ -n "$family" ]] || continue
        while IFS= read -r interface; do
          [[ -n "$interface" ]] || continue
          port_hopping_validate_interface "$interface" || return 1
          local plan_family=$family
          [[ "$plan_family" == ip6 ]] && plan_family=ipv6
          jq --arg node_id "$node_id" --arg family "$plan_family" --arg interface "$interface" \
            --argjson start "$range_start" --argjson finish "$range_end" --argjson actual "$actual" \
            '.rules += [{node_id:$node_id,family:$family,interface:$interface,start:$start,end:$finish,actual_port:$actual}]' \
            "$output" >"$output.next" || return 1
          mv -f -- "$output.next" "$output" || return 1
        done <<<"$interfaces"
      done <<<"$families"
    done <<<"$(printf '%b' "$ranges")"
  done < <(jq -c '.nodes[]' "$nodes_source")
  port_hopping_plan_validate "$output"
}

port_hopping_nft_table_for_family() {
  case "$1" in
    ip) printf '%s' "$PORTHOP_NFT_TABLE_V4" ;;
    ipv6) printf '%s' "$PORTHOP_NFT_TABLE_V6" ;;
    *) return 1 ;;
  esac
}

port_hopping_nft_ensure_namespace() {
  local family=$1 table output
  table=$(port_hopping_nft_table_for_family "$family") || return 1
  if ! nft list table "$([[ "$family" == ipv6 ]] && printf ip6 || printf ip)" "$table" >/dev/null 2>&1; then
    nft add table "$([[ "$family" == ipv6 ]] && printf ip6 || printf ip)" "$table" >/dev/null 2>&1 || return 1
  fi
  output=$(nft list chain "$([[ "$family" == ipv6 ]] && printf ip6 || printf ip)" "$table" "$PORTHOP_NFT_CHAIN" 2>&1 || true)
  if ! grep -q 'type nat hook prerouting' <<<"$output"; then
    if grep -q 'No such file' <<<"$output" || grep -q 'does not exist' <<<"$output"; then
      nft add chain "$([[ "$family" == ipv6 ]] && printf ip6 || printf ip)" "$table" "$PORTHOP_NFT_CHAIN" '{ type nat hook prerouting priority -100; policy accept; }' >/dev/null 2>&1 || return 1
    else
      error "nftables 端口跳跃链 $table/$PORTHOP_NFT_CHAIN 不是可证明的 manager NAT 链。"
      return 1
    fi
  fi
  grep -q 'policy accept' <<<"$(nft list chain "$([[ "$family" == ipv6 ]] && printf ip6 || printf ip)" "$table" "$PORTHOP_NFT_CHAIN" 2>/dev/null)"
}

port_hopping_nft_cleanup_marked() {
  local family=$1 table nft_family output handle marker
  table=$(port_hopping_nft_table_for_family "$family") || return 1
  nft_family=ip; [[ "$family" == ipv6 ]] && nft_family=ip6
  output=$(nft -a list chain "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" 2>/dev/null || true)
  while IFS= read -r line; do
    [[ "$line" == *'comment "ss2022-hy2:'* ]] || continue
    handle=$(sed -nE 's/.*# handle ([0-9]+).*/\1/p' <<<"$line")
    [[ "$handle" =~ ^[0-9]+$ ]] || return 1
    nft delete rule "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" handle "$handle" >/dev/null 2>&1 || return 1
  done <<<"$output"
}

port_hopping_nft_apply() {
  local desired=$1 family table nft_family output line handle key marker range interface actual
  local -a families=()
  mapfile -t families < <(jq -r '.rules[].family' "$desired" | sort -u)
  for family in "${families[@]}"; do
    [[ -n "$family" ]] || continue
    port_hopping_nft_ensure_namespace "$family" || return 1
  done
  # Create the desired set first. Existing rules are removed only after all
  # candidate rules have been accepted, so a failed add leaves old traffic
  # usable and the caller can restore from the persistent state transaction.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    family=$(jq -er '.family' <<<"$line") || return 1
    table=$(port_hopping_nft_table_for_family "$family") || return 1
    nft_family=ip; [[ "$family" == ipv6 ]] && nft_family=ip6
    interface=$(jq -er '.interface' <<<"$line") || return 1
    actual=$(jq -er '.actual_port' <<<"$line") || return 1
    marker="$PORTHOP_MARKER_PREFIX$(jq -er '.node_id' <<<"$line")"
    local start end
    start=$(jq -er '.start' <<<"$line") || return 1
    end=$(jq -er '.end' <<<"$line") || return 1
    range="$start"; (( start != end )) && range="$start-$end"
    output=$(nft list chain "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" 2>/dev/null || true)
    key="iifname \"$interface\" udp dport $range"
    if ! grep -Fq -- "$key" <<<"$output" || ! grep -Fq -- "redirect to :$actual" <<<"$output" || ! grep -Fq -- "comment \"$marker\"" <<<"$output"; then
      # nft's comment expression is a quoted string in nft syntax; shell
      # quoting alone is removed before nft parses it, so preserve the quotes
      # in the argument or markers containing `:` are rejected as syntax.
      nft add rule "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" iifname "$interface" udp dport "$range" counter redirect to :"$actual" comment "\"$marker\"" >/dev/null 2>&1 || return 1
    fi
  done < <(jq -c '.rules[]' "$desired")
  # Remove only marked rules whose exact desired tuple is absent. The line
  # parser is deliberately restricted to manager comments and numeric handles.
  while IFS= read -r family; do
    [[ -n "$family" ]] || continue
    table=$(port_hopping_nft_table_for_family "$family") || return 1
    nft_family=ip; [[ "$family" == ipv6 ]] && nft_family=ip6
    output=$(nft -a list chain "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" 2>/dev/null || true)
    while IFS= read -r line; do
      [[ "$line" == *'comment "ss2022-hy2:'* ]] || continue
      handle=$(sed -nE 's/.*# handle ([0-9]+).*/\1/p' <<<"$line")
      [[ "$handle" =~ ^[0-9]+$ ]] || return 1
      marker=$(sed -nE 's/.*comment "(ss2022-hy2:[a-f0-9]{32})".*/\1/p' <<<"$line")
      [[ -n "$marker" ]] || return 1
      if ! jq -e --arg marker "$marker" --arg line "$line" '
        any(.rules[];
          . as $rule
          | (("ss2022-hy2:" + $rule.node_id) == $marker)
            and ($line | contains(("iifname \"" + $rule.interface + "\" udp dport " + ($rule.start|tostring) + (if $rule.start == $rule.end then "" else "-" + ($rule.end|tostring) end))))
            and ($line | contains(("redirect to :" + ($rule.actual_port|tostring))))
        )
      ' "$desired" >/dev/null 2>&1; then
        nft delete rule "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" handle "$handle" >/dev/null 2>&1 || return 1
      fi
    done <<<"$output"
  done < <(jq -r '.rules[].family' "$desired" | sort -u)
}

port_hopping_iptables_command() {
  [[ "$1" == ip ]] && printf 'iptables' || printf 'ip6tables'
}

port_hopping_iptables_ensure_namespace() {
  local family=$1 command_name output
  command_name=$(port_hopping_iptables_command "$family")
  "$command_name" -t nat -N "$PORTHOP_IPTABLES_CHAIN" >/dev/null 2>&1 || true
  output=$("$command_name" -t nat -S "$PORTHOP_IPTABLES_CHAIN" 2>&1) || return 1
  if ! grep -Fq -- "-m comment --comment $PORTHOP_IPTABLES_OWNER -j RETURN" <<<"$output"; then
    if [[ -n "$output" ]]; then
      error "$command_name 的 manager 专属链已存在但缺少所有权标记，拒绝接管。"
      return 1
    fi
    "$command_name" -t nat -A "$PORTHOP_IPTABLES_CHAIN" -m comment --comment "$PORTHOP_IPTABLES_OWNER" -j RETURN >/dev/null 2>&1 || return 1
  fi
  "$command_name" -t nat -C PREROUTING -m comment --comment "$PORTHOP_IPTABLES_JUMP" -j "$PORTHOP_IPTABLES_CHAIN" >/dev/null 2>&1 || \
    "$command_name" -t nat -I PREROUTING 1 -m comment --comment "$PORTHOP_IPTABLES_JUMP" -j "$PORTHOP_IPTABLES_CHAIN" >/dev/null 2>&1 || return 1
}

port_hopping_iptables_apply() {
  local desired=$1 family command_name line interface start end actual marker range output
  local -a families=()
  mapfile -t families < <(jq -r '.rules[].family' "$desired" | sort -u)
  for family in "${families[@]}"; do port_hopping_iptables_ensure_namespace "$family" || return 1; done
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    family=$(jq -er '.family' <<<"$line") || return 1
    command_name=$(port_hopping_iptables_command "$family") || return 1
    interface=$(jq -er '.interface' <<<"$line") || return 1
    start=$(jq -er '.start' <<<"$line") || return 1
    end=$(jq -er '.end' <<<"$line") || return 1
    actual=$(jq -er '.actual_port' <<<"$line") || return 1
    marker="$PORTHOP_MARKER_PREFIX$(jq -er '.node_id' <<<"$line")"
    range="$start"; (( start != end )) && range="$start:$end"
    "$command_name" -t nat -C "$PORTHOP_IPTABLES_CHAIN" -i "$interface" -p udp --dport "$range" -m comment --comment "$marker" -j REDIRECT --to-ports "$actual" >/dev/null 2>&1 || \
      "$command_name" -t nat -A "$PORTHOP_IPTABLES_CHAIN" -i "$interface" -p udp --dport "$range" -m comment --comment "$marker" -j REDIRECT --to-ports "$actual" >/dev/null 2>&1 || return 1
  done < <(jq -c '.rules[]' "$desired")
  # Remove only manager rules with a complete, validated tuple. Foreign rules
  # in the custom chain are never touched.
  while IFS= read -r family; do
    [[ -n "$family" ]] || continue
    command_name=$(port_hopping_iptables_command "$family") || return 1
    output=$("$command_name" -t nat -S "$PORTHOP_IPTABLES_CHAIN" 2>/dev/null) || return 1
    while IFS= read -r line; do
      [[ "$line" == *'-m comment --comment ss2022-hy2:'* ]] || continue
      if [[ "$line" =~ ^-A[[:space:]]+$PORTHOP_IPTABLES_CHAIN[[:space:]]+-i[[:space:]]+([A-Za-z0-9_.-]{1,15})[[:space:]]+-p[[:space:]]+udp[[:space:]]+--dport[[:space:]]+([0-9:]+)[[:space:]]+-m[[:space:]]+comment[[:space:]]+--comment[[:space:]]+(ss2022-hy2:[a-f0-9]{32})[[:space:]]+-j[[:space:]]+REDIRECT[[:space:]]+--to-ports[[:space:]]+([0-9]+)$ ]]; then
        interface=${BASH_REMATCH[1]}; range=${BASH_REMATCH[2]}; marker=${BASH_REMATCH[3]}; actual=${BASH_REMATCH[4]}
        if ! jq -e --arg family "$([[ "$family" == ip ]] && printf ip || printf ipv6)" --arg interface "$interface" --arg marker "$marker" --arg range "$range" --argjson actual "$actual" '
          any(.rules[]; .family == $family and .interface == $interface and ("ss2022-hy2:" + .node_id) == $marker
            and ((.start|tostring) + (if .start == .end then "" else ":" + (.end|tostring) end)) == $range
            and .actual_port == $actual)
        ' "$desired" >/dev/null 2>&1; then
          "$command_name" -t nat -D "$PORTHOP_IPTABLES_CHAIN" -i "$interface" -p udp --dport "$range" -m comment --comment "$marker" -j REDIRECT --to-ports "$actual" >/dev/null 2>&1 || return 1
        fi
      else
        return 1
      fi
    done <<<"$output"
  done < <(jq -r '.rules[].family' "$desired" | sort -u)
}

port_hopping_cleanup() {
  local backend=${1:-} family table nft_family command_name output handle
  if [[ "$backend" == nftables || -z "$backend" ]]; then
    for family in ip ipv6; do
      table=$(port_hopping_nft_table_for_family "$family") || return 1
      nft_family=ip; [[ "$family" == ipv6 ]] && nft_family=ip6
      if command -v nft >/dev/null 2>&1 && nft list chain "$nft_family" "$table" "$PORTHOP_NFT_CHAIN" >/dev/null 2>&1; then
        port_hopping_nft_cleanup_marked "$family" || return 1
      fi
    done
  fi
  if [[ "$backend" == iptables || -z "$backend" ]]; then
    for family in ip ipv6; do
      command_name=$(port_hopping_iptables_command "$family")
      command -v "$command_name" >/dev/null 2>&1 || continue
      output=$("$command_name" -t nat -S "$PORTHOP_IPTABLES_CHAIN" 2>/dev/null || true)
      while IFS= read -r line; do
        [[ "$line" == *'-m comment --comment ss2022-hy2:'* ]] || continue
        [[ "$line" =~ ^-A[[:space:]]+$PORTHOP_IPTABLES_CHAIN[[:space:]]+-i[[:space:]]+([A-Za-z0-9_.-]{1,15})[[:space:]]+-p[[:space:]]+udp[[:space:]]+--dport[[:space:]]+([0-9:]+)[[:space:]]+-m[[:space:]]+comment[[:space:]]+--comment[[:space:]]+(ss2022-hy2:[a-f0-9]{32})[[:space:]]+-j[[:space:]]+REDIRECT[[:space:]]+--to-ports[[:space:]]+([0-9]+)$ ]] || return 1
        "$command_name" -t nat -D "$PORTHOP_IPTABLES_CHAIN" -i "${BASH_REMATCH[1]}" -p udp --dport "${BASH_REMATCH[2]}" -m comment --comment "${BASH_REMATCH[3]}" -j REDIRECT --to-ports "${BASH_REMATCH[4]}" >/dev/null 2>&1 || return 1
      done <<<"$output"
    done
  fi
  rm -f -- "$PORTHOP_PLAN"
}

port_hopping_reconcile() {
  local nodes_source=${1:-$NODES_FILE} desired count backend
  desired=$(runtime_temp_file porthop-desired) || return 1
  port_hopping_build_desired "$nodes_source" "$desired" || { rm -f -- "$desired"; return 1; }
  count=$(jq -er '.rules | length' "$desired") || { rm -f -- "$desired"; return 1; }
  if (( count == 0 )); then
    backend=''
    if [[ -f "$PORTHOP_PLAN" && ! -L "$PORTHOP_PLAN" ]]; then backend=$(jq -r '.backend // empty' "$PORTHOP_PLAN" 2>/dev/null || true); fi
    port_hopping_cleanup "$backend" || { rm -f -- "$desired"; return 1; }
    rm -f -- "$desired"
    return 0
  fi
  backend=$(jq -er '.backend' "$desired") || { rm -f -- "$desired"; return 1; }
  case "$backend" in
    nftables) port_hopping_nft_apply "$desired" || { rm -f -- "$desired"; return 1; } ;;
    iptables) port_hopping_iptables_apply "$desired" || { rm -f -- "$desired"; return 1; } ;;
    *) rm -f -- "$desired"; return 1 ;;
  esac
  atomic_json_write "$desired" "$PORTHOP_PLAN" 600 || { rm -f -- "$desired"; return 1; }
  rm -f -- "$desired"
}

port_hopping_check() {
  local nodes_source=${1:-$NODES_FILE} desired count backend
  # Reconcile first so a reboot or an externally removed manager rule is
  # repaired before the health result is reported. The reconcile layer is
  # idempotent and only touches manager-owned NAT objects.
  port_hopping_reconcile "$nodes_source" || return 1
  desired=$(runtime_temp_file porthop-check) || return 1
  port_hopping_build_desired "$nodes_source" "$desired" || { rm -f -- "$desired"; return 1; }
  count=$(jq -er '.rules | length' "$desired") || { rm -f -- "$desired"; return 1; }
  if (( count == 0 )); then
    rm -f -- "$desired"
    [[ ! -e "$PORTHOP_PLAN" ]] || { port_hopping_cleanup "$(jq -r '.backend // empty' "$PORTHOP_PLAN" 2>/dev/null || true)"; }
    return 0
  fi
  [[ -f "$PORTHOP_PLAN" && ! -L "$PORTHOP_PLAN" ]] || { rm -f -- "$desired"; return 1; }
  backend=$(jq -er '.backend' "$PORTHOP_PLAN") || { rm -f -- "$desired"; return 1; }
  [[ "$backend" == "$(jq -er '.backend' "$desired")" ]] || { rm -f -- "$desired"; return 1; }
  jq -e --slurpfile expected "$desired" '.rules == $expected[0].rules' "$PORTHOP_PLAN" >/dev/null 2>&1 || { rm -f -- "$desired"; return 1; }
  rm -f -- "$desired"
}

port_hopping_restore() {
  port_hopping_reconcile "${1:-$NODES_FILE}"
}

# Apply a port-hopping metadata change without rewriting or restarting the
# sing-box configuration.  The tc/NAT plans and the node/traffic files still
# share the manager's durable transaction journal, so a failure restores the
# previous node state and both kernel rule sets.
port_hopping_apply_state_transaction() {
  local candidate_nodes=$1 candidate_traffic=$2 candidate_history=$3 reason=$4
  local collect_traffic=${5:-1} merged_traffic backup_path
  ensure_runtime_dirs || return 1
  initialize_state_files || return 1
  merged_traffic=$(runtime_temp_file traffic.port-hop-merge) || return 1
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
  validate_traffic_file_semantic "$candidate_traffic" "$candidate_nodes" || {
    rm -f -- "$merged_traffic"
    error '候选流量数据库语义或节点关联无效。'
    return 1
  }
  validate_history_file_semantic "$candidate_history" || {
    rm -f -- "$merged_traffic"
    error '候选流量历史语义无效。'
    return 1
  }
  validate_tls_certificate_state "$candidate_nodes" "$CERTS_DIR" || {
    rm -f -- "$merged_traffic"
    error '候选 HY2/TUIC TLS 证书目录或 Pin 无效。'
    return 1
  }

  local service_was_active=0 active_status=0
  singbox_is_active || active_status=$?
  (( active_status != 2 )) || { rm -f -- "$merged_traffic"; return 1; }
  (( active_status == 0 )) && service_was_active=1
  backup_path=$(backup_create_snapshot "$reason") || { rm -f -- "$merged_traffic"; return 1; }
  state_transaction_begin "$reason" "$service_was_active" || {
    rm -f -- "$merged_traffic"
    return 1
  }
  if ! state_transaction_set_phase applying_tc || ! bandwidth_apply_and_check "$candidate_nodes"; then
    error '新的 tc 流控规则应用/检查失败，正在恢复上一版本配置和规则。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  if ! state_transaction_set_phase applying_port_hop || ! port_hopping_reconcile "$candidate_nodes"; then
    error '新的 Hysteria2 端口跳跃规则应用/检查失败，正在恢复上一版本配置和规则。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  if ! traffic_reset_kernel_baselines "$candidate_nodes" "$candidate_traffic"; then
    error '新的 tc 计数基线无法保存，正在恢复上一版本配置和规则。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  validate_traffic_file_semantic "$candidate_traffic" "$candidate_nodes" || {
    error '重置后的候选流量数据库无效，正在回滚。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  }
  if ! state_transaction_set_phase committing_state \
    || ! atomic_json_write "$candidate_nodes" "$NODES_FILE" 600 \
    || ! atomic_json_write "$candidate_traffic" "$TRAFFIC_FILE" 600 \
    || ! atomic_json_write "$candidate_history" "$HISTORY_FILE" 600; then
    error '节点数据库提交失败，正在回滚端口跳跃规则和状态。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  if ! transaction_runtime_health_check "$NODES_FILE" "$service_was_active"; then
    error '提交后 sing-box 健康检查失败，正在回滚端口跳跃规则和状态。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  if ! state_transaction_set_phase committed; then
    error '端口跳跃事务完成标记失败，正在恢复上一版本状态。'
    state_transaction_rollback_after_failure || true
    rm -f -- "$merged_traffic"
    return 1
  fi
  state_transaction_clear || warn "端口跳跃状态已提交，但事务日志未能清理：$STATE_TRANSACTION_DIR"
  backup_prune || warn '端口跳跃已提交，但旧备份自动清理失败。'
  rm -f -- "$merged_traffic" || warn '端口跳跃已提交，但运行时候选文件清理失败。'
  if declare -F subscription_publish_export >/dev/null 2>&1; then
    subscription_publish_export "$NODES_FILE" || warn '端口跳跃已提交，但订阅派生输出更新失败；请稍后重建订阅。'
  fi
  success "端口跳跃事务已提交，备份：$backup_path"
}
