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

node_base64_uri() {
  local node=$1
  local uri
  uri=$(node_sip002_uri "$node") || return 1
  base64_no_wrap "$uri" || return 1
}

show_node_credentials() {
  local node_id=$1 node uri base64_uri node_status runtime_status active_status=0
  local name address port method password
  node=$(node_by_id "$node_id") || { error "节点不存在或节点数据库读取失败：$node_id"; return 1; }
  uri=$(node_sip002_uri "$node") || { error '无法生成节点 SIP002 URI。'; return 1; }
  base64_uri=$(base64_no_wrap "$uri") || { error '无法生成节点 Base64 信息。'; return 1; }
  node_status=$(jq -er '.status' <<<"$node") || return 1
  runtime_status=$(status_label "$node_status") || return 1
  name=$(jq -er '.name' <<<"$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  method=$(jq -er '.method' <<<"$node") || return 1
  password=$(jq -er '.password' <<<"$node") || return 1
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
  printf '服务器地址：%s\n' "$address"
  printf '端口：%s（TCP + UDP）\n' "$port"
  printf '加密方式：%s\n' "$method"
  printf '密钥：%s\n' "$password"
  printf 'TCP 状态：%s\nUDP 状态：%s\n' "$runtime_status" "$runtime_status"
  printf '\n[Shadowsocks URI / SIP002]\n%s\n' "$uri"
  printf '\n[Base64 节点信息（上方 SIP002 URI 的 Base64）]\n%s\n' "$base64_uri"
  printf '\n[二维码]\n'
  if command -v qrencode >/dev/null 2>&1; then
    # qrencode reads stdin when STRING is omitted; do not expose credentials
    # through its command-line arguments.
    printf '%s' "$uri" | qrencode -t UTF8 -m 1 || warn '二维码生成失败；上方 URI 仍可复制。'
  else
    warn '系统没有 qrencode，无法在终端显示二维码；URI 仍可复制。'
  fi
  printf '\n请检查服务器防火墙、安全组或云厂商防火墙是否放行 TCP/UDP 端口。\n'
  printf '\n请妥善保管以上密钥、链接和二维码，不要提交到 GitHub 或普通日志。\n'
}

show_node_link_flow() {
  local node_id
  select_node_for_flow node_id '请选择要显示链接/二维码的节点' || return 0
  show_node_credentials "$node_id"
}
