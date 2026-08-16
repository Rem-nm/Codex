#!/usr/bin/env bash
# Subscription settings, secure derived exports and service lifecycle.
# The HTTP daemon never reads nodes.json; this module is the root-only builder
# that publishes a sanitized snapshot for the dedicated low-privilege user.

subscription_default_json() {
  jq -nc '{schema_version:1,enabled:false,listen_address:"127.0.0.1",listen_port:18080,public_base_url:null,token:null,created_at:null,updated_at:null}'
}

subscription_validate_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

subscription_validate_public_url() {
  local value=$1
  [[ -z "$value" ]] && return 0
  python3 - "$value" <<'PY'
from urllib.parse import urlsplit
import ipaddress
import re
import sys

try:
    value = sys.argv[1]
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError
    if parsed.username is not None or parsed.password is not None:
        raise ValueError
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError
    host = parsed.hostname
    if not host or any(ord(ch) < 0x20 or ch.isspace() for ch in value):
        raise ValueError
    try:
        port = parsed.port
    except ValueError:
        raise ValueError
    if port is not None and not (1 <= port <= 65535):
        raise ValueError
    if ":" in host:
        ipaddress.IPv6Address(host)
    else:
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", host):
            ipaddress.IPv4Address(host)
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

subscription_validate_settings_file() {
  local path=${1:-$SUBSCRIPTION_CONFIG}
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || return 1
  [[ "$(stat -c '%a' -- "$path" 2>/dev/null || printf 0)" == 600 ]] || return 1
  [[ "$(stat -c '%u' -- "$path" 2>/dev/null || printf 1)" == 0 ]] || return 1
  jq -e '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    type == "object"
    and .schema_version == 1
    and (.enabled | type == "boolean")
    and .listen_address == "127.0.0.1"
    and (.listen_port | type == "number" and floor == . and . >= 1 and . <= 65535)
    and ((.public_base_url == null) or (.public_base_url | type == "string"))
    and ((.token == null) or (.token | type == "string" and test("^[A-Za-z0-9_-]{43}$")))
    and ((.created_at == null) or (.created_at | iso))
    and ((.updated_at == null) or (.updated_at | iso))
    and (keys | sort) == ["created_at","enabled","listen_address","listen_port","public_base_url","schema_version","token","updated_at"]
  ' "$path" >/dev/null 2>&1 || return 1
  local enabled url
  enabled=$(jq -r '.enabled' "$path") || return 1
  url=$(jq -r '.public_base_url // empty' "$path") || return 1
  [[ -z "$url" ]] || subscription_validate_public_url "$url" || return 1
  if [[ "$enabled" == true ]]; then
    jq -e '.token != null and .public_base_url != null' "$path" >/dev/null 2>&1 || return 1
  fi
}

subscription_ensure_account() {
  local shell_path=/usr/sbin/nologin
  [[ -x "$shell_path" ]] || shell_path=/sbin/nologin
  if ! getent group "$SUBSCRIPTION_SERVICE_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd --system "$SUBSCRIPTION_SERVICE_GROUP" || return 1
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup -S "$SUBSCRIPTION_SERVICE_GROUP" || return 1
    else
      return 1
    fi
  fi
  if ! getent passwd "$SUBSCRIPTION_SERVICE_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd --system --no-create-home --home-dir /nonexistent --shell "$shell_path" \
        --gid "$SUBSCRIPTION_SERVICE_GROUP" "$SUBSCRIPTION_SERVICE_USER" || return 1
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -h /nonexistent -s "$shell_path" -G "$SUBSCRIPTION_SERVICE_GROUP" \
        "$SUBSCRIPTION_SERVICE_USER" || return 1
    else
      return 1
    fi
  fi
  local uid gid groups
  uid=$(id -u "$SUBSCRIPTION_SERVICE_USER" 2>/dev/null) || return 1
  gid=$(id -g "$SUBSCRIPTION_SERVICE_USER" 2>/dev/null) || return 1
  groups=$(id -Gn "$SUBSCRIPTION_SERVICE_USER" 2>/dev/null) || return 1
  [[ "$uid" != 0 && "$gid" != 0 ]] || return 1
  case " $groups " in
    *" $SUBSCRIPTION_SERVICE_GROUP "*) ;;
    *) return 1 ;;
  esac
}

subscription_ensure_dirs() {
  subscription_ensure_account || return 1
  # The parent data directory contains root-only state files.  Grant only
  # directory traversal to the dedicated subscription user; it still cannot
  # list or read nodes, traffic, certificates, or any other sibling file.
  chmod 711 -- "$DATA_DIR" || return 1
  ensure_dir "$SUBSCRIPTION_DIR" 750 || return 1
  chown root:"$SUBSCRIPTION_SERVICE_GROUP" -- "$SUBSCRIPTION_DIR" 2>/dev/null || return 1
  chmod 750 -- "$SUBSCRIPTION_DIR" || return 1
}

subscription_initialize() {
  ensure_dir "$CONFIG_DIR" 700 || return 1
  subscription_ensure_dirs || return 1
  if [[ -e "$SUBSCRIPTION_CONFIG" || -L "$SUBSCRIPTION_CONFIG" ]]; then
    subscription_validate_settings_file "$SUBSCRIPTION_CONFIG" || {
      error 'subscription.json 语义或权限无效；请先使用备份恢复。'
      return 1
    }
  else
    local now
    now=$(timestamp_iso) || return 1
    subscription_default_json | jq --arg now "$now" '.created_at=$now | .updated_at=$now' \
      | atomic_json_from_stdin "$SUBSCRIPTION_CONFIG" 600 || return 1
  fi
  subscription_validate_settings_file "$SUBSCRIPTION_CONFIG"
}

subscription_generate_token() {
  local token
  token=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\r\n') || return 1
  subscription_validate_token "$token" || return 1
  printf '%s' "$token"
}

subscription_port_available() {
  local port=$1 allow_existing=${2:-}
  validate_port "$port" || return 1
  if [[ -n "$allow_existing" && "$allow_existing" == "$port" ]]; then
    # Reusing the current port is safe only while the project service is the
    # listener.  A disabled/stale service must not hide a third-party process
    # that took the same port in the meantime.
    local service_name active_status=2
    if declare -F subscription_service_definition_name >/dev/null 2>&1 \
      && declare -F service_is_active >/dev/null 2>&1; then
      service_name=$(subscription_service_definition_name 2>/dev/null) || service_name=''
      if [[ -n "$service_name" ]]; then
        if service_is_active "$service_name" >/dev/null 2>&1; then
          active_status=0
        else
          active_status=$?
        fi
      fi
    fi
    [[ "$active_status" == 0 ]] && return 0
  fi
  local output
  output=$(ss -H -ltn 2>/dev/null) || return 2
  awk -v pattern=":${port}$" '$4 ~ pattern {found=1} END {exit found ? 1 : 0}' <<<"$output"
}

subscription_qualified_nodes() {
  local source=${1:-$NODES_FILE}
  [[ -f "$source" && ! -L "$source" ]] || return 1
  jq -c '[.nodes[] | select(.subscription_enabled == true and .status == "enabled")]
    | sort_by((.created_at // ""), .node_id)[]' "$source"
}

subscription_build_export_candidate() {
  local nodes_source=$1 export_candidate=$2 profile_candidate=$3
  local items_file failed_file node node_id uri outbound reason raw_file base64_file outbounds_file
  items_file=$(runtime_temp_file subscription-items) || return 1
  failed_file=$(runtime_temp_file subscription-failed) || { rm -f -- "$items_file"; return 1; }
  raw_file=$(runtime_temp_file subscription-raw) || { rm -f -- "$items_file" "$failed_file"; return 1; }
  base64_file=$(runtime_temp_file subscription-base64) || { rm -f -- "$items_file" "$failed_file" "$raw_file"; return 1; }
  outbounds_file=$(runtime_temp_file subscription-outbounds) || { rm -f -- "$items_file" "$failed_file" "$raw_file" "$base64_file"; return 1; }
  printf '[]' >"$items_file"; printf '[]' >"$failed_file"; printf '[]' >"$outbounds_file"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_id=$(jq -er '.node_id' <<<"$node") || continue
    reason='uri_or_outbound_generation_failed'
    uri=$(node_share_uri "$node" 2>/dev/null) || uri=''
    if [[ -n "$uri" ]] && [[ "$uri" != *$'\n'* ]] && [[ "$uri" != *$'\r'* ]]; then
      outbound=$(node_client_outbound "$node" 2>/dev/null) || outbound=''
      if [[ -n "$outbound" ]] && jq -e 'type == "object" and (.tag | type == "string")' <<<"$outbound" >/dev/null 2>&1; then
        jq --arg id "$node_id" --arg uri "$uri" --argjson outbound "$outbound" \
          '. + [{node_id:$id,uri:$uri,outbound:$outbound}]' "$items_file" >"$items_file.next" \
          && mv -f -- "$items_file.next" "$items_file" || { rm -f -- "$items_file.next"; return 1; }
        jq --argjson outbound "$outbound" '. + [$outbound]' "$outbounds_file" >"$outbounds_file.next" \
          && mv -f -- "$outbounds_file.next" "$outbounds_file" || { rm -f -- "$outbounds_file.next"; return 1; }
        continue
      fi
    fi
    jq --arg id "$node_id" --arg reason "$reason" '. + [{node_id:$id,reason:$reason}]' "$failed_file" >"$failed_file.next" \
      && mv -f -- "$failed_file.next" "$failed_file" || { rm -f -- "$failed_file.next"; return 1; }
  done < <(subscription_qualified_nodes "$nodes_source")
  local item_count failed_count generated_at raw base64 profile_available profile_json
  item_count=$(jq -er 'length' "$items_file") || return 1
  failed_count=$(jq -er 'length' "$failed_file") || return 1
  if (( item_count == 0 )); then
    jq -n --arg generated_at "$(timestamp_iso)" --slurpfile failed "$failed_file" \
      '{schema_version:1,available:false,generated_at:$generated_at,node_count:0,failed_nodes:$failed[0],raw:null,base64:null,profile:null,profile_available:false}' \
      >"$export_candidate" || return 1
    jq -n '{type:"array",items:[]}' >"$profile_candidate" || return 1
  else
    jq -j 'map(.uri) | join("\n") + "\n"' "$items_file" >"$raw_file" || return 1
    if base64 --help 2>&1 | grep -q -- '-w'; then
      base64 -w 0 <"$raw_file" >"$base64_file" || return 1
    else
      base64 <"$raw_file" | tr -d '\r\n' >"$base64_file" || return 1
    fi
    profile_available=true
    profile_json='null'
    if subscription_profile_from_outbounds "$outbounds_file" "$profile_candidate" \
      && singbox_check_config "$profile_candidate" >/dev/null 2>&1; then
      profile_json=$(<"$profile_candidate")
    else
      profile_available=false
      rm -f -- "$profile_candidate"
    fi
    generated_at=$(timestamp_iso) || return 1
    jq -n --arg generated_at "$generated_at" --slurpfile items "$items_file" \
      --slurpfile failed "$failed_file" --rawfile raw "$raw_file" --rawfile base64 "$base64_file" \
      --argjson profile_available "$profile_available" --argjson profile "$profile_json" \
      '{schema_version:1,available:true,generated_at:$generated_at,node_count:($items[0]|length),failed_nodes:$failed[0],raw:$raw,base64:$base64,profile:$profile,profile_available:$profile_available}' \
      >"$export_candidate" || return 1
  fi
  chmod 600 -- "$export_candidate" "$profile_candidate" 2>/dev/null || true
  jq -e 'type == "object" and .schema_version == 1 and (.available | type == "boolean")' \
    "$export_candidate" >/dev/null 2>&1 || return 1
  rm -f -- "$items_file" "$failed_file" "$raw_file" "$base64_file" "$outbounds_file" "$profile_candidate" 2>/dev/null || true
}

subscription_publish_unavailable_export() {
  local reason=${1:-generation_failed} candidate runtime_candidate generated_at
  [[ "$reason" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || reason=generation_failed
  candidate=$(runtime_temp_file subscription-export-unavailable) || return 1
  runtime_candidate=$(runtime_temp_file subscription-runtime-unavailable) || {
    rm -f -- "$candidate"
    return 1
  }
  generated_at=$(timestamp_iso) || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  jq -n --arg generated_at "$generated_at" --arg reason "$reason" \
    '{schema_version:1,available:false,generated_at:$generated_at,node_count:0,failed_nodes:[{node_id:"*",reason:$reason}],raw:null,base64:null,profile:null,profile_available:false}' \
    >"$candidate" || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  jq --arg export "$SUBSCRIPTION_EXPORT" --arg generated_at "$generated_at" \
    --argjson listen_port "$(jq -er '.listen_port' "$SUBSCRIPTION_CONFIG")" \
    '{schema_version:1,token:(if .token == null then null else .token end),export_path:$export,generated_at:$generated_at,listen_port:$listen_port}' \
    "$SUBSCRIPTION_CONFIG" >"$runtime_candidate" || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  chmod 600 -- "$candidate" "$runtime_candidate" || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  atomic_json_write "$candidate" "$SUBSCRIPTION_EXPORT" 640 || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  atomic_json_write "$runtime_candidate" "$SUBSCRIPTION_RUNTIME" 640 || {
    rm -f -- "$candidate" "$runtime_candidate"
    return 1
  }
  chown root:"$SUBSCRIPTION_SERVICE_GROUP" -- "$SUBSCRIPTION_EXPORT" "$SUBSCRIPTION_RUNTIME" 2>/dev/null || return 1
  chmod 640 -- "$SUBSCRIPTION_EXPORT" "$SUBSCRIPTION_RUNTIME" || return 1
  rm -f -- "$candidate" "$runtime_candidate"
}

subscription_publish_export() {
  local nodes_source=${1:-$NODES_FILE}
  subscription_initialize || return 1
  local candidate profile_candidate runtime_candidate token
  candidate=$(runtime_temp_file subscription-export-candidate) || return 1
  profile_candidate=$(runtime_temp_file subscription-profile-candidate) || { rm -f -- "$candidate"; return 1; }
  if ! subscription_build_export_candidate "$nodes_source" "$candidate" "$profile_candidate"; then
    rm -f -- "$candidate" "$profile_candidate"
    # Never leave a previous snapshot serving credentials for a state that
    # could not be exported.  The daemon will fail closed with HTTP 503.
    subscription_publish_unavailable_export generation_failed >/dev/null 2>&1 || true
    return 1
  fi
  token=$(jq -r '.token // empty' "$SUBSCRIPTION_CONFIG") || return 1
  if [[ -n "$token" ]]; then subscription_validate_token "$token" || return 1; fi
  runtime_candidate=$(runtime_temp_file subscription-runtime-candidate) || { rm -f -- "$candidate"; return 1; }
  jq --arg export "$SUBSCRIPTION_EXPORT" \
    --arg generated_at "$(jq -r '.generated_at' "$candidate")" \
    --argjson listen_port "$(jq -er '.listen_port' "$SUBSCRIPTION_CONFIG")" \
    '{schema_version:1,token:(if .token == null then null else .token end),export_path:$export,generated_at:$generated_at,listen_port:$listen_port}' \
    "$SUBSCRIPTION_CONFIG" \
    >"$runtime_candidate" || { rm -f -- "$candidate" "$profile_candidate" "$runtime_candidate"; return 1; }
  atomic_json_write "$candidate" "$SUBSCRIPTION_EXPORT" 640 || { rm -f -- "$candidate" "$profile_candidate" "$runtime_candidate"; return 1; }
  atomic_json_write "$runtime_candidate" "$SUBSCRIPTION_RUNTIME" 640 || { rm -f -- "$candidate" "$profile_candidate" "$runtime_candidate"; return 1; }
  chown root:"$SUBSCRIPTION_SERVICE_GROUP" -- "$SUBSCRIPTION_EXPORT" "$SUBSCRIPTION_RUNTIME" 2>/dev/null || return 1
  chmod 640 -- "$SUBSCRIPTION_EXPORT" "$SUBSCRIPTION_RUNTIME" || return 1
  rm -f -- "$candidate" "$profile_candidate" "$runtime_candidate" 2>/dev/null || true
}

subscription_service_definition_name() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then printf '%s' "$SYSTEMD_SUBSCRIPTION_SERVICE"; else printf '%s' "$OPENRC_SUBSCRIPTION_SERVICE"; fi
}

subscription_service_install_definition() {
  local name source destination install_mode=644
  name=$(subscription_service_definition_name) || return 1
  destination=$(service_definition_path "$name") || return 1
  if [[ "$INIT_SYSTEM" == systemd ]]; then source="$PROGRAM_DIR/systemd/$SYSTEMD_SUBSCRIPTION_SERVICE"; else source="$PROGRAM_DIR/openrc/$OPENRC_SUBSCRIPTION_SERVICE"; fi
  [[ "$INIT_SYSTEM" == systemd ]] || install_mode=755
  [[ -f "$source" && ! -L "$source" ]] || return 1
  if service_definition_path_present "$name" && ! service_definition_is_managed "$name"; then
    die "$destination 已存在且不是本项目创建，拒绝覆盖订阅服务。"
  fi
  atomic_file_write "$source" "$destination" "$install_mode" 755 || return 1
  service_manager_reload
}

subscription_service_enable() {
  subscription_service_install_definition || return 1
  local name
  name=$(subscription_service_definition_name) || return 1
  service_enable "$name" >/dev/null || return 1
  service_start "$name" >/dev/null || return 1
  service_is_active "$name"
}

subscription_service_disable() {
  local name status=0
  name=$(subscription_service_definition_name) || return 1
  if service_is_active "$name" >/dev/null 2>&1; then
    service_stop "$name" >/dev/null || return 1
  else
    status=$?
    (( status == 1 )) || return 1
  fi
  if service_is_enabled "$name" >/dev/null 2>&1; then
    service_disable "$name" >/dev/null || return 1
  else
    status=$?
    (( status == 1 )) || return 1
  fi
  return 0
}

subscription_service_remove_definition() {
  local name presence_status=0 active_status=0 enabled_status=0
  name=$(subscription_service_definition_name) || return 1
  if ! service_definition_path_present "$name"; then
    service_exists "$name" || presence_status=$?
    (( presence_status == 1 )) && return 0
    (( presence_status == 0 )) && { error "检测到不受 Ss2022 管理的订阅服务：$name"; return 1; }
    return 1
  fi
  service_definition_is_managed "$name" || return 1
  service_is_active "$name" || active_status=$?
  (( active_status != 2 )) || return 1
  if (( active_status == 0 )); then service_stop "$name" >/dev/null || return 1; fi
  service_is_enabled "$name" || enabled_status=$?
  (( enabled_status != 2 )) || return 1
  if (( enabled_status == 0 )); then service_disable "$name" >/dev/null || return 1; fi
  service_remove_managed_definition "$name"
}

subscription_remove_account() {
  if id "$SUBSCRIPTION_SERVICE_USER" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then userdel "$SUBSCRIPTION_SERVICE_USER" >/dev/null 2>&1 || return 1; elif command -v deluser >/dev/null 2>&1; then deluser "$SUBSCRIPTION_SERVICE_USER" >/dev/null 2>&1 || return 1; else return 1; fi
  fi
  if getent group "$SUBSCRIPTION_SERVICE_GROUP" >/dev/null 2>&1; then
    if command -v groupdel >/dev/null 2>&1; then groupdel "$SUBSCRIPTION_SERVICE_GROUP" >/dev/null 2>&1 || return 1; elif command -v delgroup >/dev/null 2>&1; then delgroup "$SUBSCRIPTION_SERVICE_GROUP" >/dev/null 2>&1 || return 1; else return 1; fi
  fi
}

subscription_update_settings() {
  local enabled=$1 public_url=${2:-} port=${3:-18080} rotate=${4:-false}
  [[ "$enabled" == true || "$enabled" == false ]] || return 1
  validate_port "$port" || return 1
  local current_port
  current_port=$(jq -r '.listen_port // empty' "$SUBSCRIPTION_CONFIG") || return 1
  subscription_port_available "$port" "$current_port" || {
    local port_status=$?
    (( port_status == 1 )) && error "订阅本地 TCP 端口已被占用：$port"
    return "$port_status"
  }
  [[ -z "$public_url" ]] || subscription_validate_public_url "$public_url" || return 1
  local old_token token now candidate token_file old_settings old_enabled old_url old_port
  old_settings=$(runtime_temp_file subscription-settings-old) || return 1
  install -m 600 -- "$SUBSCRIPTION_CONFIG" "$old_settings" || return 1
  old_token=$(jq -r '.token // empty' "$SUBSCRIPTION_CONFIG") || return 1
  old_enabled=$(jq -r '.enabled' "$SUBSCRIPTION_CONFIG") || return 1
  old_url=$(jq -r '.public_base_url // empty' "$SUBSCRIPTION_CONFIG") || return 1
  old_port=$(jq -er '.listen_port' "$SUBSCRIPTION_CONFIG") || return 1
  token="$old_token"
  if [[ "$rotate" == true || -z "$token" ]]; then token=$(subscription_generate_token) || return 1; fi
  if [[ "$enabled" == true && -z "$public_url" ]]; then return 1; fi
  now=$(timestamp_iso) || return 1
  candidate=$(runtime_temp_file subscription-settings) || return 1
  token_file=$(runtime_temp_file subscription-token) || { rm -f -- "$candidate"; return 1; }
  printf '%s\n' "$token" >"$token_file"
  chmod 600 -- "$token_file" || { rm -f -- "$candidate" "$token_file"; return 1; }
  jq --argjson enabled "$enabled" --arg url "$public_url" --argjson port "$port" \
    --rawfile token "$token_file" --arg now "$now" '.enabled=$enabled | .listen_address="127.0.0.1" | .listen_port=$port | .public_base_url=(if $url=="" then null else ($url|sub("/$";"")) end) | .token=(($token|rtrimstr("\n")) | if .=="" then null else . end) | .updated_at=$now | .created_at=(.created_at // $now)' \
    "$SUBSCRIPTION_CONFIG" >"$candidate" || { rm -f -- "$candidate" "$token_file"; return 1; }
  rm -f -- "$token_file" || true
  atomic_json_write "$candidate" "$SUBSCRIPTION_CONFIG" 600 || { rm -f -- "$candidate" "$token_file" "$old_settings"; return 1; }
  rm -f -- "$candidate" || true
  rm -f -- "$token_file" || true
  if ! subscription_publish_export "$NODES_FILE"; then
    atomic_json_write "$old_settings" "$SUBSCRIPTION_CONFIG" 600 || true
    subscription_publish_export "$NODES_FILE" || true
    rm -f -- "$old_settings"
    return 1
  fi
  if [[ "$enabled" == true ]]; then
    if [[ "$old_enabled" == true && "$old_port" != "$port" ]]; then
      subscription_service_restart || {
        atomic_json_write "$old_settings" "$SUBSCRIPTION_CONFIG" 600 || true
        subscription_publish_export "$NODES_FILE" || true
        subscription_service_enable || true
        rm -f -- "$old_settings"
        return 1
      }
    else
      subscription_service_enable || {
        atomic_json_write "$old_settings" "$SUBSCRIPTION_CONFIG" 600 || true
        subscription_publish_export "$NODES_FILE" || true
        if [[ "$old_enabled" == true ]]; then subscription_service_enable || true; else subscription_service_disable || true; fi
        rm -f -- "$old_settings"
        return 1
      }
    fi
  else
    subscription_service_disable || {
      atomic_json_write "$old_settings" "$SUBSCRIPTION_CONFIG" 600 || true
      subscription_publish_export "$NODES_FILE" || true
      if [[ "$old_enabled" == true ]]; then subscription_service_enable || true; else subscription_service_disable || true; fi
      rm -f -- "$old_settings"
      return 1
    }
  fi
  rm -f -- "$old_settings"
}

subscription_service_restart() {
  local name
  name=$(subscription_service_definition_name) || return 1
  service_restart "$name" >/dev/null || return 1
  service_is_active "$name"
}

subscription_local_health() {
  subscription_validate_settings_file "$SUBSCRIPTION_CONFIG" || return 1
  local enabled token port name
  enabled=$(jq -r '.enabled' "$SUBSCRIPTION_CONFIG") || return 1
  [[ "$enabled" == true ]] || return 0
  token=$(jq -er '.token' "$SUBSCRIPTION_CONFIG") || return 1
  port=$(jq -er '.listen_port' "$SUBSCRIPTION_CONFIG") || return 1
  name=$(subscription_service_definition_name) || return 1
  service_is_active "$name" || return 1
  local curl_config
  curl_config=$(runtime_temp_file subscription-health-curl) || return 1
  printf 'url = "http://127.0.0.1:%s/healthz"\n' "$port" >"$curl_config"
  curl --config "$curl_config" --proto '=http' --fail --silent --show-error --max-time 5 >/dev/null || { rm -f -- "$curl_config"; return 1; }
  printf 'url = "http://127.0.0.1:%s/sub/%s/raw"\n' "$port" "$token" >"$curl_config"
  curl --config "$curl_config" --proto '=http' --fail --silent --show-error --max-time 5 >/dev/null || { rm -f -- "$curl_config"; return 1; }
  rm -f -- "$curl_config"
}

subscription_url() {
  local token base port
  token=$(jq -er '.token' "$SUBSCRIPTION_CONFIG") || return 1
  base=$(jq -r '.public_base_url // empty' "$SUBSCRIPTION_CONFIG") || return 1
  if [[ -z "$base" ]]; then
    port=$(jq -er '.listen_port' "$SUBSCRIPTION_CONFIG") || return 1
    base="http://127.0.0.1:$port"
  fi
  printf '%s/sub/%s' "${base%/}" "$token"
}
