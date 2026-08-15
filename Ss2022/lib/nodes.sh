#!/usr/bin/env bash
# Node identity, validation, selection and user-facing node operations.

node_count() {
  jq '.nodes | length' "$NODES_FILE"
}

node_by_id() {
  local node_id=$1
  jq -ce --arg id "$node_id" '[.nodes[] | select(.node_id == $id)] | if length == 1 then .[0] else empty end' "$NODES_FILE"
}

node_exists() {
  local node_id=$1
  jq -e --arg id "$node_id" 'any(.nodes[]; .node_id == $id)' "$NODES_FILE" >/dev/null
}

node_name_exists() {
  local name=$1
  local exclude_id=${2:-}
  jq -e --arg name "$name" --arg exclude "$exclude_id" \
    'any(.nodes[]; (.name | ascii_downcase) == ($name | ascii_downcase) and .node_id != $exclude)' "$NODES_FILE" >/dev/null
}

unique_node_name() {
  local requested=$1
  local exclude_id=${2:-}
  local exists_status=0
  validate_name "$requested" || return 1
  node_name_exists "$requested" "$exclude_id" || exists_status=$?
  if (( exists_status == 1 )); then
    printf '%s' "$requested"
    return 0
  fi
  (( exists_status == 0 )) || return 1
  local index=2 candidate suffix prefix_length
  while true; do
    suffix="-${index}"
    prefix_length=$((64 - ${#suffix}))
    (( prefix_length > 0 )) || return 1
    candidate="${requested:0:prefix_length}${suffix}"
    validate_name "$candidate" || return 1
    exists_status=0
    node_name_exists "$candidate" "$exclude_id" || exists_status=$?
    if (( exists_status == 1 )); then
      printf '%s' "$candidate"
      return 0
    fi
    (( exists_status == 0 )) || return 1
    ((index++))
  done
}

node_port_in_database() {
  local port=$1
  local exclude_id=${2:-}
  jq -e --argjson port "$port" --arg exclude "$exclude_id" \
    'any(.nodes[]; .port == $port and .node_id != $exclude)' "$NODES_FILE" >/dev/null
}

system_port_in_use_for_protocol() {
  local port=$1 protocol=${2:-shadowsocks} tcp_listeners udp_listeners
  local pattern="(^|:)${port}$"
  case "$protocol" in
    shadowsocks|vless) tcp_listeners=$(ss -H -ltn 2>/dev/null) || return 2 ;;
    hysteria2|tuic) ;;
    *) return 2 ;;
  esac
  if [[ "$protocol" == shadowsocks || "$protocol" == hysteria2 || "$protocol" == tuic ]]; then
    udp_listeners=$(ss -H -lun 2>/dev/null) || return 2
  fi
  if [[ "$protocol" != hysteria2 && "$protocol" != tuic ]] && awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' <<<"$tcp_listeners"; then
    return 0
  fi
  if [[ "$protocol" == shadowsocks || "$protocol" == hysteria2 || "$protocol" == tuic ]]; then
    awk -v pattern="$pattern" '$4 ~ pattern { found=1 } END { exit !found }' <<<"$udp_listeners" && return 0
  fi
  return 1
}

system_port_in_use() {
  system_port_in_use_for_protocol "$1" shadowsocks
}

port_available() {
  local port=$1
  local exclude_id=${2:-}
  local protocol=${3:-}
  if [[ -z "$protocol" ]]; then
    if [[ -n "$exclude_id" ]]; then
      protocol=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | (.protocol // "shadowsocks")' "$NODES_FILE") || return 2
    else
      protocol=shadowsocks
    fi
  fi
  [[ "$protocol" == shadowsocks || "$protocol" == vless || "$protocol" == hysteria2 || "$protocol" == tuic ]] || return 2
  local database_status=0
  validate_port "$port" || return 1
  node_port_in_database "$port" "$exclude_id" || database_status=$?
  (( database_status == 1 )) || {
    (( database_status == 0 )) && return 1
    return 2
  }
  local port_state=0
  if [[ "$protocol" == shadowsocks ]]; then
    system_port_in_use "$port" || port_state=$?
  else
    system_port_in_use_for_protocol "$port" "$protocol" || port_state=$?
  fi
  (( port_state != 2 )) || return 2
  if (( port_state == 0 )); then
    # While editing an enabled node, its unchanged live port is expected to
    # be occupied by sing-box.  Every other occupied port remains forbidden.
    [[ -n "$exclude_id" ]] || return 1
    local live_port live_status
    live_port=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | .port' "$NODES_FILE") || return 2
    live_status=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | .status' "$NODES_FILE") || return 2
    [[ "$live_status" == enabled && "$live_port" == "$port" ]] || return 1
    singbox_is_active || return 1
    singbox_owns_node_port "$port" '' "$protocol" || return 1
  fi
  return 0
}

# Called without an argument for new nodes and with an excluded Node ID while
# editing; ShellCheck cannot see the latter across separately sourced modules.
# shellcheck disable=SC2120
choose_port() {
  local exclude_id=${1:-}
  local protocol=${2:-}
  if [[ -z "$protocol" ]]; then
    if [[ -n "$exclude_id" ]]; then
      protocol=$(jq -r --arg id "$exclude_id" '.nodes[] | select(.node_id == $id) | (.protocol // "shadowsocks")' "$NODES_FILE") || return 1
    else
      protocol=shadowsocks
    fi
  fi
  local port attempt availability_status
  while true; do
    printf '请输入端口（回车随机，范围 %s-%s）：\n> ' "$DEFAULT_PORT_MIN" "$DEFAULT_PORT_MAX" >&2
    IFS= read -r port || die "读取输入失败。"
    port=$(trim_spaces "$port")
    if [[ -z "$port" ]]; then
      for ((attempt=1; attempt<=500; attempt++)); do
        port=$(shuf -i "${DEFAULT_PORT_MIN}-${DEFAULT_PORT_MAX}" -n 1)
        if port_available "$port" "$exclude_id" "$protocol"; then
          printf '[INFO] 已自动选择端口：%s\n' "$port" >&2
          printf '%s' "$port"
          return 0
        else
          availability_status=$?
          (( availability_status != 2 )) || die '无法可靠查询系统监听端口，已停止选择端口。'
        fi
      done
      die "在随机范围内没有找到可用端口。"
    fi
    if ! validate_port "$port"; then
      warn "端口必须是 1-65535 的整数；直接回车可随机选择。"
    elif port_available "$port" "$exclude_id" "$protocol"; then
      printf '%s' "$port"
      return 0
    else
      availability_status=$?
      (( availability_status != 2 )) || die '无法可靠查询系统监听端口，已停止选择端口。'
      if [[ "$protocol" == shadowsocks ]]; then
        warn "端口 $port 的 TCP 或 UDP 已被占用，或与已有节点冲突；不会覆盖。"
      elif [[ "$protocol" == hysteria2 || "$protocol" == tuic ]]; then
        warn "端口 $port 的 UDP 已被占用，或与已有节点冲突；不会覆盖。"
      else
        warn "端口 $port 的 TCP 已被占用，或与已有节点冲突；不会覆盖。"
      fi
    fi
  done
}

choose_method() {
  local choice
  while true; do
    printf '%s\n\n1. 2022-blake3-aes-128-gcm\n2. 2022-blake3-aes-256-gcm（默认）\n' '请选择加密方式：' >&2
    printf '> ' >&2
    IFS= read -r choice || die "读取输入失败。"
    [[ -z "$choice" ]] && choice=2
    case "$choice" in
      1) printf '2022-blake3-aes-128-gcm'; return 0 ;;
      2) printf '2022-blake3-aes-256-gcm'; return 0 ;;
      *) warn "请选择 1 或 2。" ;;
    esac
  done
}

choose_protocol() {
  local choice
  while true; do
    printf '%s\n\n1. Shadowsocks 2022\n2. VLESS + REALITY + Vision\n3. Hysteria2\n4. TUIC\n' '请选择协议：' >&2
    printf '> ' >&2
    IFS= read -r choice || die '读取输入失败。'
    [[ -z "$choice" ]] && choice=1
    case "$choice" in
      1) printf 'shadowsocks'; return 0 ;;
      2) printf 'vless'; return 0 ;;
      3) printf 'hysteria2'; return 0 ;;
      4) printf 'tuic'; return 0 ;;
      *) warn '请选择 1、2、3 或 4。' ;;
    esac
  done
}

choose_address() {
  local value detected
  while true; do
    printf '请输入节点地址（回车自动检测公网 IPv4，失败后尝试 IPv6；输入 ipv6 可自动检测公网 IPv6；也可直接输入 IP/域名）：\n> ' >&2
    IFS= read -r value || die "读取输入失败。"
    value=$(trim_spaces "$value")
    if [[ -z "$value" || "$value" == auto ]]; then
      detected=ipv4
      value=$(discover_public_ip ipv4 2>/dev/null || true)
      if [[ -z "$value" ]]; then
        detected=ipv6
        value=$(discover_public_ip ipv6 2>/dev/null || true)
      fi
      [[ -n "$value" ]] || { warn "没有检测到公网 IPv4/IPv6，请直接输入 IP 或域名。"; continue; }
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    if [[ "$value" == ipv4 ]]; then
      detected=ipv4
      value=$(discover_public_ip ipv4 2>/dev/null || true)
      [[ -n "$value" ]] || { warn "没有检测到公网 IPv4，请直接输入 IP 或域名。"; continue; }
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    if [[ "$value" == ipv6 || "$value" == auto6 ]]; then
      detected=ipv6
      value=$(discover_public_ip ipv6 2>/dev/null || true)
      if [[ -z "$value" ]]; then
        warn "没有检测到公网 IPv6；请直接输入 IPv6、IPv4 或域名。"
        continue
      fi
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    detected=$(validate_address "$value" 2>/dev/null || true)
    if [[ "$detected" == ipv4 || "$detected" == ipv6 || "$detected" == domain ]]; then
      printf '%s\t%s' "$value" "$detected"
      return 0
    fi
    warn "不是有效的 IPv4、IPv6 或域名。"
  done
}

choose_reality_server_name() {
  local value normalized
  while true; do
    printf '请输入 Reality Server Name / SNI：\n> ' >&2
    IFS= read -r value || die '读取输入失败。'
    value=$(trim_spaces "$value")
    normalized=$(normalize_domain_name "$value" 2>/dev/null || true)
    if [[ -n "$normalized" ]]; then
      [[ "$normalized" == "$value" ]] || info "SNI 已规范化为：$normalized" >&2
      printf '%s' "$normalized"
      return 0
    fi
    warn 'SNI 必须是有效域名；不接受 IP、端口、路径或控制字符。'
  done
}

choose_reality_handshake_target() {
  local value parsed server port display_server
  while true; do
    printf '请输入 Reality 握手目标（域名或域名:端口，省略端口默认 443；IPv6 使用 [地址]:端口）：\n> ' >&2
    IFS= read -r value || die '读取输入失败。'
    value=$(trim_spaces "$value")
    parsed=$(parse_reality_handshake_target "$value" 2>/dev/null || true)
    if [[ -n "$parsed" ]]; then
      server=${parsed%$'\t'*}
      port=${parsed##*$'\t'}
      display_server=$server
      [[ "$server" == *:* ]] && display_server="[$server]"
      info "Reality 握手目标：${display_server}:${port}" >&2
      printf '%s' "$parsed"
      return 0
    fi
    warn '握手目标格式无效；请输入 example.com、example.com:443 或 [IPv6]:443。'
  done
}

generate_vless_uuid() {
  local generated
  [[ -x "$SING_BOX_BINARY" ]] || return 1
  generated=$("$SING_BOX_BINARY" generate uuid 2>/dev/null | tr -d '\r\n') || return 1
  validate_uuid "$generated" || return 1
  printf '%s' "${generated,,}"
}

generate_reality_keypair() {
  local output private_key public_key
  [[ -x "$SING_BOX_BINARY" ]] || return 1
  output=$("$SING_BOX_BINARY" generate reality-keypair 2>/dev/null) || return 1
  private_key=$(awk -F: 'tolower($1) ~ /private/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$output") || return 1
  public_key=$(awk -F: 'tolower($1) ~ /public/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<<"$output") || return 1
  validate_reality_keypair "$private_key" "$public_key" || return 1
  printf '%s\t%s' "$private_key" "$public_key"
}

generate_reality_short_id() {
  local generated
  # Short IDs are raw random bytes represented as hexadecimal.  Generate them
  # with OpenSSL instead of depending on the positional-option parsing of
  # `sing-box generate rand`, which differs across supported sing-box builds.
  generated=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n') || return 1
  generated=${generated,,}
  validate_short_id "$generated" || return 1
  printf '%s' "$generated"
}

vless_uuid_in_database() {
  local value=$1 existing_values existing
  validate_uuid "$value" || return 2
  # UUID is a client authentication credential. Read existing values from the
  # protected database and compare inside Bash instead of placing the new UUID
  # in jq's externally observable argument vector.
  existing_values=$(jq -er '[.nodes[]? | select(.protocol == "vless" or .protocol == "tuic") | .uuid] | join("\n")' "$NODES_FILE") \
    || return 2
  while IFS= read -r existing; do
    [[ -n "$existing" ]] || continue
    validate_uuid "$existing" || return 2
    [[ "${existing,,}" == "${value,,}" ]] && return 0
  done <<<"$existing_values"
  return 1
}

tuic_password_in_database() {
  local value=$1 existing_values existing
  validate_tuic_password "$value" || return 2
  existing_values=$(jq -er '[.nodes[]? | select(.protocol == "tuic") | .password] | join("\n")' "$NODES_FILE") \
    || return 2
  while IFS= read -r existing; do
    [[ -n "$existing" ]] || continue
    validate_tuic_password "$existing" || return 2
    [[ "${existing,,}" == "${value,,}" ]] && return 0
  done <<<"$existing_values"
  return 1
}

vless_public_key_in_database() {
  local value=$1
  # A public key is client-visible, so it is safe to pass as a jq argument.
  # Matching it also rejects a repeated effective X25519 private scalar without
  # ever placing the server private key in another process's argv.
  jq -e --arg value "$value" '
    any(.nodes[]?;
      (.protocol // "shadowsocks") == "vless"
      and .reality_public_key == $value)
  ' "$NODES_FILE" >/dev/null
}

vless_short_id_in_database() {
  local value=$1 existing_values existing
  validate_short_id "$value" || return 2
  existing_values=$(jq -er '[.nodes[]? | select((.protocol // "shadowsocks") == "vless") | .reality_short_id] | join("\n")' "$NODES_FILE") \
    || return 2
  while IFS= read -r existing; do
    [[ -n "$existing" ]] || continue
    validate_short_id "$existing" || return 2
    [[ "${existing,,}" == "${value,,}" ]] && return 0
  done <<<"$existing_values"
  return 1
}

generate_unique_vless_uuid() {
  local generated status attempt
  for ((attempt=1; attempt<=64; attempt++)); do
    generated=$(generate_vless_uuid) || return 1
    status=0
    vless_uuid_in_database "$generated" || status=$?
    if (( status == 1 )); then
      printf '%s' "$generated" || return 1
      return 0
    fi
    (( status == 0 )) || return 1
  done
  return 1
}

generate_unique_tuic_uuid() {
  generate_unique_vless_uuid
}

generate_unique_tuic_password() {
  local generated status attempt
  for ((attempt=1; attempt<=64; attempt++)); do
    generated=$(generate_tuic_password) || return 1
    status=0
    tuic_password_in_database "$generated" || status=$?
    if (( status == 1 )); then
      printf '%s' "$generated" || return 1
      return 0
    fi
    (( status == 0 )) || return 1
  done
  return 1
}

generate_unique_reality_keypair() {
  local generated public_key status attempt
  for ((attempt=1; attempt<=64; attempt++)); do
    generated=$(generate_reality_keypair) || return 1
    public_key=${generated##*$'\t'}
    status=0
    vless_public_key_in_database "$public_key" || status=$?
    if (( status == 1 )); then
      printf '%s' "$generated" || return 1
      return 0
    fi
    (( status == 0 )) || return 1
  done
  return 1
}

generate_unique_reality_short_id() {
  local generated status attempt
  for ((attempt=1; attempt<=64; attempt++)); do
    generated=$(generate_reality_short_id) || return 1
    status=0
    vless_short_id_in_database "$generated" || status=$?
    if (( status == 1 )); then
      printf '%s' "$generated" || return 1
      return 0
    fi
    (( status == 0 )) || return 1
  done
  return 1
}

vless_generation_capabilities_available() {
  # Exercise the exact generators and validators used by create/rotate flows,
  # but keep every generated credential inside local shell variables.  This is
  # used only when existing VLESS nodes make these capabilities mandatory.
  local generated_uuid generated_keypair generated_private generated_public generated_short_id
  generated_uuid=$(generate_vless_uuid) || return 1
  generated_keypair=$(generate_reality_keypair) || return 1
  generated_private=${generated_keypair%$'\t'*}
  generated_public=${generated_keypair##*$'\t'}
  generated_short_id=$(generate_reality_short_id) || return 1
  validate_uuid "$generated_uuid" \
    && validate_reality_keypair "$generated_private" "$generated_public" \
    && validate_short_id "$generated_short_id"
}

tuic_generation_capabilities_available() {
  # Exercise the exact credential generators used by TUIC create/rotate flows.
  local generated_uuid generated_password
  generated_uuid=$(generate_vless_uuid) || return 1
  generated_password=$(generate_tuic_password) || return 1
  validate_uuid "$generated_uuid" && validate_tuic_password "$generated_password"
}

reality_handshake_reachable() {
  local server=$1 port=$2 server_name=$3
  # Bound DNS resolution as well as socket/TLS work.  Python's socket timeout
  # alone does not reliably limit a blocked system resolver.
  timeout 8 python3 - "$server" "$port" "$server_name" <<'PY'
import socket
import ssl
import sys

server, port, server_name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection((server, port), timeout=5) as connection:
        connection.settimeout(5)
        with context.wrap_socket(connection, server_hostname=server_name) as tls:
            if not tls.version():
                raise OSError("TLS handshake did not complete")
except (OSError, ssl.SSLError):
    raise SystemExit(1)
PY
}

generate_node_id() {
  local node_id exists_status
  while true; do
    node_id=$(openssl rand -hex 16) || return 1
    exists_status=0
    node_exists "$node_id" || exists_status=$?
    if (( exists_status == 1 )); then
      printf '%s' "$node_id"
      return 0
    fi
    (( exists_status == 0 )) || return 1
  done
}

node_new_record() {
  local name=$1 method=$2 port=$3 address=$4 address_type=$5 node_id=$6 password=$7
  local now reset_at next_reset
  now=$(timestamp_iso) || return 1
  reset_at=$(timestamp_iso) || return 1
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY") || return 1
  # Feed the key through stdin instead of exposing it in jq's argv.
  printf '%s' "$password" | jq -Rs \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg method "$method" \
    --arg address "$address" \
    --arg address_type "$address_type" \
    --arg now "$now" \
    --arg reset_at "$reset_at" \
    --arg next_reset "$next_reset" \
    --argjson port "$port" \
    --argjson quota "$DEFAULT_QUOTA_BYTES" \
    --argjson reset_day "$DEFAULT_RESET_DAY" \
    --argjson upload_limit "$DEFAULT_UPLOAD_LIMIT_MBPS" \
    --argjson download_limit "$DEFAULT_DOWNLOAD_LIMIT_MBPS" \
    '. as $password | {node_id:$node_id,name:$name,protocol:"shadowsocks",method:$method,password:$password,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}'
}

node_new_vless_record() {
  local name=$1 port=$2 address=$3 address_type=$4 node_id=$5 uuid=$6 private_key=$7 public_key=$8 short_id=$9
  local server_name=${10} handshake_server=${11} handshake_port=${12}
  local now reset_at next_reset
  now=$(timestamp_iso) || return 1
  reset_at=$(timestamp_iso) || return 1
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY") || return 1
  # Keep the server private key and client authentication identifiers out of
  # jq's argument vector. Their validated formats cannot contain newlines, so
  # one protected three-line stdin record can carry them without ambiguity.
  printf '%s\n%s\n%s' "$private_key" "$uuid" "$short_id" | jq -eRs \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg address "$address" \
    --arg address_type "$address_type" \
    --arg public_key "$public_key" \
    --arg server_name "$server_name" \
    --arg handshake_server "$handshake_server" \
    --arg now "$now" \
    --arg reset_at "$reset_at" \
    --arg next_reset "$next_reset" \
    --argjson port "$port" \
    --argjson handshake_port "$handshake_port" \
    --argjson quota "$DEFAULT_QUOTA_BYTES" \
    --argjson reset_day "$DEFAULT_RESET_DAY" \
    --argjson upload_limit "$DEFAULT_UPLOAD_LIMIT_MBPS" \
    --argjson download_limit "$DEFAULT_DOWNLOAD_LIMIT_MBPS" \
    'split("\n") as $credentials
      | if ($credentials | length) != 3 then error("invalid VLESS credential record") else
          {node_id:$node_id,name:$name,protocol:"vless",uuid:$credentials[1],flow:"xtls-rprx-vision",reality_private_key:$credentials[0],reality_public_key:$public_key,reality_short_id:$credentials[2],reality_server_name:$server_name,reality_handshake_server:$handshake_server,reality_handshake_port:$handshake_port,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}
        end'
}

node_new_hysteria2_record() {
  local name=$1 port=$2 address=$3 address_type=$4 node_id=$5 password=$6 server_name=$7 pin=$8
  local now reset_at next_reset
  now=$(timestamp_iso) || return 1
  reset_at=$(timestamp_iso) || return 1
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY") || return 1
  printf '%s' "$password" | jq -eRs \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg address "$address" \
    --arg address_type "$address_type" \
    --arg server_name "$server_name" \
    --arg pin "$pin" \
    --arg now "$now" \
    --arg reset_at "$reset_at" \
    --arg next_reset "$next_reset" \
    --argjson port "$port" \
    --argjson quota "$DEFAULT_QUOTA_BYTES" \
    --argjson reset_day "$DEFAULT_RESET_DAY" \
    --argjson upload_limit "$DEFAULT_UPLOAD_LIMIT_MBPS" \
    --argjson download_limit "$DEFAULT_DOWNLOAD_LIMIT_MBPS" \
    '. as $password | {node_id:$node_id,name:$name,protocol:"hysteria2",password:$password,tls_server_name:$server_name,certificate_sha256:$pin,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}'
}

node_new_tuic_record() {
  local name=$1 port=$2 address=$3 address_type=$4 node_id=$5 uuid=$6 password=$7 server_name=$8 pin=$9
  local now reset_at next_reset
  now=$(timestamp_iso) || return 1
  reset_at=$(timestamp_iso) || return 1
  next_reset=$(calculate_next_reset_at "$reset_at" "$DEFAULT_RESET_DAY") || return 1
  # Keep both client authentication values out of jq's argument vector.
  printf '%s\n%s' "$uuid" "$password" | jq -eRs \
    --arg node_id "$node_id" \
    --arg name "$name" \
    --arg address "$address" \
    --arg address_type "$address_type" \
    --arg server_name "$server_name" \
    --arg pin "$pin" \
    --arg now "$now" \
    --arg reset_at "$reset_at" \
    --arg next_reset "$next_reset" \
    --argjson port "$port" \
    --argjson quota "$DEFAULT_QUOTA_BYTES" \
    --argjson reset_day "$DEFAULT_RESET_DAY" \
    --argjson upload_limit "$DEFAULT_UPLOAD_LIMIT_MBPS" \
    --argjson download_limit "$DEFAULT_DOWNLOAD_LIMIT_MBPS" \
    'split("\n") as $credentials
      | if ($credentials | length) != 2 then error("invalid TUIC credential record") else
          {node_id:$node_id,name:$name,protocol:"tuic",uuid:$credentials[0],password:$credentials[1],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls_server_name:$server_name,certificate_sha256:$pin,port:$port,address:$address,address_type:$address_type,status:"enabled",status_reason:"",quota_bytes:$quota,reset_day:$reset_day,upload_limit_mbps:$upload_limit,download_limit_mbps:$download_limit,created_at:$now,updated_at:$now,last_reset_at:$reset_at,next_reset_at:$next_reset}
        end'
}

node_add_flow() {
  acquire_manager_lock
  local requested name protocol method port address_line address address_type node_id password record_file candidate traffic_candidate candidate_history
  local server_name handshake_line handshake_server handshake_port uuid keypair private_key public_key short_id
  local certificate_pin candidate_certs
  requested=$(read_nonempty '请输入节点名称：')
  validate_name "$requested" || die "节点名称包含控制字符、路径字符或超过 64 个字符。"
  name=$(unique_node_name "$requested") || die "无法生成唯一节点名称。"
  [[ "$name" == "$requested" ]] || info "名称已存在，自动使用：$name"
  protocol=$(choose_protocol)
  if [[ "$protocol" == shadowsocks ]]; then
    method=$(choose_method)
  fi
  port=$(choose_port '' "$protocol")
  address_line=$(choose_address)
  address=${address_line%$'\t'*}
  address_type=${address_line##*$'\t'}
  node_id=$(generate_node_id)
  record_file=$(runtime_temp_file node-record) || die '无法创建节点记录暂存文件。'
  if [[ "$protocol" == shadowsocks ]]; then
    password=$(generate_random_key "$(method_key_bytes "$method")")
    node_new_record "$name" "$method" "$port" "$address" "$address_type" "$node_id" "$password" >"$record_file" \
      || { rm -f -- "$record_file"; die '无法创建 Shadowsocks 节点记录。'; }
  elif [[ "$protocol" == vless ]]; then
    server_name=$(choose_reality_server_name)
    handshake_line=$(choose_reality_handshake_target)
    handshake_server=${handshake_line%$'\t'*}
    handshake_port=${handshake_line##*$'\t'}
    reality_handshake_reachable "$handshake_server" "$handshake_port" "$server_name" \
      || warn 'Reality 握手目标当前无法完成 TCP/TLS 探测；将继续依靠 sing-box 配置检查，创建后还需进行客户端握手测试。'
    uuid=$(generate_unique_vless_uuid) || { rm -f -- "$record_file"; die 'sing-box 无法生成未被其他节点使用的有效 VLESS UUID。'; }
    keypair=$(generate_unique_reality_keypair) || { rm -f -- "$record_file"; die 'sing-box 无法生成未被其他节点使用的有效 Reality KeyPair。'; }
    private_key=${keypair%$'\t'*}
    public_key=${keypair##*$'\t'}
    short_id=$(generate_unique_reality_short_id) || { rm -f -- "$record_file"; die '无法安全生成未被其他节点使用的有效 Reality Short ID。'; }
    node_new_vless_record "$name" "$port" "$address" "$address_type" "$node_id" "$uuid" "$private_key" "$public_key" "$short_id" "$server_name" "$handshake_server" "$handshake_port" >"$record_file" \
      || { rm -f -- "$record_file"; die '无法创建 VLESS 节点记录。'; }
  elif [[ "$protocol" == hysteria2 ]]; then
    server_name=$(tls_server_name_for_node hysteria2 "$node_id") \
      || { rm -f -- "$record_file"; die '无法生成 Hysteria2 TLS Server Name。'; }
    info "Hysteria2 TLS Server Name：$server_name"
    candidate_certs=$(tls_make_candidate_cert_root) || { rm -f -- "$record_file"; die '无法创建 Hysteria2 证书候选目录。'; }
    password=$(generate_hysteria2_password) || { rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法生成 Hysteria2 密码。'; }
    certificate_pin=$(tls_generate_certificate "$candidate_certs" "$node_id" "$server_name") || {
      rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法生成 Hysteria2 自签名证书。';
    }
    node_new_hysteria2_record "$name" "$port" "$address" "$address_type" "$node_id" "$password" "$server_name" "$certificate_pin" >"$record_file" \
      || { rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法创建 Hysteria2 节点记录。'; }
  else
    server_name=$(tls_server_name_for_node tuic "$node_id") \
      || { rm -f -- "$record_file"; die '无法生成 TUIC TLS Server Name。'; }
    info "TUIC TLS Server Name：$server_name"
    candidate_certs=$(tls_make_candidate_cert_root) || { rm -f -- "$record_file"; die '无法创建 TUIC 证书候选目录。'; }
    uuid=$(generate_unique_tuic_uuid) || { rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die 'sing-box 无法生成未被其他节点使用的有效 TUIC UUID。'; }
    password=$(generate_unique_tuic_password) || { rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法生成未被其他节点使用的 TUIC 密码。'; }
    certificate_pin=$(tls_generate_certificate "$candidate_certs" "$node_id" "$server_name") || {
      rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法生成 TUIC 自签名证书。';
    }
    node_new_tuic_record "$name" "$port" "$address" "$address_type" "$node_id" "$uuid" "$password" "$server_name" "$certificate_pin" >"$record_file" \
      || { rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法创建 TUIC 节点记录。'; }
  fi
  chmod 600 -- "$record_file" || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法保护节点记录暂存文件。'; }
  candidate=$(runtime_temp_file nodes.candidate) || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$record_file"; die '无法创建节点候选暂存文件。'; }
  jq --slurpfile record "$record_file" '.nodes += [$record[0]]' "$NODES_FILE" >"$candidate" \
    || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$record_file" "$candidate"; die '无法生成节点候选数据库。'; }
  rm -f -- "$record_file" || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$candidate"; die '无法清理节点密钥暂存文件。'; }
  traffic_candidate=$(runtime_temp_file traffic.add) || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$candidate"; die '无法创建流量候选暂存文件。'; }
  candidate_history=$(runtime_temp_file history.add) || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$candidate" "$traffic_candidate"; die '无法创建历史候选暂存文件。'; }
  traffic_candidate_add_node "$node_id" "$DEFAULT_QUOTA_BYTES" "$DEFAULT_RESET_DAY" >"$traffic_candidate" \
    || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"; die '无法生成新节点流量状态。'; }
  install -m 600 -- "$HISTORY_FILE" "$candidate_history" \
    || { [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"; rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"; die '无法复制流量历史候选状态。'; }
  apply_state_transaction "$candidate" "$traffic_candidate" "$candidate_history" "add-node-$node_id" 1 "${candidate_certs:-}" || {
    [[ -z "${candidate_certs:-}" ]] || rm -rf -- "$candidate_certs"
    rm -f -- "$candidate" "$traffic_candidate" "$candidate_history"
    die "添加节点失败，当前运行配置和节点数据库已保持不变。"
  }
  rm -f -- "$candidate" "$traffic_candidate" "$candidate_history" \
    || warn '节点已经创建，但运行时候选文件清理失败。'
  [[ -z "${candidate_certs:-}" ]] || {
    [[ ! -e "$candidate_certs" ]] || warn 'TLS 证书候选目录已经发布，但暂存目录清理失败。'
  }
  success "节点创建成功。"
  show_node_credentials "$node_id" || warn '节点已经创建，但凭据展示未完整完成；可稍后从菜单重新显示。'
}

node_list_compact() {
  local index=1 node node_id name protocol protocol_text port status current_u current_d total node_lines
  local quota quota_text upload_text download_text total_text status_text
  printf '\n%-4s %-18s %-7s %-7s %-11s %-11s %-11s %-11s %-10s\n' '序号' '名称' '协议' '端口' '上传' '下载' '合计' '限额' '状态'
  printf '%s\n' '------------------------------------------------------------------------------------------------'
  node_lines=$(jq -c '.nodes[]' "$NODES_FILE") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    name=$(jq -er '.name' <<<"$node") || return 1
    protocol=$(node_protocol "$node") || return 1
    protocol_text=$(protocol_label "$protocol") || return 1
    port=$(jq -er '.port' <<<"$node") || return 1
    status=$(jq -er '.status' <<<"$node") || return 1
    current_u=$(traffic_value "$node_id" '.current_upload_bytes') || return 1
    current_d=$(traffic_value "$node_id" '.current_download_bytes') || return 1
    total=$((current_u + current_d))
    quota=$(jq -er '.quota_bytes' <<<"$node") || return 1
    quota_text='无限'
    if (( quota > 0 )); then
      quota_text=$(format_bytes "$quota") || return 1
    fi
    upload_text=$(format_bytes "$current_u") || return 1
    download_text=$(format_bytes "$current_d") || return 1
    total_text=$(format_bytes "$total") || return 1
    status_text=$(status_label "$status") || return 1
    printf '%-4s %-18s %-7s %-7s %-11s %-11s %-11s %-11s %-10s\n' "$index" "$name" "$protocol_text" "$port" "$upload_text" "$download_text" "$total_text" "$quota_text" "$status_text"
    ((index++))
  done <<<"$node_lines"
  (( index > 1 )) || info '当前没有节点。'
}

select_node_id() {
  local prompt=${1:-'请选择节点序号'}
  # This function is normally called through command substitution; the list
  # and prompt are UI output, not the selected Node ID.
  node_list_compact >&2 || return 2
  local count index
  count=$(node_count) || return 2
  (( count > 0 )) || return 1
  while true; do
    printf '%s（0 返回）\n> ' "$prompt" >&2
    IFS= read -r index || return 2
    [[ "$index" == 0 ]] && return 1
    if [[ "$index" =~ ^[1-9][0-9]*$ ]] && (( index >= 1 && index <= count )); then
      jq -er --argjson index "$index" '.nodes[$index-1].node_id' "$NODES_FILE" || return 2
      return 0
    fi
    warn "请输入有效的节点序号。"
  done
}

select_node_for_flow() {
  local output_variable=$1 prompt=$2 selected='' select_status=0
  selected=$(select_node_id "$prompt") || select_status=$?
  if (( select_status == 0 )); then
    printf -v "$output_variable" '%s' "$selected"
    return 0
  fi
  (( select_status == 1 )) && return 1
  die '无法可靠读取或显示节点数据库，操作已停止。'
}

node_show_detail() {
  local node_id=$1 node
  node=$(node_by_id "$node_id") || die "节点不存在：$node_id"
  local upload download total total_upload total_download total_all quota reset_day status billable quota_policy
  local name address port protocol protocol_text upload_limit download_limit next_reset status_text
  local upload_text download_text total_text total_upload_text total_download_text total_all_text
  local cert_path cert_dates cert_start cert_end
  upload=$(traffic_value "$node_id" '.current_upload_bytes') || die '无法读取节点上传流量。'
  download=$(traffic_value "$node_id" '.current_download_bytes') || die '无法读取节点下载流量。'
  total=$((upload + download))
  billable=$(quota_billable_bytes "$upload" "$download") || die '配额计数超出安全整数范围。'
  quota_policy=$(quota_policy_description) || die '无法读取全局配额策略。'
  total_upload=$(traffic_value "$node_id" '.total_upload_bytes') || die '无法读取节点累计上传流量。'
  total_download=$(traffic_value "$node_id" '.total_download_bytes') || die '无法读取节点累计下载流量。'
  total_all=$((total_upload + total_download))
  quota=$(jq -er '.quota_bytes' <<<"$node") || die '节点限额字段无效。'
  reset_day=$(jq -er '.reset_day' <<<"$node") || die '节点重置日字段无效。'
  status=$(jq -er '.status' <<<"$node") || die '节点状态字段无效。'
  name=$(jq -er '.name' <<<"$node") || die '节点名称字段无效。'
  address=$(jq -er '.address' <<<"$node") || die '节点地址字段无效。'
  port=$(jq -er '.port' <<<"$node") || die '节点端口字段无效。'
  protocol=$(node_protocol "$node") || die '节点协议字段无效。'
  protocol_text=$(protocol_label "$protocol") || die '无法格式化节点协议。'
  upload_limit=$(jq -er '.upload_limit_mbps' <<<"$node") || die '节点上传限速字段无效。'
  download_limit=$(jq -er '.download_limit_mbps' <<<"$node") || die '节点下载限速字段无效。'
  next_reset=$(jq -er '.next_reset_at' <<<"$node") || die '节点下次重置时间无效。'
  status_text=$(status_label "$status") || die '无法格式化节点状态。'
  upload_text=$(format_bytes "$upload") || die '无法格式化上传流量。'
  download_text=$(format_bytes "$download") || die '无法格式化下载流量。'
  total_text=$(format_bytes "$total") || die '无法格式化本周期流量。'
  total_upload_text=$(format_bytes "$total_upload") || die '无法格式化累计上传流量。'
  total_download_text=$(format_bytes "$total_download") || die '无法格式化累计下载流量。'
  total_all_text=$(format_bytes "$total_all") || die '无法格式化累计流量。'
  printf '\n节点：%s\nNode ID：%s\n协议：%s\n服务器地址：%s\n' "$name" "$node_id" "$protocol_text" "$address"
  if [[ "$protocol" == shadowsocks ]]; then
    printf '端口：%s（TCP + UDP）\n加密方式：%s\n' "$port" "$(jq -er '.method' <<<"$node")"
  elif [[ "$protocol" == vless ]]; then
    local handshake_server handshake_port handshake_display
    handshake_server=$(jq -er '.reality_handshake_server' <<<"$node") || die 'Reality 握手服务器字段无效。'
    handshake_port=$(jq -er '.reality_handshake_port' <<<"$node") || die 'Reality 握手端口字段无效。'
    handshake_display=$handshake_server
    [[ "$handshake_server" == *:* ]] && handshake_display="[$handshake_server]"
    printf '端口：%s（TCP）\n模式：REALITY + Vision\nUUID：%s\nFlow：%s\nReality SNI：%s\nReality 握手目标：%s:%s\nReality Public Key：%s\nShort ID：%s\n' \
      "$port" \
      "$(jq -er '.uuid' <<<"$node")" \
      "$(jq -er '.flow' <<<"$node")" \
      "$(jq -er '.reality_server_name' <<<"$node")" \
      "$handshake_display" "$handshake_port" \
      "$(jq -er '.reality_public_key' <<<"$node")" \
      "$(jq -er '.reality_short_id' <<<"$node")"
  elif [[ "$protocol" == hysteria2 ]]; then
    cert_path=$(tls_cert_path "$CERTS_DIR" "$node_id") || die '无法推导 Hysteria2 证书路径。'
    tls_validate_certificate_files "$CERTS_DIR" "$node_id" \
      "$(jq -er '.tls_server_name' <<<"$node")" "$(jq -er '.certificate_sha256' <<<"$node")" \
      || die 'Hysteria2 证书、私钥或 Pin 校验失败；请先使用备份恢复。'
    cert_dates=$(openssl x509 -in "$cert_path" -noout -startdate -enddate 2>/dev/null) \
      || die '无法读取 Hysteria2 证书有效期。'
    cert_start=${cert_dates#*notBefore=}
    cert_start=${cert_start%%$'\n'*}
    cert_end=${cert_dates#*notAfter=}
    cert_end=${cert_end%%$'\n'*}
    printf '端口：%s（UDP）\n模式：TLS + Hysteria2\n密码：%s\nTLS SNI：%s\n证书 Pin（SHA-256）：%s\n证书有效期：%s 至 %s\n' \
      "$port" \
      "$(jq -er '.password' <<<"$node")" \
      "$(jq -er '.tls_server_name' <<<"$node")" \
      "$(jq -er '.certificate_sha256' <<<"$node")" "$cert_start" "$cert_end"
    if ! openssl x509 -in "$cert_path" -checkend $((30 * 86400)) -noout >/dev/null 2>&1; then
      warn 'Hysteria2 证书将在 30 天内到期；项目不会自动轮换，请手动确认是否重新生成。'
    fi
  else
    cert_path=$(tls_cert_path "$CERTS_DIR" "$node_id") || die '无法推导 TUIC 证书路径。'
    tls_validate_certificate_files "$CERTS_DIR" "$node_id" \
      "$(jq -er '.tls_server_name' <<<"$node")" "$(jq -er '.certificate_sha256' <<<"$node")" \
      || die 'TUIC 证书、私钥或 Pin 校验失败；请先使用备份恢复。'
    cert_dates=$(openssl x509 -in "$cert_path" -noout -startdate -enddate 2>/dev/null) \
      || die '无法读取 TUIC 证书有效期。'
    cert_start=${cert_dates#*notBefore=}
    cert_start=${cert_start%%$'\n'*}
    cert_end=${cert_dates#*notAfter=}
    cert_end=${cert_end%%$'\n'*}
    printf '端口：%s（UDP / QUIC）\n模式：TUIC v5\nTLS：Self-Signed\nUUID：%s\n密码：%s\nTLS SNI：%s\n证书 Pin（叶证书 DER SHA-256）：%s\n证书有效期：%s 至 %s\nQUIC 拥塞控制：%s\n认证超时：%s\n心跳：%s\n0-RTT：%s\n' \
      "$port" \
      "$(jq -er '.uuid' <<<"$node")" \
      "$(jq -er '.password' <<<"$node")" \
      "$(jq -er '.tls_server_name' <<<"$node")" \
      "$(jq -er '.certificate_sha256' <<<"$node")" "$cert_start" "$cert_end" \
      "$(jq -er '.congestion_control' <<<"$node")" \
      "$(jq -er '.auth_timeout' <<<"$node")" \
      "$(jq -er '.heartbeat' <<<"$node")" \
      "$(jq -er 'if .zero_rtt_handshake then "开启" else "关闭" end' <<<"$node")"
    if ! openssl x509 -in "$cert_path" -checkend $((30 * 86400)) -noout >/dev/null 2>&1; then
      warn 'TUIC 证书将在 30 天内到期；项目不会自动轮换，请手动确认是否重新生成。'
    fi
  fi
  printf '状态：%s\n' "$status_text"
  printf '本周期上传：%s\n本周期下载：%s\n本周期合计：%s\n' "$upload_text" "$download_text" "$total_text"
  if (( quota == 0 )); then
    printf '月流量限额：无限\n自动停用策略：%s（端口层观测值，不是认证账单）\n' "$quota_policy"
  else
    printf '月流量限额：%s\n计费流量：%s（%s；不能视为认证账单）\n剩余：%s\n' \
      "$(format_bytes "$quota")" "$(format_bytes "$billable")" "$quota_policy" \
      "$(format_bytes "$(( quota > billable ? quota - billable : 0 ))")"
  fi
  printf '累计上传：%s\n累计下载：%s\n累计合计：%s\n' "$total_upload_text" "$total_download_text" "$total_all_text"
  printf '重置日：每月 %s 日\n上传限速：%s\n下载限速：%s\n下次重置：%s\n' "$reset_day" "$(format_mbps "$upload_limit")" "$(format_mbps "$download_limit")" "$next_reset"
}

node_view_flow() {
  local node_id
  select_node_for_flow node_id '请选择要查看的节点' || return 0
  node_show_detail "$node_id"
  if prompt_yes_no '是否显示该节点的客户端凭据、链接和二维码？' n; then
    show_node_credentials "$node_id"
  fi
}
