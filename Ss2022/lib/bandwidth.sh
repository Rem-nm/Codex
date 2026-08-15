#!/usr/bin/env bash
# Per-node tc accounting and aggregate hard rate policing. No firewall tables are touched.

DEFAULT_TC_PREF=49100
TC_ACTION_INDEX_BASE=1000000000

tc_active_families() {
  local families family disable_ipv6
  families=$(current_default_route_families) || return 1
  while IFS= read -r family; do
    case "$family" in
      ip) printf '%s\n' ip ;;
      ipv6)
        [[ -s /proc/net/if_inet6 ]] || return 1
        disable_ipv6=$(sysctl_read net.ipv6.conf.all.disable_ipv6) || return 1
        [[ "$disable_ipv6" == 0 ]] || return 1
        printf '%s\n' ipv6
        ;;
      *) return 1 ;;
    esac
  done <<<"$families"
}

tc_capability_signature() {
  local kernel tc_version families
  kernel=$(uname -r) || return 1
  tc_version=$(tc -V 2>/dev/null | head -n 1) || return 1
  families=$(tc_active_families | tr '\n' ',') || return 1
  families=${families%,}
  # Bump this probe contract whenever later runtime code starts depending on
  # additional tc JSON fields or semantics, forcing existing installs to run
  # the stronger dummy-interface preflight once.
  printf 'ss2022-tc-probe-v5|%s|%s|%s' "$kernel" "$tc_version" "$families"
}

probe_tc_capabilities() {
  require_cmd ip jq sha256sum tc uname
  local interface="ssmprobe${BASHPID}"
  interface=${interface:0:15}
  local base=$((1900000000 + (BASHPID % 100000) * 2))
  local gact_index police_index candidate_offset kind lookup_status index_free
  for ((candidate_offset=0; candidate_offset<100; candidate_offset+=2)); do
    gact_index=$((base + candidate_offset))
    police_index=$((gact_index + 1))
    index_free=1
    for kind in gact police; do
      if tc_action_lookup "$kind" "$gact_index" >/dev/null 2>&1; then index_free=0; else lookup_status=$?; (( lookup_status == 1 )) || return 1; fi
      if tc_action_lookup "$kind" "$police_index" >/dev/null 2>&1; then index_free=0; else lookup_status=$?; (( lookup_status == 1 )) || return 1; fi
    done
    (( index_free == 1 )) && break
  done
  (( index_free == 1 )) || { error '无法找到空闲的临时 tc action index。'; return 1; }
  local gact_cookie police_cookie output ingress_output egress_output signature match_count
  gact_cookie=$(printf 'ss2022-capability-gact-%s' "$BASHPID" | sha256sum | awk '{print substr($1,1,32)}') || return 1
  police_cookie=$(printf 'ss2022-capability-police-%s' "$BASHPID" | sha256sum | awk '{print substr($1,1,32)}') || return 1

  if ip link show dev "$interface" >/dev/null 2>&1; then
    error "tc 能力探测临时接口名称冲突：$interface"
    return 1
  fi
  if ! ip link add "$interface" type dummy >/dev/null 2>&1; then
    error '无法创建临时 dummy 接口；系统缺少 tc 所需的 CAP_NET_ADMIN 或 dummy 支持。'
    return 1
  fi
  local probe_ok=1 family protocol family_pref expected_rules=0 bind_count handles handle_count handle family_lines
  local -a families=()
  family_lines=$(tc_active_families) || probe_ok=0
  if (( probe_ok == 1 )); then
    mapfile -t families <<<"$family_lines"
  fi
  (( ${#families[@]} >= 1 )) || probe_ok=0
  ip link set dev "$interface" up >/dev/null 2>&1 || probe_ok=0
  (( probe_ok == 0 )) || tc qdisc add dev "$interface" clsact >/dev/null 2>&1 || probe_ok=0
  (( probe_ok == 0 )) || tc_create_shared_action gact "$gact_index" "$gact_cookie" 0 || probe_ok=0
  (( probe_ok == 0 )) || tc_create_shared_action police "$police_index" "$police_cookie" 1 || probe_ok=0
  if (( probe_ok == 1 )); then
    for family in "${families[@]}"; do
      family_pref=$(tc_family_pref 65000 "$family") || { probe_ok=0; break; }
      for protocol in tcp udp; do
        tc_add_flower_rule "$interface" ingress "$family" "$protocol" 9 "$family_pref" gact "$gact_index" "$gact_cookie" >/dev/null 2>&1 || { probe_ok=0; break 2; }
        tc_add_flower_rule "$interface" egress "$family" "$protocol" 9 "$family_pref" police "$police_index" "$police_cookie" >/dev/null 2>&1 || { probe_ok=0; break 2; }
        expected_rules=$((expected_rules + 1))
      done
    done
  fi
  if (( probe_ok == 1 )); then
    ingress_output=$(tc -s -j filter show dev "$interface" ingress 2>/dev/null) || probe_ok=0
    if (( probe_ok == 1 )); then ingress_output=$(tc_filter_normalize_json "$ingress_output") || probe_ok=0; fi
    (( probe_ok == 0 )) || jq -e --argjson expected "$expected_rules" '[.[] | select((.options? // null) | type == "object")] | length == $expected' >/dev/null 2>&1 <<<"$ingress_output" || probe_ok=0
    egress_output=$(tc -s -j filter show dev "$interface" egress 2>/dev/null) || probe_ok=0
    if (( probe_ok == 1 )); then egress_output=$(tc_filter_normalize_json "$egress_output") || probe_ok=0; fi
    (( probe_ok == 0 )) || jq -e --argjson expected "$expected_rules" '[.[] | select((.options? // null) | type == "object")] | length == $expected' >/dev/null 2>&1 <<<"$egress_output" || probe_ok=0
    if (( probe_ok == 1 )); then
      for family in "${families[@]}"; do
        family_pref=$(tc_family_pref 65000 "$family") || { probe_ok=0; break; }
        for protocol in tcp udp; do
          match_count=$(tc_rule_json_match_count "$ingress_output" "$family_pref" "$family" "$protocol" ingress 9 gact "$gact_index") || { probe_ok=0; break 2; }
          (( match_count == 1 )) || { probe_ok=0; break 2; }
          handles=$(tc_rule_json_handles "$ingress_output" "$family_pref" "$family" "$protocol" ingress 9 gact "$gact_index") || { probe_ok=0; break 2; }
          handle_count=$(awk 'NF {count++} END {print count+0}' <<<"$handles") || { probe_ok=0; break 2; }
          (( handle_count == 1 )) || { probe_ok=0; break 2; }
          handle=$(awk 'NF {print; exit}' <<<"$handles") || { probe_ok=0; break 2; }
          [[ "$handle" =~ ^(0x)?[A-Fa-f0-9]+$ ]] || { probe_ok=0; break 2; }
          match_count=$(tc_rule_json_match_count "$egress_output" "$family_pref" "$family" "$protocol" egress 9 police "$police_index") || { probe_ok=0; break 2; }
          (( match_count == 1 )) || { probe_ok=0; break 2; }
          handles=$(tc_rule_json_handles "$egress_output" "$family_pref" "$family" "$protocol" egress 9 police "$police_index") || { probe_ok=0; break 2; }
          handle_count=$(awk 'NF {count++} END {print count+0}' <<<"$handles") || { probe_ok=0; break 2; }
          (( handle_count == 1 )) || { probe_ok=0; break 2; }
          handle=$(awk 'NF {print; exit}' <<<"$handles") || { probe_ok=0; break 2; }
          [[ "$handle" =~ ^(0x)?[A-Fa-f0-9]+$ ]] || { probe_ok=0; break 2; }
        done
      done
    fi
    output=$(tc -s -j actions get action gact index "$gact_index" 2>/dev/null) || probe_ok=0
    (( probe_ok == 0 )) || tc_action_counter_from_json "$output" gact "$gact_index" "$gact_cookie" >/dev/null 2>&1 || probe_ok=0
    if (( probe_ok == 1 )); then
      bind_count=$(tc_action_bind_count_from_json "$output" gact "$gact_index" "$gact_cookie") || probe_ok=0
      (( probe_ok == 0 || bind_count == expected_rules )) || probe_ok=0
    fi
    output=$(tc -s -j actions get action police index "$police_index" 2>/dev/null) || probe_ok=0
    (( probe_ok == 0 )) || tc_action_counter_from_json "$output" police "$police_index" "$police_cookie" >/dev/null 2>&1 || probe_ok=0
    if (( probe_ok == 1 )); then
      bind_count=$(tc_action_bind_count_from_json "$output" police "$police_index" "$police_cookie") || probe_ok=0
      (( probe_ok == 0 || bind_count == expected_rules )) || probe_ok=0
    fi
  fi

  if ! ip link del "$interface" >/dev/null 2>&1; then
    warn "tc 能力探测临时接口清理失败：$interface"
    probe_ok=0
  fi
  if ! tc_delete_owned_action gact "$gact_index" "$gact_cookie" >/dev/null 2>&1; then
    warn "tc 能力探测 gact/$gact_index 无法在证明所有权后清理。"
    probe_ok=0
  fi
  if ! tc_delete_owned_action police "$police_index" "$police_cookie" >/dev/null 2>&1; then
    warn "tc 能力探测 police/$police_index 无法在证明所有权后清理。"
    probe_ok=0
  fi
  if (( probe_ok != 1 )); then
    error '当前内核/iproute2 不完整支持 clsact、flower、当前启用地址族的 TCP/UDP、共享 gact/police action、cookie、bind/handle 校验、可证明清理或 tc JSON 统计。'
    return 1
  fi
  signature=$(tc_capability_signature) || return 1
  manager_state_set_json tc_capabilities_verified true || return 1
  manager_state_set_json tc_capability_signature "$(jq -Rn --arg value "$signature" '$value')" || return 1
  success 'tc 流量统计与限速能力探测通过。'
}

ensure_tc_capabilities() {
  local expected recorded verified
  expected=$(tc_capability_signature) || return 1
  recorded=$(manager_state_get tc_capability_signature '') || return 1
  verified=$(manager_state_get tc_capabilities_verified false) || return 1
  if [[ "$verified" == true && "$recorded" == "$expected" ]]; then
    return 0
  fi
  probe_tc_capabilities
}

kernel_boot_id() {
  local boot_id=''
  [[ -r /proc/sys/kernel/random/boot_id ]] || return 1
  IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 1
  [[ "$boot_id" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || return 1
  printf '%s' "$boot_id"
}

bandwidth_plan_path() { printf '%s/bandwidth-plan.json' "$DATA_DIR"; }

bandwidth_plan_matches_current_boot() {
  local plan_file boot_id
  plan_file=$(bandwidth_plan_path) || return 1
  [[ -f "$plan_file" && ! -L "$plan_file" ]] || return 1
  boot_id=$(kernel_boot_id) || boot_id=unknown
  jq -e --arg boot_id "$boot_id" '.schema_version == 2 and .boot_id == $boot_id and (.actions | type == "array")' "$plan_file" >/dev/null 2>&1
}

bandwidth_plan_matches_current_families() {
  local plan_file families current planned
  plan_file=$(bandwidth_plan_path) || return 2
  [[ -f "$plan_file" && ! -L "$plan_file" ]] || return 1
  families=$(tc_active_families) || return 2
  current=$(printf '%s\n' "$families" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort') || return 2
  planned=$(jq -c '(.families // ["ip","ipv6"]) | unique | sort' "$plan_file" 2>/dev/null) || return 2
  [[ "$current" == "$planned" ]]
}

bandwidth_plan_interfaces() {
  local plan_file
  plan_file=$(bandwidth_plan_path) || return 1
  [[ ! -L "$plan_file" ]] || return 1
  [[ -f "$plan_file" ]] || return 0
  jq -r '.interfaces[]?' "$plan_file" 2>/dev/null || return 1
}

bandwidth_plan_families() {
  local plan_file=${1:-}
  [[ -n "$plan_file" ]] || plan_file=$(bandwidth_plan_path) || return 1
  [[ ! -L "$plan_file" ]] || return 1
  if [[ -f "$plan_file" ]]; then
    # Schema-2 plans created before family-aware probing always installed both.
    jq -r '(.families // ["ip","ipv6"])[]' "$plan_file" 2>/dev/null || return 1
  else
    tc_active_families
  fi
}

bandwidth_known_interfaces() {
  local current planned
  current=$(traffic_interfaces) || return 1
  planned=$(bandwidth_plan_interfaces) || return 1
  printf '%s\n%s\n' "$current" "$planned" | awk 'NF && !seen[$0]++'
}

bandwidth_plan_action() {
  local node_id=$1 direction=$2 plan_file
  plan_file=$(bandwidth_plan_path) || return 1
  [[ -f "$plan_file" && ! -L "$plan_file" ]] || return 1
  jq -ce --arg id "$node_id" --arg direction "$direction" '
    [.actions[]? | select(.node_id == $id and .direction == $direction)]
    | if length == 1 then .[0] else empty end
  ' "$plan_file"
}

bandwidth_pref() {
  local value
  value=$(manager_state_get tc_pref "$DEFAULT_TC_PREF") || return 1
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
  local interface=$1 output status=0
  output=$(ip -j link show dev "$interface" 2>/dev/null) || status=$?
  if (( status == 0 )); then
    jq -e --arg interface "$interface" 'type == "array" and length == 1 and .[0].ifname == $interface' \
      >/dev/null 2>&1 <<<"$output" || return 2
    return 0
  fi
  # `ip link show dev missing` and an operational query failure both return
  # non-zero.  A successful full enumeration distinguishes a genuinely absent
  # interface; if it still appears, retain ownership evidence and fail closed.
  output=$(ip -j link show 2>/dev/null) || return 2
  jq -e 'type == "array" and all(.[]; (.ifname | type == "string"))' >/dev/null 2>&1 <<<"$output" || return 2
  if jq -e --arg interface "$interface" 'any(.[]; .ifname == $interface)' >/dev/null 2>&1 <<<"$output"; then
    return 2
  fi
  return 1
}

tc_filter_normalize_json() {
  local output=$1
  if jq -e . >/dev/null 2>&1 <<<"$output"; then
    printf '%s' "$output"
    return 0
  fi
  # iproute2 5.10 emits the police action body as human-readable tokens
  # inside otherwise JSON-looking filter output. Normalize that one legacy
  # shape before applying the normal jq ownership and rule checks.
  printf '%s' "$output" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()
pattern = re.compile(
    r"\{\s*\"order\"\s*:\s*(?P<order>[0-9]+)\s+police\s+0x(?P<index>[0-9A-Fa-f]+).*?\"control_action\"\s*:\s*(?P<control>\{.*?\})\s+overhead\s+\S+\s+ref\s+(?P<ref>[0-9]+)\s+bind\s+(?P<bind>[0-9]+)\s*,(?P<after>.*?)\"cookie\"\s*:\s*\"(?P<cookie>[0-9A-Fa-f]{32})\"\s*\}",
    re.S,
)

def replace(match):
    return (
        "{\"order\":" + match.group("order")
        + ",\"kind\":\"police\",\"index\":" + str(int(match.group("index"), 16))
        + ",\"control_action\":" + match.group("control")
        + ",\"ref\":" + match.group("ref")
        + ",\"bind\":" + match.group("bind")
        + "," + match.group("after")
        + "\"cookie\":\"" + match.group("cookie") + "\"}"
    )

normalized = pattern.sub(replace, raw)
try:
    value = json.loads(normalized)
except (TypeError, ValueError):
    raise SystemExit(1)
json.dump(value, sys.stdout, separators=(",", ":"))
'
}

tc_filter_scoped_json() {
  local interface=$1 direction=$2 family=$3 pref=$4 raw qdisc interface_status=0
  tc_interface_exists "$interface" || interface_status=$?
  case "$interface_status" in
    0) ;;
    1) printf '[]'; return 0 ;;
    *) return 1 ;;
  esac
  qdisc=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
  if ! grep -q 'clsact' <<<"$qdisc"; then
    printf '[]'
    return 0
  fi
  raw=$(tc -j filter show dev "$interface" "$direction" 2>/dev/null) || return 1
  raw=$(tc_filter_normalize_json "$raw") || return 1
  jq -ce --arg family "$family" --argjson pref "$pref" '
    [ .[]
      | select((((.pref // -1) | tonumber?) // -1) == $pref)
      | select(((.protocol // "") | tostring | ascii_downcase) == $family)
    ]
  ' <<<"$raw"
}

tc_pref_is_free() {
  local pref=$1 interface family direction rules interfaces families
  interfaces=$(traffic_interfaces) || return 1
  families=$(tc_active_families) || return 1
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r family; do
      [[ -n "$family" ]] || continue
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$pref") || return 1
        [[ "$(jq -r 'length' <<<"$rules")" == 0 ]] || return 1
      done
    done <<<"$families"
  done <<<"$interfaces"
  return 0
}

ensure_bandwidth_pref() {
  local existing pref ipv6_pref
  existing=$(manager_state_get tc_pref '') || return 1
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
  jq --argjson pref "$pref" --argjson ipv6_pref "$ipv6_pref" \
    '.tc_pref=$pref | .tc_ipv6_pref=$ipv6_pref' "$MANAGER_STATE" \
    | atomic_json_from_stdin "$MANAGER_STATE" 600 || return 1
  printf '%s' "$pref"
}

record_manager_clsact_interface() {
  local interface=$1 current updated
  current=$(jq -c '.tc_clsact_interfaces // [] | if type == "array" then . else [] end' "$MANAGER_STATE") || return 1
  updated=$(jq -nc --argjson current "$current" --arg interface "$interface" '$current + [$interface] | unique') || return 1
  manager_state_set_json tc_clsact_interfaces "$updated"
}

ensure_clsact() {
  local interface=$1 qdisc
  qdisc=$(tc qdisc show dev "$interface" 2>/dev/null) || {
    error "无法可靠查询接口 $interface 的 qdisc，拒绝猜测 clsact 状态。"
    return 1
  }
  if ! grep -q 'clsact' <<<"$qdisc"; then
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
  local nodes_source=$1 output_file=$2 node node_id port direction limit identity index cookie kind node_lines protocols protocols_json
  jq -n '[]' >"$output_file" || return 1
  node_lines=$(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    port=$(jq -er '.port' <<<"$node") || return 1
    protocols=$(node_transport_protocols "$node") || return 1
    protocols_json=$(printf '%s\n' "$protocols" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
    for direction in ingress egress; do
      if [[ "$direction" == ingress ]]; then
        limit=$(jq -er '.upload_limit_mbps // 0' <<<"$node") || return 1
      else
        limit=$(jq -er '.download_limit_mbps // 0' <<<"$node") || return 1
      fi
      identity=$(bandwidth_action_identity "$node_id" "$direction") || return 1
      index=${identity%%$'\t'*}
      cookie=${identity#*$'\t'}
      kind=$(bandwidth_action_kind "$limit") || return 1
      jq --arg node_id "$node_id" --arg direction "$direction" --arg kind "$kind" --arg cookie "$cookie" \
        --argjson port "$port" --argjson index "$index" --argjson limit "$limit" --argjson protocols "$protocols_json" \
        '. += [{node_id:$node_id,direction:$direction,port:$port,kind:$kind,index:$index,cookie:$cookie,limit_mbps:$limit,protocols:$protocols}]' \
        "$output_file" >"$output_file.next" || return 1
      mv -f -- "$output_file.next" "$output_file" || return 1
    done
  done <<<"$node_lines"
  jq -e '([.[].index] | length) == ([.[].index] | unique | length) and all(.[]; (.cookie | test("^[a-f0-9]{32}$")))' "$output_file" >/dev/null || return 1
}

tc_action_entry_from_json() {
  local output=$1 kind=$2 index=$3
  if ! jq -e . >/dev/null 2>&1 <<<"$output"; then
    output=$(tc_action_legacy_json "$output" "$kind" "$index") || return 1
  fi
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

tc_action_legacy_json() {
  local output=$1 kind=$2 expected_index=$3
  local candidate index_hex index_decimal cookie bind bytes packets drops overlimits requeues backlog qlen

  [[ "$kind" == gact || "$kind" == police ]] || return 1
  [[ "$expected_index" =~ ^[0-9]+$ ]] || return 1

  # iproute2 5.10 emits an unquoted, human-readable `police` action body
  # despite accepting -j. Older iproute2 (for example Ubuntu 18.04) emits
  # the complete action listing in the same form and omits the decimal index
  # for police. Select the one matching block first, then extract only the
  # identity and counters needed by ownership/statistics checks.
  candidate=$output
  if grep -Eq '(^|[[:space:]])action order[[:space:]]+[0-9]+:' <<<"$output"; then
    local expected_hex
    expected_hex=$(printf '%x' "$expected_index") || return 1
    candidate=$(awk -v kind="$kind" -v expected="$expected_index" -v expected_hex="$expected_hex" '
      BEGIN { RS=""; ORS="\n\n" }
      {
        has_kind = ($0 ~ (": *" kind "[[:space:]]"))
        has_decimal = ($0 ~ ("index[[:space:]]+" expected "[[:space:]]"))
        has_hex = ($0 ~ ("[[:space:]]" kind "[[:space:]]+0x" expected_hex "([[:space:]]|$)"))
        if (has_kind && (has_decimal || has_hex)) { print; found=1; exit }
      }
      END { if (!found) exit 1 }
    ' <<<"$output") || return 1
  fi

  index_hex=$(sed -nE "s/.*[[:space:]]${kind}[[:space:]]+0x([0-9A-Fa-f]+).*/\1/p" <<<"$candidate" | head -n 1)
  if [[ -n "$index_hex" ]]; then
    index_decimal=$(printf '%d' "0x$index_hex") || return 1
  else
    index_decimal=$(sed -nE 's/.*index[[:space:]]+([0-9]+)[[:space:]]+ref[[:space:]]+[0-9]+[[:space:]]+bind[[:space:]]+[0-9]+.*/\1/p' <<<"$candidate" | head -n 1)
    [[ -n "$index_decimal" ]] || index_decimal=$(sed -nE 's/.*"index"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  fi
  [[ "$index_decimal" == "$expected_index" ]] || return 1

  cookie=$(sed -nE 's/.*"cookie"[[:space:]]*:[[:space:]]*"([0-9A-Fa-f]{32})".*/\1/p' <<<"$candidate" | head -n 1)
  [[ -n "$cookie" ]] || cookie=$(sed -nE 's/.*[[:space:]]cookie[[:space:]]+([0-9A-Fa-f]{32}).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$cookie" =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
  bind=$(sed -nE 's/.*[[:space:]]bind[[:space:]]+([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$bind" =~ ^[0-9]+$ ]] || bind=$(sed -nE 's/.*"bind"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$bind" =~ ^[0-9]+$ ]] || return 1

  bytes=$(sed -nE 's/.*"bytes"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  packets=$(sed -nE 's/.*"packets"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  drops=$(sed -nE 's/.*"drops"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  overlimits=$(sed -nE 's/.*"overlimits"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  requeues=$(sed -nE 's/.*"requeues"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  backlog=$(sed -nE 's/.*"backlog"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  qlen=$(sed -nE 's/.*"qlen"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=$(sed -nE 's/.*Sent[[:space:]]+([0-9]+)[[:space:]]+bytes.*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$packets" =~ ^[0-9]+$ ]] || packets=$(sed -nE 's/.*Sent[[:space:]]+[0-9]+[[:space:]]+bytes[[:space:]]+([0-9]+)[[:space:]]+pkt.*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$drops" =~ ^[0-9]+$ ]] || drops=$(sed -nE 's/.*dropped[[:space:]]+([0-9]+),.*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$overlimits" =~ ^[0-9]+$ ]] || overlimits=$(sed -nE 's/.*overlimits[[:space:]]+([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$requeues" =~ ^[0-9]+$ ]] || requeues=$(sed -nE 's/.*requeues[[:space:]]+([0-9]+).*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$backlog" =~ ^[0-9]+$ ]] || backlog=$(sed -nE 's/.*backlog[[:space:]]+([0-9]+)b.*/\1/p' <<<"$candidate" | head -n 1)
  [[ "$qlen" =~ ^[0-9]+$ ]] || qlen=$(sed -nE 's/.*backlog[[:space:]]+[0-9]+b[[:space:]]+([0-9]+)p.*/\1/p' <<<"$candidate" | head -n 1)
  bytes=${bytes:-0}; packets=${packets:-0}; drops=${drops:-0}; overlimits=${overlimits:-0}
  requeues=${requeues:-0}; backlog=${backlog:-0}; qlen=${qlen:-0}
  for value in "$bytes" "$packets" "$drops" "$overlimits" "$requeues" "$backlog" "$qlen"; do
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
  done
  jq -n \
    --arg kind "$kind" \
    --arg cookie "${cookie,,}" \
    --argjson index "$index_decimal" \
    --argjson bind "$bind" \
    --argjson bytes "$bytes" \
    --argjson packets "$packets" \
    --argjson drops "$drops" \
    --argjson overlimits "$overlimits" \
    --argjson requeues "$requeues" \
    --argjson backlog "$backlog" \
    --argjson qlen "$qlen" \
    '{kind:$kind,index:$index,cookie:$cookie,bind:$bind,stats:{bytes:$bytes,packets:$packets,drops:$drops,overlimits:$overlimits,requeues:$requeues,backlog:$backlog,qlen:$qlen}}'
}

tc_action_normalize_json() {
  local output=$1 kind=$2 index=$3
  if jq -e . >/dev/null 2>&1 <<<"$output"; then
    printf '%s' "$output"
  else
    tc_action_legacy_json "$output" "$kind" "$index"
  fi
}

tc_action_lookup() {
  local kind=$1 index=$2 output count status=0
  [[ "$kind" == gact || "$kind" == police ]] || return 1
  [[ "$index" =~ ^[0-9]+$ ]] || return 1
  # Query one index instead of listing all actions.  This avoids the invalid
  # police JSON emitted by iproute2 5.10 when any unrelated police action is
  # present, while still allowing an exact ownership decision.
  output=$(tc -j actions get action "$kind" index "$index" 2>&1) || status=$?
  if (( status != 0 )); then
    if grep -qiE 'specified index not found|no such file|not found' <<<"$output"; then
      return 1
    fi
    # iproute2 before the action-get JSON interface rejects the otherwise
    # valid `actions get action ...` form. Its list operation still exposes
    # indexed, cookie-bearing actions, so use that as a compatibility path.
    if grep -qi 'command "action" is unknown' <<<"$output"; then
      output=$(tc -j actions ls action "$kind" 2>&1) || return 2
    else
      return 2
    fi
  fi
  output=$(tc_action_normalize_json "$output" "$kind" "$index") || {
    status=$?
    (( status == 1 )) && return 1
    return 2
  }
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

tc_action_bind_count_from_json() {
  local output=$1 kind=$2 index=$3 cookie=$4 entry
  entry=$(tc_action_entry_from_json "$output" "$kind" "$index") || return 1
  tc_action_cookie_matches "$entry" "$cookie" || return 1
  jq -er '(.bind | tonumber?) as $bind | if ($bind != null and $bind >= 0 and ($bind | floor) == $bind) then $bind else error("invalid bind count") end' \
    <<<"$entry"
}

tc_delete_owned_action() {
  local kind=$1 index=$2 cookie=$3 entry status bind
  if entry=$(tc_action_lookup "$kind" "$index"); then
    tc_action_cookie_matches "$entry" "$cookie" || {
      error "tc action $kind/$index 已被其他程序占用，拒绝删除。"
      return 1
    }
    bind=$(tc_action_bind_count_from_json "$entry" "$kind" "$index" "$cookie") || return 1
    (( bind == 0 )) || {
      error "tc action $kind/$index 仍有 $bind 个过滤器绑定，拒绝删除。"
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
        tc_delete_owned_action "$other_kind" "$index" "$cookie" || return 1
      elif [[ "$other_kind" == "$kind" ]]; then
        error "tc action $kind/$index 已由其他程序使用，拒绝覆盖。"
        return 1
      fi
    else
      status=$?
      (( status == 1 )) || { error "无法检查 tc action $other_kind/$index。"; return 1; }
    fi
  done
  # Some kernels expose clsact/flower and cookie-bearing inline actions but
  # reject standalone `tc actions add` with EPERM.  Let the first filter bind
  # create that shared action in this mode; subsequent filters reuse its index
  # and cookie exactly like the standalone path.
  if [[ "$kind" == police ]]; then
    if tc actions add action police rate "${limit}mbit" burst 64kb mtu 64kb conform-exceed drop/pass index "$index" cookie "$cookie" skip_hw 2>/dev/null; then
      return 0
    fi
    # Older tc accepts cookie-bearing standalone actions but rejects the
    # skip_hw attribute on `actions add`; retain the same ownership contract
    # while omitting only that unsupported attribute.
    if tc actions add action police rate "${limit}mbit" burst 64kb mtu 64kb conform-exceed drop/pass index "$index" cookie "$cookie" 2>/dev/null; then
      return 0
    fi
  elif tc actions add action gact pass index "$index" cookie "$cookie" skip_hw 2>/dev/null; then
    return 0
  elif tc actions add action gact pass index "$index" cookie "$cookie" 2>/dev/null; then
    return 0
  fi
  if entry=$(tc_action_lookup "$kind" "$index"); then
    tc_action_cookie_matches "$entry" "$cookie" || {
      error "tc action $kind/$index 已由其他程序使用，拒绝以内联方式接管。"
      return 1
    }
    return 0
  else
    status=$?
    (( status == 1 )) || {
      error "无法确认 tc action $kind/$index 是否可由内联规则创建。"
      return 1
    }
    TC_INLINE_ACTIONS=1
    return 0
  fi
}

bandwidth_preflight_actions() {
  local actions_file=$1 action kind index cookie entry status action_lines
  action_lines=$(jq -c '.[]' "$actions_file") || return 1
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
  done <<<"$action_lines"
}

tc_add_flower_rule() {
  local interface=$1 direction=$2 family=$3 protocol=$4 port=$5 pref=$6 kind=$7 index=$8 cookie=${9:-}
  local -a args=(filter add dev "$interface" "$direction" pref "$pref" protocol "$family" flower skip_hw ip_proto "$protocol")
  if [[ "$direction" == ingress ]]; then args+=(dst_port "$port"); else args+=(src_port "$port"); fi
  args+=(action "$kind" index "$index")
  [[ "${TC_INLINE_ACTIONS:-0}" == 1 && -n "$cookie" ]] && args+=(cookie "$cookie")
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
        | ($options.actions // []) as $actions
        | select(($actions | length) == 1)
        | select(any($actions[];
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
      | ($options.actions // []) as $actions
      | select(($actions | length) == 1)
      | select(any($actions[];
          (((.kind // "") | tostring | ascii_downcase) == $expected_action)
          and ((((.index // -1) | tonumber?) // -1) == $expected_index)))
      | ($options.handle // .handle // empty)
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
  local interfaces node_lines
  validate_nodes_file_semantic "$nodes_source" || return 1
  interfaces=$(bandwidth_known_interfaces) || return 1
  node_lines=$(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source") || return 1
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        local rule_count
        rule_count=$(jq -er 'length' <<<"$rules") || return 1
        actual=$((actual + rule_count))
        while IFS= read -r node; do
          [[ -n "$node" ]] || continue
          port=$(jq -er '.port' <<<"$node") || return 1
          if [[ "$direction" == ingress ]]; then
            limit=$(jq -er '.upload_limit_mbps // 0' <<<"$node") || return 1
          else
            limit=$(jq -er '.download_limit_mbps // 0' <<<"$node") || return 1
          fi
          kind=$(bandwidth_action_kind "$limit") || return 1
          while IFS= read -r protocol; do
            [[ -n "$protocol" ]] || continue
            count=$(tc_rule_json_match_count "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind") || return 1
            (( count <= 1 )) || { printf 'mixed'; return 0; }
            matched=$((matched + count))
          done < <(node_transport_protocols "$node")
        done <<<"$node_lines"
      done
    done
  done <<<"$interfaces"
  if (( actual == 0 )); then printf 'empty'
  elif (( matched == 0 )); then printf 'foreign'
  elif (( actual == matched )); then printf 'managed'
  else printf 'mixed'
  fi
}

bandwidth_reset_empty_manager_clsact() {
  local interface_lines=$1 interface qdisc ingress egress
  local -a removed=()

  # Some older kernels keep a stale action bind count until the clsact qdisc
  # itself disappears. Only use that escape hatch when every affected
  # interface is recorded as created by Ss2022 and both directions are
  # provably empty after the owned filters were removed. A foreign rule or an
  # unknown qdisc state therefore remains a hard stop rather than being
  # overwritten.
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    jq -e --arg interface "$interface" '
      (.tc_clsact_interfaces // []) as $interfaces
      | ($interfaces | type == "array")
      and any($interfaces[]; . == $interface)
    ' "$MANAGER_STATE" >/dev/null 2>&1 || return 1
    qdisc=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
    grep -q 'clsact' <<<"$qdisc" || return 1
    ingress=$(tc -j filter show dev "$interface" ingress 2>/dev/null) || return 1
    egress=$(tc -j filter show dev "$interface" egress 2>/dev/null) || return 1
    ingress=$(tc_filter_normalize_json "$ingress") || return 1
    egress=$(tc_filter_normalize_json "$egress") || return 1
    jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<<"$ingress" || return 1
    jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<<"$egress" || return 1
  done <<<"$interface_lines"

  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    if ! tc qdisc del dev "$interface" clsact >/dev/null 2>&1; then
      local restore
      for restore in "${removed[@]}"; do
        tc qdisc add dev "$restore" clsact >/dev/null 2>&1 || true
      done
      return 1
    fi
    removed+=("$interface")
  done <<<"$interface_lines"
  printf '%s\n' "${removed[@]}"
}

bandwidth_recreate_manager_clsact() {
  local interface_lines=$1 interface
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    tc qdisc add dev "$interface" clsact >/dev/null 2>&1 || return 1
  done <<<"$interface_lines"
}

bandwidth_delete_legacy_filters() {
  local pref=$1 interface family direction family_pref rules interfaces
  interfaces=$(bandwidth_known_interfaces) || return 1
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    for family in ip ipv6; do
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        local rule_count
        rule_count=$(jq -er 'length' <<<"$rules") || return 1
        if (( rule_count > 0 )); then
          tc filter del dev "$interface" "$direction" protocol "$family" pref "$family_pref" >/dev/null || return 1
        fi
      done
    done
  done <<<"$interfaces"
}

bandwidth_remove_plan() {
  local plan_file=$1 pref action entry status expected_bind bind interface family direction family_pref rules actions_json owned_count
  local node_id port kind index cookie protocol handles handle action_key action_lines interface_lines family_lines direction_action_lines protocol_lines protocol_count
  local reset_interfaces='' needs_clsact_reset=0
  local -a deletions=()
  local -A observed_bind=()
  [[ -f "$plan_file" && ! -L "$plan_file" ]] || return 1
  validate_bandwidth_plan_semantic "$plan_file" || return 1
  pref=$(jq -er '.pref' "$plan_file") || return 1
  local interface_count family_count
  interface_count=$(jq -er '.interfaces | length' "$plan_file") || return 1
  action_lines=$(jq -c '.actions[]' "$plan_file") || return 1
  interface_lines=$(jq -r '.interfaces[]?' "$plan_file") || return 1
  family_lines=$(bandwidth_plan_families "$plan_file") || return 1
  family_count=$(awk 'NF {count++} END {print count+0}' <<<"$family_lines") || return 1
  (( family_count >= 1 )) || return 1
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || return 1
    index=$(jq -er '.index' <<<"$action") || return 1
    cookie=$(jq -er '.cookie' <<<"$action") || return 1
    protocol_count=$(jq -er '(.protocols // ["tcp","udp"]) | length' <<<"$action") || return 1
    expected_bind=$((interface_count * family_count * protocol_count))
    action_key="$kind:$index"
    observed_bind["$action_key"]=0
    if entry=$(tc_action_lookup "$kind" "$index"); then
      tc_action_cookie_matches "$entry" "$cookie" || { error "tc action $kind/$index 所有权不匹配，拒绝清理。"; return 1; }
      bind=$(tc_action_bind_count_from_json "$entry" "$kind" "$index" "$cookie") || return 1
      (( bind <= expected_bind )) || { error "tc action $kind/$index 存在额外绑定，拒绝影响其他规则。"; return 1; }
    else
      status=$?
      (( status == 1 )) || return 1
    fi
  done <<<"$action_lines"

  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r family; do
      [[ -n "$family" ]] || continue
      family_pref=$(tc_family_pref "$pref" "$family") || return 1
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || return 1
        actions_json=$(jq -c --arg direction "$direction" '[.actions[] | select(.direction == $direction)]' "$plan_file") || return 1
        direction_action_lines=$(jq -c --arg direction "$direction" '.actions[] | select(.direction == $direction)' "$plan_file") || return 1
        local matched_count=0
        while IFS= read -r action; do
          [[ -n "$action" ]] || continue
          node_id=$(jq -er '.node_id' <<<"$action") || return 1
          : "$node_id"
          port=$(jq -er '.port' <<<"$action") || return 1
          kind=$(jq -er '.kind' <<<"$action") || return 1
          index=$(jq -er '.index' <<<"$action") || return 1
          protocol_lines=$(jq -r '(.protocols // ["tcp","udp"])[]' <<<"$action") || return 1
          while IFS= read -r protocol; do
            [[ -n "$protocol" ]] || continue
            handles=$(tc_rule_json_handles "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind" "$index") || return 1
            local handle_count
            handle_count=$(awk 'NF {count++} END {print count+0}' <<<"$handles") || return 1
            (( handle_count <= 1 )) || { error "检测到重复的 Ss2022 tc 规则，拒绝模糊清理。"; return 1; }
            if (( handle_count == 1 )); then
              handle=$(awk 'NF {print; exit}' <<<"$handles") || return 1
              [[ "$handle" =~ ^(0x)?[A-Fa-f0-9]+$ ]] || { error "tc filter handle 无效：$handle"; return 1; }
              deletions+=("$interface"$'\t'"$direction"$'\t'"$family"$'\t'"$family_pref"$'\t'"$handle")
              matched_count=$((matched_count + 1))
              action_key="$kind:$index"
              observed_bind["$action_key"]=$(( ${observed_bind["$action_key"]:-0} + 1 ))
            fi
          done <<<"$protocol_lines"
        done <<<"$direction_action_lines"
        owned_count=$(tc_rule_owned_action_count "$rules" "$actions_json") || return 1
        (( owned_count == matched_count )) || { error "tc 优先级包含使用 Ss2022 action 的未知规则，拒绝删除。"; return 1; }
      done
    done <<<"$family_lines"
  done <<<"$interface_lines"

  # Prove that every kernel binding of each owned action is one of the exact
  # handles collected above.  A foreign binding outside our interfaces or
  # priorities must stop cleanup before the first filter is deleted.
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || return 1
    index=$(jq -er '.index' <<<"$action") || return 1
    cookie=$(jq -er '.cookie' <<<"$action") || return 1
    action_key="$kind:$index"
    if entry=$(tc_action_lookup "$kind" "$index"); then
      tc_action_cookie_matches "$entry" "$cookie" || return 1
      bind=$(tc_action_bind_count_from_json "$entry" "$kind" "$index" "$cookie") || return 1
      (( bind == ${observed_bind["$action_key"]:-0} )) || {
        error "tc action $kind/$index 存在计划范围外或竞态新增的绑定，拒绝删除。"
        return 1
      }
    else
      status=$?
      (( status == 1 && ${observed_bind["$action_key"]:-0} == 0 )) || return 1
    fi
  done <<<"$action_lines"

  local deletion
  for deletion in "${deletions[@]}"; do
    IFS=$'\t' read -r interface direction family family_pref handle <<<"$deletion"
    tc filter del dev "$interface" "$direction" protocol "$family" pref "$family_pref" handle "$handle" flower >/dev/null || return 1
  done

  # Linux 4.15 can retain a non-zero action bind count after the last filter
  # is deleted. Before removing the action, prove every affected clsact is
  # empty and owned by this manager, then reset only those qdiscs. Modern
  # kernels report bind=0 here and take the normal path without a qdisc reset.
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || return 1
    index=$(jq -er '.index' <<<"$action") || return 1
    cookie=$(jq -er '.cookie' <<<"$action") || return 1
    if entry=$(tc_action_lookup "$kind" "$index"); then
      tc_action_cookie_matches "$entry" "$cookie" || return 1
      bind=$(tc_action_bind_count_from_json "$entry" "$kind" "$index" "$cookie") || return 1
      (( bind > 0 )) && needs_clsact_reset=1
    else
      status=$?
      (( status == 1 )) || return 1
    fi
  done <<<"$action_lines"
  if (( needs_clsact_reset == 1 )); then
    reset_interfaces=$(bandwidth_reset_empty_manager_clsact "$interface_lines") || {
      error '旧版内核的 tc action 仍有绑定，且无法证明项目 clsact 已完全为空；拒绝清理。'
      return 1
    }
    [[ -n "$reset_interfaces" ]] || {
      error '旧版内核的 tc action 绑定无法安全归零；拒绝清理。'
      return 1
    }
  fi

  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || return 1
    index=$(jq -er '.index' <<<"$action") || return 1
    cookie=$(jq -er '.cookie' <<<"$action") || return 1
    if ! tc_delete_owned_action "$kind" "$index" "$cookie"; then
      [[ -z "$reset_interfaces" ]] || bandwidth_recreate_manager_clsact "$reset_interfaces" || true
      return 1
    fi
  done <<<"$action_lines"
  if [[ -n "$reset_interfaces" ]]; then
    bandwidth_recreate_manager_clsact "$reset_interfaces" || return 1
  fi
}

delete_manager_tc_filters() {
  local pref=${1:-} nodes_source=${2:-$NODES_FILE} plan_file state
  [[ -n "$pref" ]] || pref=$(bandwidth_pref) || return 1
  plan_file=$(bandwidth_plan_path) || return 1
  if [[ -e "$plan_file" || -L "$plan_file" ]]; then
    [[ -f "$plan_file" && ! -L "$plan_file" ]] || {
      error "tc 规则计划不是常规文件或为符号链接：$plan_file。无法证明所有权，拒绝清理。"
      return 1
    }
    if jq -e '.schema_version == 2 and (.actions | type == "array")' "$plan_file" >/dev/null 2>&1; then
      bandwidth_remove_plan "$plan_file" || return 1
      rm -f -- "$plan_file" || return 1
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
  rm -f -- "$plan_file" || return 1
}

bandwidth_candidate_cleanup() {
  local plan_file=$1 live_plan
  if bandwidth_remove_plan "$plan_file" >/dev/null 2>&1; then
    live_plan=$(bandwidth_plan_path) || {
      warn '候选 tc 规则已清理，但无法确定持久计划路径。'
      return 1
    }
    rm -f -- "$live_plan" || {
      warn '候选 tc 规则已清理，但持久计划文件删除失败。'
      return 1
    }
  else
    warn '候选 tc 规则清理不完整；持久计划证据已保留，请通过 rem 查看 tc 状态。'
    return 1
  fi
}

bandwidth_apply_candidate_abort() {
  local plan_file=$1 actions_file=$2
  bandwidth_candidate_cleanup "$plan_file" || true
  rm -f -- "$actions_file" "$actions_file.next" "$plan_file" || true
  return 0
}

bandwidth_apply_nodes() {
  local nodes_source=$1 interfaces_count has_limit=0 node node_lines interfaces families
  local actions_file
  actions_file=$(runtime_temp_file bandwidth-actions) || return 1
  validate_nodes_file_semantic "$nodes_source" || { rm -f -- "$actions_file"; return 1; }
  node_lines=$(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source") || { rm -f -- "$actions_file"; return 1; }
  interfaces=$(traffic_interfaces) || { rm -f -- "$actions_file"; return 1; }
  families=$(tc_active_families) || { rm -f -- "$actions_file"; return 1; }
  interfaces_count=$(awk 'NF {count++} END {print count+0}' <<<"$interfaces") || { rm -f -- "$actions_file"; return 1; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    local node_upload node_download
    node_upload=$(jq -er '.upload_limit_mbps // 0' <<<"$node") || { rm -f -- "$actions_file"; return 1; }
    node_download=$(jq -er '.download_limit_mbps // 0' <<<"$node") || { rm -f -- "$actions_file"; return 1; }
    if [[ "$node_upload" != 0 || "$node_download" != 0 ]]; then
      has_limit=1
      break
    fi
  done <<<"$node_lines"
  if (( interfaces_count == 0 )); then
    if (( has_limit == 1 )); then
      error '没有默认路由接口，无法安全应用节点限速。'
      rm -f -- "$actions_file"
      return 1
    fi
    local current_pref
    current_pref=$(bandwidth_pref) || { rm -f -- "$actions_file"; return 1; }
    delete_manager_tc_filters "$current_pref" "$NODES_FILE" || { rm -f -- "$actions_file"; return 1; }
    rm -f -- "$actions_file" || return 1
    warn '没有默认路由接口，已保留节点配置；流量统计/限速等待接口配置。'
    return 0
  fi
  bandwidth_build_actions "$nodes_source" "$actions_file" || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }
  bandwidth_preflight_actions "$actions_file" || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }
  local current_pref
  current_pref=$(bandwidth_pref) || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }
  delete_manager_tc_filters "$current_pref" "$NODES_FILE" \
    || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }

  local pref ipv6_pref plan_candidate interfaces_json families_json boot_id action_lines family_lines
  local live_plan_path updated_at
  pref=$(ensure_bandwidth_pref) || { rm -f -- "$actions_file"; return 1; }
  ipv6_pref=$(tc_family_pref "$pref" ipv6) || { rm -f -- "$actions_file"; return 1; }
  : "$ipv6_pref"
  plan_candidate=$(runtime_temp_file bandwidth-plan) || { rm -f -- "$actions_file" "$actions_file.next"; return 1; }
  interfaces_json=$(printf '%s\n' "$interfaces" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') \
    || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  families_json=$(printf '%s\n' "$families" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique') \
    || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  jq -e 'length >= 1 and all(.[]; . == "ip" or . == "ipv6")' >/dev/null <<<"$families_json" \
    || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  boot_id=$(kernel_boot_id) || boot_id=unknown
  updated_at=$(timestamp_iso) || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  jq -n --argjson pref "$pref" --arg boot_id "$boot_id" --arg updated_at "$updated_at" --argjson interfaces "$interfaces_json" --argjson families "$families_json" \
    --slurpfile actions "$actions_file" \
    '{schema_version:2,pref:$pref,boot_id:$boot_id,interfaces:$interfaces,families:$families,actions:$actions[0],updated_at:$updated_at}' >"$plan_candidate" || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  validate_bandwidth_plan_semantic "$plan_candidate" || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }

  action_lines=$(jq -c '.[]' "$actions_file") || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  family_lines=$(jq -r '.families[]' "$plan_candidate") || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  # Persist ownership evidence before the first kernel mutation.  After a
  # SIGKILL or power loss, startup recovery can then identify and remove even
  # a partially-created action/filter set without guessing.
  live_plan_path=$(bandwidth_plan_path) || { rm -f -- "$actions_file" "$plan_candidate"; return 1; }
  atomic_json_write "$plan_candidate" "$live_plan_path" 600 || {
    rm -f -- "$actions_file" "$plan_candidate"
    return 1
  }

  local interface action kind index cookie limit port direction family family_pref protocol protocol_lines
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    ensure_clsact "$interface" || {
      error "无法在接口 $interface 上准备 clsact。"
      bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"
      return 1
    }
  done <<<"$interfaces"
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
    index=$(jq -er '.index' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
    cookie=$(jq -er '.cookie' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
    limit=$(jq -er '.limit_mbps' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
    if ! tc_create_shared_action "$kind" "$index" "$cookie" "$limit"; then
      error "无法创建聚合 tc action：$kind/$index"
      bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"
      return 1
    fi
  done <<<"$action_lines"
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r action; do
      [[ -n "$action" ]] || continue
      port=$(jq -er '.port' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
      direction=$(jq -er '.direction' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
      kind=$(jq -er '.kind' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
      index=$(jq -er '.index' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
      cookie=$(jq -er '.cookie' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
      while IFS= read -r family; do
        [[ -n "$family" ]] || continue
        family_pref=$(tc_family_pref "$pref" "$family") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
        protocol_lines=$(jq -r '(.protocols // ["tcp","udp"])[]' <<<"$action") || { bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"; return 1; }
        while IFS= read -r protocol; do
          [[ -n "$protocol" ]] || continue
          if ! tc_add_flower_rule "$interface" "$direction" "$family" "$protocol" "$port" "$family_pref" "$kind" "$index" "$cookie"; then
            error "tc 规则创建失败：接口 $interface，$direction，$family/$protocol，端口 $port"
            bandwidth_apply_candidate_abort "$plan_candidate" "$actions_file"
            return 1
          fi
        done <<<"$protocol_lines"
      done <<<"$family_lines"
    done <<<"$action_lines"
  done <<<"$interfaces"
  rm -f -- "$actions_file" "$actions_file.next" "$plan_candidate" \
    || warn 'tc 规则已经发布，但运行时候选文件清理失败。'
}

bandwidth_check_nodes() {
  local nodes_source=$1 interfaces_count has_limit=0 node plan_file expected_actions node_lines interfaces families action_lines
  local current_interfaces plan_interfaces current_families plan_families family_count
  validate_nodes_file_semantic "$nodes_source" || return 1
  node_lines=$(jq -c '.nodes[] | select(.status == "enabled")' "$nodes_source") || return 1
  interfaces=$(traffic_interfaces) || return 1
  families=$(tc_active_families) || return 1
  interfaces_count=$(awk 'NF {count++} END {print count+0}' <<<"$interfaces") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    local node_upload node_download
    node_upload=$(jq -er '.upload_limit_mbps // 0' <<<"$node") || return 1
    node_download=$(jq -er '.download_limit_mbps // 0' <<<"$node") || return 1
    if [[ "$node_upload" != 0 || "$node_download" != 0 ]]; then has_limit=1; break; fi
  done <<<"$node_lines"
  if (( interfaces_count == 0 )); then (( has_limit == 0 )); return; fi
  plan_file=$(bandwidth_plan_path) || return 1
  bandwidth_plan_matches_current_boot || return 1
  expected_actions=$(runtime_temp_file bandwidth-check-actions) || return 1
  bandwidth_build_actions "$nodes_source" "$expected_actions" || { rm -f -- "$expected_actions"; return 1; }
  jq -e --slurpfile expected "$expected_actions" '(.actions | sort_by(.node_id,.direction)) == ($expected[0] | sort_by(.node_id,.direction))' "$plan_file" >/dev/null || {
    rm -f -- "$expected_actions"
    return 1
  }
  current_interfaces=$(printf '%s\n' "$interfaces" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort') \
    || { rm -f -- "$expected_actions"; return 1; }
  plan_interfaces=$(jq -c '.interfaces | unique | sort' "$plan_file") \
    || { rm -f -- "$expected_actions"; return 1; }
  [[ "$current_interfaces" == "$plan_interfaces" ]] || { rm -f -- "$expected_actions"; return 1; }
  current_families=$(printf '%s\n' "$families" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort') || { rm -f -- "$expected_actions"; return 1; }
  plan_families=$(jq -c '(.families // ["ip","ipv6"]) | unique | sort' "$plan_file") || { rm -f -- "$expected_actions"; return 1; }
  [[ "$current_families" == "$plan_families" ]] || { rm -f -- "$expected_actions"; return 1; }
  family_count=$(jq -r 'length' <<<"$plan_families") || { rm -f -- "$expected_actions"; return 1; }
  (( family_count >= 1 )) || { rm -f -- "$expected_actions"; return 1; }

  local action kind index cookie entry expected_bind bind protocol_count
  action_lines=$(jq -c '.[]' "$expected_actions") || { rm -f -- "$expected_actions"; return 1; }
  while IFS= read -r action; do
    [[ -n "$action" ]] || continue
    kind=$(jq -er '.kind' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
    index=$(jq -er '.index' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
    cookie=$(jq -er '.cookie' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
    protocol_count=$(jq -er '(.protocols // ["tcp","udp"]) | length' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
    expected_bind=$((interfaces_count * family_count * protocol_count))
    if ! entry=$(tc_action_lookup "$kind" "$index"); then rm -f -- "$expected_actions"; return 1; fi
    tc_action_cookie_matches "$entry" "$cookie" || { rm -f -- "$expected_actions"; return 1; }
    bind=$(tc_action_bind_count_from_json "$entry" "$kind" "$index" "$cookie") || { rm -f -- "$expected_actions"; return 1; }
    (( bind == expected_bind )) || { rm -f -- "$expected_actions"; return 1; }
  done <<<"$action_lines"

  local pref interface family family_pref direction rules actions_json owned_count expected_owned port protocol match_count
  local plan_family_lines direction_action_lines protocol_lines
  pref=$(jq -er '.pref' "$plan_file") || { rm -f -- "$expected_actions"; return 1; }
  plan_family_lines=$(jq -r '.[]' <<<"$plan_families") || { rm -f -- "$expected_actions"; return 1; }
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    while IFS= read -r family; do
      [[ -n "$family" ]] || continue
      family_pref=$(tc_family_pref "$pref" "$family") || { rm -f -- "$expected_actions"; return 1; }
      for direction in ingress egress; do
        rules=$(tc_filter_scoped_json "$interface" "$direction" "$family" "$family_pref") || { rm -f -- "$expected_actions"; return 1; }
        actions_json=$(jq -c --arg direction "$direction" '[.[] | select(.direction == $direction)]' "$expected_actions") || { rm -f -- "$expected_actions"; return 1; }
        direction_action_lines=$(jq -c '.[]' <<<"$actions_json") || { rm -f -- "$expected_actions"; return 1; }
        expected_owned=$(jq -r '[.[] | ((.protocols // ["tcp","udp"]) | length)] | add // 0' <<<"$actions_json") || { rm -f -- "$expected_actions"; return 1; }
        owned_count=$(tc_rule_owned_action_count "$rules" "$actions_json") || { rm -f -- "$expected_actions"; return 1; }
        [[ "$owned_count" == "$expected_owned" ]] || { rm -f -- "$expected_actions"; return 1; }
        while IFS= read -r action; do
          [[ -n "$action" ]] || continue
          port=$(jq -er '.port' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
          kind=$(jq -er '.kind' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
          index=$(jq -er '.index' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
          protocol_lines=$(jq -r '(.protocols // ["tcp","udp"])[]' <<<"$action") || { rm -f -- "$expected_actions"; return 1; }
          while IFS= read -r protocol; do
            [[ -n "$protocol" ]] || continue
            match_count=$(tc_rule_json_match_count "$rules" "$family_pref" "$family" "$protocol" "$direction" "$port" "$kind" "$index") || { rm -f -- "$expected_actions"; return 1; }
            [[ "$match_count" == 1 ]] || { rm -f -- "$expected_actions"; return 1; }
          done <<<"$protocol_lines"
        done <<<"$direction_action_lines"
      done
    done <<<"$plan_family_lines"
  done <<<"$interfaces"
  rm -f -- "$expected_actions" "$expected_actions.next" || return 1
}

bandwidth_apply_and_check() {
  local nodes_source=$1
  bandwidth_apply_nodes "$nodes_source" || return 1
  bandwidth_check_nodes "$nodes_source"
}

bandwidth_status() {
  local pref interface ipv6_pref plan_file action kind index interfaces action_lines
  pref=$(bandwidth_pref) || return 1
  ipv6_pref=$(tc_family_pref "$pref" ipv6 2>/dev/null || printf '%s' "$pref")
  printf 'tc 管理优先级：IPv4 %s，IPv6 %s\n' "$pref" "$ipv6_pref"
  interfaces=$(traffic_interfaces) || {
    error '无法读取流量接口状态。'
    return 1
  }
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    printf '\n接口：%s\n' "$interface"
    tc -s filter show dev "$interface" ingress protocol ip pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress protocol ip pref "$pref" 2>/dev/null || true
    tc -s filter show dev "$interface" ingress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
    tc -s filter show dev "$interface" egress protocol ipv6 pref "$ipv6_pref" 2>/dev/null || true
  done <<<"$interfaces"
  plan_file=$(bandwidth_plan_path) || return 1
  if [[ -e "$plan_file" || -L "$plan_file" ]]; then
    [[ -f "$plan_file" && ! -L "$plan_file" ]] || {
      error 'tc 计划不是常规文件或为符号链接，拒绝展示不可信内容。'
      return 1
    }
    action_lines=$(jq -c '.actions[]?' "$plan_file") || return 1
    printf '\n聚合 action：\n'
    while IFS= read -r action; do
      [[ -n "$action" ]] || continue
      kind=$(jq -er '.kind' <<<"$action") || return 1
      index=$(jq -er '.index' <<<"$action") || return 1
      tc -s actions get action "$kind" index "$index" 2>/dev/null || true
    done <<<"$action_lines"
  fi
}

bandwidth_remove_manager_clsact() {
  local interfaces interface ingress egress remaining='[]' query_ok interface_lines interface_status
  interfaces=$(jq -ce '.tc_clsact_interfaces // [] | if type == "array" then . else error("invalid clsact interface state") end' "$MANAGER_STATE" 2>/dev/null) || {
    error '无法读取本项目创建的 clsact 接口记录，拒绝删除任何 clsact。'
    return 1
  }
  interface_lines=$(jq -r '.[]' <<<"$interfaces") || return 1
  while IFS= read -r interface; do
    [[ -n "$interface" ]] || continue
    interface_status=0
    tc_interface_exists "$interface" || interface_status=$?
    if (( interface_status == 1 )); then
      continue
    elif (( interface_status == 2 )); then
      warn "无法可靠查询接口 $interface 是否存在，已保留其 clsact 所有权记录。"
      remaining=$(jq -nc --argjson current "$remaining" --arg interface "$interface" '$current + [$interface] | unique') || return 1
      continue
    fi
    query_ok=1
    ingress=$(tc -j filter show dev "$interface" ingress 2>/dev/null) || query_ok=0
    egress=$(tc -j filter show dev "$interface" egress 2>/dev/null) || query_ok=0
    if (( query_ok == 0 )) || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ingress" \
      || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$egress"; then
      warn "无法可靠查询接口 $interface 的全部 clsact 过滤器，已保留该 qdisc。"
      remaining=$(jq -nc --argjson current "$remaining" --arg interface "$interface" '$current + [$interface] | unique') || return 1
    elif jq -e 'length == 0' >/dev/null <<<"$ingress" \
      && jq -e 'length == 0' >/dev/null <<<"$egress"; then
      if ! tc qdisc del dev "$interface" clsact >/dev/null 2>&1; then
        warn "接口 $interface 的空 clsact 删除失败，已保留所有权记录。"
        remaining=$(jq -nc --argjson current "$remaining" --arg interface "$interface" '$current + [$interface] | unique') || return 1
      fi
    else
      warn "接口 $interface 的 clsact 仍有其他规则，已保留。"
      remaining=$(jq -nc --argjson current "$remaining" --arg interface "$interface" '$current + [$interface] | unique') || return 1
    fi
  done <<<"$interface_lines"
  manager_state_set_json tc_clsact_interfaces "$remaining" >/dev/null || return 1
}

bandwidth_remove_manager_rules() {
  local pref plan_file
  pref=$(bandwidth_pref) || return 1
  delete_manager_tc_filters "$pref" "$NODES_FILE" || return 1
  bandwidth_remove_manager_clsact || return 1
  plan_file=$(bandwidth_plan_path) || return 1
  rm -f -- "$plan_file" || return 1
}
