#!/usr/bin/env bash
# Explicit credential display: canonical SS2022/VLESS URI, Base64 form and terminal QR.

base64_no_wrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\r\n'
  fi
}

node_uri_host() {
  local address=$1 address_type=$2
  case "$address_type" in
    ipv6) printf '[%s]' "$address" ;;
    ipv4|domain) printf '%s' "$address" ;;
    *) error "节点地址类型无效：$address_type"; return 1 ;;
  esac
}

node_sip002_uri() {
  local node=$1
  local method password address address_type port name encoded_method encoded_password encoded_name host
  method=$(jq -er '.method' <<<"$node") || return 1
  password=$(jq -er '.password' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  # SIP002 requires AEAD-2022 userinfo to remain plain and percent-encoded.
  # Base64URL userinfo is explicitly forbidden for SIP002 AEAD-2022 methods.
  encoded_method=$(url_encode "$method") || return 1
  encoded_password=$(url_encode "$password") || return 1
  encoded_name=$(url_encode "$name") || return 1
  host=$(node_uri_host "$address" "$address_type") || return 1
  printf 'ss://%s:%s@%s:%s#%s' "$encoded_method" "$encoded_password" "$host" "$port" "$encoded_name"
}

node_vless_uri() {
  local node=$1 uuid address address_type port name sni public_key short_id host encoded_name
  local encoded_sni encoded_public_key encoded_short_id
  [[ "$(node_protocol "$node")" == vless ]] || return 1
  uuid=$(jq -er '.uuid' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  sni=$(jq -er '.reality_server_name' <<<"$node") || return 1
  public_key=$(jq -er '.reality_public_key' <<<"$node") || return 1
  short_id=$(jq -er '.reality_short_id' <<<"$node") || return 1
  validate_uuid "$uuid" || return 1
  validate_domain_name "$sni" || return 1
  validate_reality_key "$public_key" || return 1
  validate_short_id "$short_id" || return 1
  host=$(node_uri_host "$address" "$address_type") || return 1
  encoded_name=$(url_encode "$name") || return 1
  encoded_sni=$(url_encode "$sni") || return 1
  encoded_public_key=$(url_encode "$public_key") || return 1
  encoded_short_id=$(url_encode "$short_id") || return 1
  printf 'vless://%s@%s:%s?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&sni=%s&fp=chrome&pbk=%s&sid=%s#%s' \
    "$uuid" "$host" "$port" "$encoded_sni" "$encoded_public_key" "$encoded_short_id" "$encoded_name"
}

node_hysteria2_uri() {
  local node=$1 node_id password address address_type port name sni pin host encoded_password encoded_sni encoded_pin encoded_name
  [[ "$(node_protocol "$node")" == hysteria2 ]] || return 1
  password=$(jq -er '.password' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  sni=$(jq -er '.tls_server_name' <<<"$node") || return 1
  pin=$(jq -er '.certificate_sha256' <<<"$node") || return 1
  node_id=$(jq -er '.node_id' <<<"$node") || return 1
  validate_hysteria_password "$password" || return 1
  validate_domain_name "$sni" || return 1
  validate_certificate_sha256 "$pin" || return 1
  hysteria2_validate_certificate_files "$CERTS_DIR" "$node_id" "$sni" "$pin" || return 1
  host=$(node_uri_host "$address" "$address_type") || return 1
  encoded_password=$(url_encode "$password") || return 1
  encoded_sni=$(url_encode "$sni") || return 1
  encoded_pin=$(url_encode "$pin") || return 1
  encoded_name=$(url_encode "$name") || return 1
  printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s#%s' \
    "$encoded_password" "$host" "$port" "$encoded_sni" "$encoded_pin" "$encoded_name"
}

node_tuic_uri() {
  local node=$1 node_id uuid password address address_type port name sni pin congestion host
  local encoded_uuid encoded_password encoded_sni encoded_congestion encoded_name
  [[ "$(node_protocol "$node")" == tuic ]] || return 1
  node_id=$(jq -er '.node_id' <<<"$node") || return 1
  uuid=$(jq -er '.uuid' <<<"$node") || return 1
  password=$(jq -er '.password' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  sni=$(jq -er '.tls_server_name' <<<"$node") || return 1
  pin=$(jq -er '.certificate_sha256' <<<"$node") || return 1
  congestion=$(jq -er '.congestion_control' <<<"$node") || return 1
  validate_uuid "$uuid" || return 1
  validate_tuic_password "$password" || return 1
  validate_domain_name "$sni" || return 1
  validate_certificate_sha256 "$pin" || return 1
  [[ "$congestion" == bbr ]] || return 1
  tls_validate_certificate_files "$CERTS_DIR" "$node_id" "$sni" "$pin" || return 1
  host=$(node_uri_host "$address" "$address_type") || return 1
  encoded_uuid=$(url_encode "$uuid") || return 1
  encoded_password=$(url_encode "$password") || return 1
  encoded_sni=$(url_encode "$sni") || return 1
  encoded_congestion=$(url_encode "$congestion") || return 1
  encoded_name=$(url_encode "$name") || return 1
  # The interoperable TUIC v5 URI convention has no portable certificate-pin
  # query key. Keep the verified leaf digest as a separately displayed value
  # instead of inventing a parameter that clients may silently ignore.
  printf 'tuic://%s:%s@%s:%s?congestion_control=%s&alpn=h3&sni=%s&allow_insecure=1&udp_relay_mode=native#%s' \
    "$encoded_uuid" "$encoded_password" "$host" "$port" "$encoded_congestion" "$encoded_sni" "$encoded_name"
}

node_share_uri() {
  local node=$1 protocol
  protocol=$(node_protocol "$node") || return 1
  case "$protocol" in
    shadowsocks) node_sip002_uri "$node" ;;
    vless) node_vless_uri "$node" ;;
    hysteria2) node_hysteria2_uri "$node" ;;
    tuic) node_tuic_uri "$node" ;;
    *) return 1 ;;
  esac
}

node_base64_uri() {
  local node=$1
  local uri
  uri=$(node_share_uri "$node") || return 1
  base64_no_wrap "$uri" || return 1
}

show_node_credentials() {
  local node_id=$1 node uri base64_uri node_status runtime_status active_status=0
  local name address port protocol protocol_text
  node=$(node_by_id "$node_id") || { error "节点不存在或节点数据库读取失败：$node_id"; return 1; }
  uri=$(node_share_uri "$node") || { error '无法生成节点标准分享 URI。'; return 1; }
  base64_uri=$(base64_no_wrap "$uri") || { error '无法生成节点 Base64 信息。'; return 1; }
  node_status=$(jq -er '.status' <<<"$node") || return 1
  runtime_status=$(status_label "$node_status") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  protocol=$(node_protocol "$node") || return 1
  protocol_text=$(protocol_label "$protocol") || return 1
  if [[ "$node_status" == enabled ]]; then
    singbox_is_active || active_status=$?
    if (( active_status == 1 )); then
      runtime_status='节点已启用 / sing-box 已停止'
    elif (( active_status == 2 )); then
      runtime_status='节点已启用 / sing-box 状态查询失败'
    fi
  fi
  printf '\n================================\n节点创建成功 / 节点凭据\n================================\n'
  printf '节点名称：%s\n' "$name"
  printf 'Node ID：%s\n' "$node_id"
  printf '协议：%s\n' "$protocol_text"
  printf '服务器地址：%s\n' "$address"
  if [[ "$protocol" == shadowsocks ]]; then
    printf '端口：%s（TCP + UDP）\n' "$port"
    printf '加密方式：%s\n' "$(jq -er '.method' <<<"$node")"
    printf '密钥：%s\n' "$(jq -er '.password' <<<"$node")"
    printf 'TCP 状态：%s\nUDP 状态：%s\n' "$runtime_status" "$runtime_status"
    printf '\n[Shadowsocks URI / SIP002]\n%s\n' "$uri"
  elif [[ "$protocol" == vless ]]; then
    printf '端口：%s（TCP）\n' "$port"
    printf '模式：REALITY + Vision\n'
    printf 'UUID：%s\n' "$(jq -er '.uuid' <<<"$node")"
    printf 'Flow：%s\n' "$(jq -er '.flow' <<<"$node")"
    printf 'SNI：%s\n' "$(jq -er '.reality_server_name' <<<"$node")"
    printf 'Reality Public Key：%s\n' "$(jq -er '.reality_public_key' <<<"$node")"
    printf 'Short ID：%s\n' "$(jq -er '.reality_short_id' <<<"$node")"
    printf 'TCP 状态：%s\n' "$runtime_status"
    printf '\n[VLESS URI]\n%s\n' "$uri"
  elif [[ "$protocol" == hysteria2 ]]; then
    printf '端口：%s（UDP）\n模式：TLS + Hysteria2\n密码：%s\nSNI：%s\n证书 Pin（SHA-256）：%s\n' \
      "$port" "$(jq -er '.password' <<<"$node")" \
      "$(jq -er '.tls_server_name' <<<"$node")" \
      "$(jq -er '.certificate_sha256' <<<"$node")"
    printf 'UDP 状态：%s\n' "$runtime_status"
    printf '\n[Hysteria2 URI]\n%s\n' "$uri"
  else
    printf '端口：%s（UDP / QUIC）\n模式：TUIC v5\nTLS：Self-Signed\nUUID：%s\nPassword：%s\nSNI：%s\n证书 Pin（叶证书 DER SHA-256）：%s\nQUIC 拥塞控制：%s\n0-RTT：关闭\n' \
      "$port" "$(jq -er '.uuid' <<<"$node")" "$(jq -er '.password' <<<"$node")" \
      "$(jq -er '.tls_server_name' <<<"$node")" "$(jq -er '.certificate_sha256' <<<"$node")" \
      "$(jq -er '.congestion_control' <<<"$node")"
    printf 'UDP 状态：%s\n' "$runtime_status"
    printf '\n[TUIC v5 URI]\n%s\n' "$uri"
    printf '说明：通用 TUIC URI 没有可移植的证书 Pin 参数；上方 Pin 供支持证书固定的客户端手动核对。\n'
  fi
  printf '\n[Base64 节点信息（上方标准 URI 的 Base64）]\n%s\n' "$base64_uri"
  printf '\n[二维码]\n'
  if command -v qrencode >/dev/null 2>&1; then
    # qrencode reads stdin when STRING is omitted; do not expose credentials
    # through its command-line arguments.
    printf '%s' "$uri" | qrencode -t UTF8 -m 1 || warn '二维码生成失败；上方 URI 仍可复制。'
  else
    warn '系统没有 qrencode，无法在终端显示二维码；URI 仍可复制。'
  fi
  if [[ "$protocol" == shadowsocks ]]; then
    printf '\n请检查服务器防火墙、安全组或云厂商防火墙是否放行 TCP/UDP 端口。\n'
  else
    [[ "$protocol" == hysteria2 || "$protocol" == tuic ]] && printf '\n请检查服务器防火墙、安全组或云厂商防火墙是否放行 UDP 端口。\n' \
      || printf '\n请检查服务器防火墙、安全组或云厂商防火墙是否放行 TCP 端口。\n'
  fi
  printf '\n请妥善保管以上客户端凭据、链接和二维码，不要提交到 GitHub 或普通日志。\n'
}

show_node_link_flow() {
  local node_id
  select_node_for_flow node_id '请选择要显示链接/二维码的节点' || return 0
  show_node_credentials "$node_id"
}
