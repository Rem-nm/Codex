#!/usr/bin/env bash
# Read-only client export helpers.  This module deliberately receives a single
# validated node object and never reads nodes.json on behalf of the HTTP
# service.  Server-only keys (Reality private keys and TLS key paths) are not
# referenced by any output object.

subscription_certificate_spki_pin() {
  local node=$1 node_id cert digest
  node_id=$(jq -er '.node_id' <<<"$node") || return 1
  cert=$(tls_cert_path "$CERTS_DIR" "$node_id") || return 1
  [[ -f "$cert" && ! -L "$cert" ]] || return 1
  digest=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}') || return 1
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  python3 - "$digest" <<'PY'
import base64
import sys
try:
    raw = bytes.fromhex(sys.argv[1])
except (IndexError, ValueError):
    raise SystemExit(1)
print(base64.b64encode(raw).decode('ascii'), end='')
PY
}

subscription_node_tag() {
  local node=$1 name node_id
  name=$(jq -er '.name' <<<"$node") || return 1
  node_id=$(jq -er '.node_id' <<<"$node") || return 1
  # The stable id is the identity; the name is only a human-facing label.
  jq -nr --arg name "$name" --arg id "$node_id" '"rem-node-" + $id + " (" + $name + ")"'
}

node_client_outbound() {
  local node=$1 protocol address port address_type host tag
  protocol=$(node_protocol "$node") || return 1
  address=$(jq -er '.address' <<<"$node") || return 1
  port=$(jq -er '.port' <<<"$node") || return 1
  address_type=$(jq -er '.address_type' <<<"$node") || return 1
  tag=$(subscription_node_tag "$node") || return 1
  # Client profiles use the unbracketed address value; sing-box JSON carries
  # the address separately and does not use URI authority formatting.
  host="$address"
  case "$protocol" in
    shadowsocks)
      jq --arg tag "$tag" --arg server "$host" --argjson port "$port" \
        --arg method "$(jq -er '.method' <<<"$node")" \
        '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:.password}' <<<"$node"
      ;;
    vless)
      local uuid sni public_key short_id flow
      sni=$(jq -er '.reality_server_name' <<<"$node") || return 1
      public_key=$(jq -er '.reality_public_key' <<<"$node") || return 1
      short_id=$(jq -er '.reality_short_id' <<<"$node") || return 1
      flow=$(jq -er '.flow' <<<"$node") || return 1
      [[ "$flow" == xtls-rprx-vision ]] || return 1
      jq --arg tag "$tag" --arg server "$host" --argjson port "$port" \
        --arg flow "$flow" --arg sni "$sni" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:.uuid,flow:$flow,tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:.reality_public_key,short_id:.reality_short_id}}}' <<<"$node"
      ;;
    hysteria2)
      local password sni pin hop_enabled hop_start hop_end spki
      sni=$(jq -er '.tls_server_name' <<<"$node") || return 1
      hop_enabled=$(jq -r '.port_hopping_enabled // false' <<<"$node") || return 1
      spki=$(subscription_certificate_spki_pin "$node") || return 1
      if [[ "$hop_enabled" == true ]]; then
        hop_start=$(jq -er '.hop_port_start' <<<"$node") || return 1
        hop_end=$(jq -er '.hop_port_end' <<<"$node") || return 1
        jq --arg tag "$tag" --arg server "$host" \
          --arg sni "$sni" --arg spki "$spki" --arg ports "${hop_start}:${hop_end}" \
          '{type:"hysteria2",tag:$tag,server:$server,server_ports:[$ports],password:.password,hop_interval:"30s",tls:{enabled:true,server_name:$sni,certificate_public_key_sha256:[$spki]}}' <<<"$node"
      else
        jq --arg tag "$tag" --arg server "$host" \
          --arg sni "$sni" --arg spki "$spki" --argjson port "$port" \
          '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:.password,tls:{enabled:true,server_name:$sni,certificate_public_key_sha256:[$spki]}}' <<<"$node"
      fi
      ;;
    tuic)
      local sni pin congestion spki
      sni=$(jq -er '.tls_server_name' <<<"$node") || return 1
      congestion=$(jq -er '.congestion_control' <<<"$node") || return 1
      [[ "$congestion" == bbr ]] || return 1
      spki=$(subscription_certificate_spki_pin "$node") || return 1
      jq --arg tag "$tag" --arg server "$host" \
        --arg sni "$sni" --arg spki "$spki" \
        --arg congestion "$congestion" --argjson port "$port" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:.uuid,password:.password,congestion_control:$congestion,udp_relay_mode:"native",zero_rtt_handshake:false,tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_public_key_sha256:[$spki]}}' <<<"$node"
      ;;
    *) return 1 ;;
  esac
}

subscription_profile_from_outbounds() {
  local outbounds_json=$1 output=$2
  [[ -f "$outbounds_json" && ! -L "$outbounds_json" ]] || return 1
  jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.tag | type == "string"))' \
    "$outbounds_json" >/dev/null 2>&1 || return 1
  jq --slurpfile nodes "$outbounds_json" '
    ($nodes[0]) as $items
    | ([{type:"selector",tag:"rem-selector",outbounds:($items | map(.tag)),default:($items[0].tag)}]
       + $items
       + [{type:"direct",tag:"rem-direct"}]) as $outbounds
    | {log:{disabled:true},
       dns:{servers:[{type:"local",tag:"rem-dns"}],final:"rem-dns"},
       inbounds:[{type:"mixed",tag:"rem-mixed-in",listen:"127.0.0.1",listen_port:2080}],
       outbounds:$outbounds,
       route:{final:"rem-selector"}}
  ' "$outbounds_json" >"$output" || return 1
  chmod 600 -- "$output" || return 1
  jq -e . "$output" >/dev/null 2>&1
}
