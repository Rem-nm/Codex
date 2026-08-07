#!/usr/bin/env bash
# Explicit credential display: canonical SIP002 URI, its Base64 form and terminal QR.

base64_no_wrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\r\n'
  fi
}

node_uri_host() {
  local address=$1 address_type=$2
  if [[ "$address_type" == ipv6 ]]; then
    printf '[%s]' "$address"
  else
    printf '%s' "$address"
  fi
}

node_sip002_uri() {
  local node=$1
  local method password address address_type port name encoded_method encoded_password encoded_name host
  method=$(jq -er '.method' <<<"$node")
  password=$(jq -er '.password' <<<"$node")
  address=$(jq -er '.address' <<<"$node")
  address_type=$(jq -er '.address_type' <<<"$node")
  port=$(jq -er '.port' <<<"$node")
  name=$(jq -er '.name' <<<"$node")
  # SIP002 requires AEAD-2022 userinfo to remain plain and percent-encoded.
  # Base64URL userinfo is explicitly forbidden for SIP002 AEAD-2022 methods.
  encoded_method=$(url_encode "$method")
  encoded_password=$(url_encode "$password")
  encoded_name=$(url_encode "$name")
  host=$(node_uri_host "$address" "$address_type")
  printf 'ss://%s:%s@%s:%s#%s' "$encoded_method" "$encoded_password" "$host" "$port" "$encoded_name"
}

node_base64_uri() {
  local node=$1
  local uri
  uri=$(node_sip002_uri "$node")
  base64_no_wrap "$uri"
}

show_node_credentials() {
  local node_id=$1 node uri base64_uri node_status runtime_status
  node=$(node_by_id "$node_id") || die "节点不存在：$node_id"
  uri=$(node_sip002_uri "$node")
  base64_uri=$(node_base64_uri "$node")
  node_status=$(jq -er '.status' <<<"$node")
  runtime_status=$(status_label "$node_status")
  if [[ "$node_status" == enabled ]] && ! singbox_is_active; then
    runtime_status='节点已启用 / sing-box 已停止'
  fi
  printf '\n================================\n节点创建成功 / 节点凭据\n================================\n'
  printf '节点名称：%s\n' "$(jq -er '.name' <<<"$node")"
  printf 'Node ID：%s\n' "$node_id"
  printf '服务器地址：%s\n' "$(jq -er '.address' <<<"$node")"
  printf '端口：%s（TCP + UDP）\n' "$(jq -er '.port' <<<"$node")"
  printf '加密方式：%s\n' "$(jq -er '.method' <<<"$node")"
  printf '密钥：%s\n' "$(jq -er '.password' <<<"$node")"
  printf 'TCP 状态：%s\nUDP 状态：%s\n' "$runtime_status" "$runtime_status"
  printf '\n[Shadowsocks URI / SIP002]\n%s\n' "$uri"
  printf '\n[Base64 节点信息（上方 SIP002 URI 的 Base64）]\n%s\n' "$base64_uri"
  printf '\n[二维码]\n'
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t UTF8 -m 1 -- "$uri"
  else
    warn '系统没有 qrencode，无法在终端显示二维码；URI 仍可复制。'
  fi
  printf '\n请检查服务器防火墙、安全组或云厂商防火墙是否放行 TCP/UDP 端口。\n'
  printf '\n请妥善保管以上密钥、链接和二维码，不要提交到 GitHub 或普通日志。\n'
}

show_node_link_flow() {
  local node_id
  node_id=$(select_node_id '请选择要显示链接/二维码的节点') || return 0
  show_node_credentials "$node_id"
}
