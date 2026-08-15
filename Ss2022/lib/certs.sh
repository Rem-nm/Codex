#!/usr/bin/env bash
# Shared TLS certificate lifecycle for UDP/QUIC nodes. Private keys live only
# in this protected directory; nodes.json stores the leaf-certificate digest
# and SNI, never a key or an arbitrary filesystem path.

tls_protocol_uses_managed_certificate() {
  [[ "$1" == hysteria2 || "$1" == tuic ]]
}

tls_cert_dir() {
  local root=${1:-$CERTS_DIR} node_id=$2
  [[ "$root" == /* && "$root" != *$'\n'* ]] || return 1
  [[ "$node_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  printf '%s/%s' "$root" "$node_id"
}

tls_cert_path() {
  local dir
  dir=$(tls_cert_dir "${1:-$CERTS_DIR}" "$2") || return 1
  printf '%s/cert.pem' "$dir"
}

tls_key_path() {
  local dir
  dir=$(tls_cert_dir "${1:-$CERTS_DIR}" "$2") || return 1
  printf '%s/key.pem' "$dir"
}

validate_hysteria_password() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{8,128}$ ]]
}

validate_tuic_password() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{8,128}$ ]]
}

validate_certificate_sha256() {
  [[ "$1" =~ ^[a-f0-9]{64}$ ]]
}

tls_server_name_for_node() {
  local protocol=$1 node_id=$2 prefix
  [[ "$node_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  case "$protocol" in
    hysteria2) prefix=hy2 ;;
    tuic) prefix=tuic ;;
    *) return 1 ;;
  esac
  printf '%s-%s.invalid' "$prefix" "$node_id"
}

generate_quic_password() {
  local value
  value=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\r\n') || return 1
  [[ "$value" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || return 1
  printf '%s' "$value"
}

generate_hysteria2_password() {
  local value
  value=$(generate_quic_password) || return 1
  validate_hysteria_password "$value" || return 1
  printf '%s' "$value"
}

generate_tuic_password() {
  local value
  value=$(generate_quic_password) || return 1
  validate_tuic_password "$value" || return 1
  printf '%s' "$value"
}

tls_certificate_pin() {
  local cert=$1 digest
  [[ -f "$cert" && ! -L "$cert" ]] || return 1
  digest=$(openssl x509 -in "$cert" -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  validate_certificate_sha256 "$digest" || return 1
  printf '%s' "$digest"
}

tls_generate_certificate() {
  local root=$1 node_id=$2 server_name=$3 dir cert key config
  dir=$(tls_cert_dir "$root" "$node_id") || return 1
  validate_domain_name "$server_name" || return 1
  ensure_dir "$root" 700 || return 1
  [[ ! -e "$dir" && ! -L "$dir" ]] || rm -rf -- "$dir" || return 1
  ensure_dir "$dir" 700 || return 1
  cert="$dir/cert.pem"
  key="$dir/key.pem"
  config=$(mktemp "$dir/openssl.XXXXXXXX") || { rm -rf -- "$dir"; return 1; }
  chmod 600 -- "$config" || { rm -rf -- "$dir"; return 1; }
  # The temporary OpenSSL config avoids relying on -addext, which is absent in
  # some OpenSSL 1.1 builds still found on supported Alpine images.
  printf '%s\n' \
    '[req]' \
    'distinguished_name = req_distinguished_name' \
    'x509_extensions = v3_req' \
    'prompt = no' \
    '[req_distinguished_name]' \
    "CN = $server_name" \
    '[v3_req]' \
    'basicConstraints = critical,CA:FALSE' \
    'keyUsage = critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage = serverAuth' \
    "subjectAltName = DNS:$server_name" >"$config" || { rm -rf -- "$dir"; return 1; }
  if ! openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -nodes -sha256 -days 3650 -keyout "$key" -out "$cert" \
    -config "$config" >/dev/null 2>&1; then
    rm -rf -- "$dir"
    return 1
  fi
  rm -f -- "$config" || { rm -rf -- "$dir"; return 1; }
  chmod 600 -- "$cert" "$key" || { rm -rf -- "$dir"; return 1; }
  chown root:root -- "$cert" "$key" "$dir" 2>/dev/null || true
  tls_certificate_pin "$cert"
}

tls_validate_certificate_files() {
  local root=$1 node_id=$2 server_name=$3 expected_pin=$4 cert key actual_pin cert_pub key_pub san
  validate_domain_name "$server_name" || return 1
  validate_certificate_sha256 "$expected_pin" || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  [[ "$(stat -c '%a' -- "$root" 2>/dev/null || printf 0)" == 700
    && "$(stat -c '%u' -- "$root" 2>/dev/null || printf 1)" == 0 ]] || return 1
  cert=$(tls_cert_path "$root" "$node_id") || return 1
  key=$(tls_key_path "$root" "$node_id") || return 1
  [[ -d "${cert%/*}" && ! -L "${cert%/*}" && -f "$cert" && ! -L "$cert" && -f "$key" && ! -L "$key" ]] || return 1
  [[ "$(stat -c '%a' -- "${cert%/*}" 2>/dev/null || printf 0)" == 700 ]] || return 1
  [[ "$(stat -c '%a' -- "$cert" 2>/dev/null || printf 0)" == 600 ]] || return 1
  [[ "$(stat -c '%a' -- "$key" 2>/dev/null || printf 0)" == 600 ]] || return 1
  [[ "$(stat -c '%u' -- "${cert%/*}" 2>/dev/null || printf 1)" == 0
    && "$(stat -c '%u' -- "$cert" 2>/dev/null || printf 1)" == 0
    && "$(stat -c '%u' -- "$key" 2>/dev/null || printf 1)" == 0 ]] || return 1
  [[ "$(stat -c '%h' -- "$cert" 2>/dev/null || printf 0)" == 1
    && "$(stat -c '%h' -- "$key" 2>/dev/null || printf 0)" == 1 ]] || return 1
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
  actual_pin=$(tls_certificate_pin "$cert") || return 1
  [[ "$actual_pin" == "$expected_pin" ]] || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || return 1
  san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)
  # Compare a complete SAN entry. A substring test would incorrectly accept a
  # certificate for "expected.example.evil" when the node expects
  # "expected.example".
  tr ',' '\n' <<<"$san" | awk -v expected="DNS:$server_name" '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 == expected) found=1
    }
    END { exit !found }
  ' || return 1
  openssl verify -CAfile "$cert" "$cert" >/dev/null 2>&1 || return 1
}

validate_tls_certificate_state() {
  local nodes_source=${1:-$NODES_FILE} root=${2:-$CERTS_DIR} node node_id protocol server_name pin entry base expected
  [[ -f "$nodes_source" && ! -L "$nodes_source" ]] || return 1
  jq -e 'type == "object" and (.nodes | type == "array")' "$nodes_source" >/dev/null 2>&1 || return 1
  [[ -d "$root" && ! -L "$root" ]] || {
    jq -e 'any(.nodes[]?; .protocol == "hysteria2" or .protocol == "tuic")' "$nodes_source" >/dev/null 2>&1 && return 1
    return 0
  }
  [[ "$(stat -c '%a' -- "$root" 2>/dev/null || printf 0)" == 700
    && "$(stat -c '%u' -- "$root" 2>/dev/null || printf 1)" == 0 ]] || return 1
  # The root is project-owned state, not a general certificate store. Reject
  # foreign files/directories and orphan node IDs instead of silently copying
  # them through an install, backup or restore transaction.
  for entry in "$root"/* "$root"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" && ! -L "$entry" ]] || return 1
    base=${entry##*/}
    [[ "$base" =~ ^[a-f0-9]{32}$ ]] || return 1
    jq -e --arg id "$base" 'any(.nodes[]?; (.protocol == "hysteria2" or .protocol == "tuic") and .node_id == $id)' "$nodes_source" >/dev/null 2>&1 || return 1
  done
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || return 1
    protocol=$(jq -er '.protocol // "shadowsocks"' <<<"$node") || return 1
    tls_protocol_uses_managed_certificate "$protocol" || continue
    server_name=$(jq -er '.tls_server_name' <<<"$node") || return 1
    pin=$(jq -er '.certificate_sha256' <<<"$node") || return 1
    expected=$(tls_cert_dir "$root" "$node_id") || return 1
    for entry in "$expected"/* "$expected"/.[!.]*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      base=${entry##*/}
      [[ "$base" == cert.pem || "$base" == key.pem ]] || return 1
    done
    tls_validate_certificate_files "$root" "$node_id" "$server_name" "$pin" || return 1
  done < <(jq -c '.nodes[]' "$nodes_source")
  return 0
}

tls_make_candidate_cert_root() {
  local candidate
  ensure_dir "$CONFIG_DIR" 700 || return 1
  candidate=$(mktemp -d "$CONFIG_DIR/.certs-candidate.XXXXXXXX") || return 1
  chmod 700 -- "$candidate" || { rm -rf -- "$candidate"; return 1; }
  if [[ -d "$CERTS_DIR" && ! -L "$CERTS_DIR" ]]; then
    cp -a -- "$CERTS_DIR/." "$candidate/" || { rm -rf -- "$candidate"; return 1; }
  fi
  printf '%s' "$candidate"
}

tls_publish_candidate_cert_root() {
  local candidate=$1
  [[ "$candidate" == "$CONFIG_DIR/.certs-candidate."* && -d "$candidate" && ! -L "$candidate" ]] || return 1
  if [[ -e "$CERTS_DIR" || -L "$CERTS_DIR" ]]; then
    [[ -d "$CERTS_DIR" && ! -L "$CERTS_DIR" ]] || return 1
    rm -rf -- "$CERTS_DIR" || return 1
  fi
  mv -- "$candidate" "$CERTS_DIR" || return 1
  chmod 700 -- "$CERTS_DIR" || return 1
  durable_sync_path "$CONFIG_DIR" || return 1
}

tls_remove_candidate_node() {
  local candidate=$1 node_id=$2 dir
  [[ "$candidate" == "$CONFIG_DIR/.certs-candidate."* ]] || return 1
  dir=$(tls_cert_dir "$candidate" "$node_id") || return 1
  [[ "$dir" == "$candidate/"* ]] || return 1
  [[ ! -e "$dir" && ! -L "$dir" ]] || rm -rf -- "$dir"
}

# Compatibility wrappers keep existing Hysteria2 integrations and third-party
# callers stable while all new code uses the protocol-neutral TLS manager.
hysteria2_cert_dir() { tls_cert_dir "$@"; }
hysteria2_cert_path() { tls_cert_path "$@"; }
hysteria2_key_path() { tls_key_path "$@"; }
hysteria2_server_name_for_node() { tls_server_name_for_node hysteria2 "$1"; }
tuic_server_name_for_node() { tls_server_name_for_node tuic "$1"; }
hysteria2_certificate_pin() { tls_certificate_pin "$@"; }
hysteria2_generate_certificate() { tls_generate_certificate "$@"; }
hysteria2_validate_certificate_files() { tls_validate_certificate_files "$@"; }
validate_hysteria2_certificate_state() { validate_tls_certificate_state "$@"; }
hysteria2_make_candidate_cert_root() { tls_make_candidate_cert_root "$@"; }
hysteria2_publish_candidate_cert_root() { tls_publish_candidate_cert_root "$@"; }
hysteria2_remove_candidate_node() { tls_remove_candidate_node "$@"; }
