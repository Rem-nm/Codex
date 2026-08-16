#!/usr/bin/env bash
# Host time synchronization and sing-box NTP fallback helpers.

time_sync_default_json() {
  jq -n \
    --arg server "${DEFAULT_NTP_SERVER:-time.apple.com}" \
    --arg interval "${DEFAULT_NTP_INTERVAL:-30m}" \
    --argjson port "${DEFAULT_NTP_PORT:-123}" \
    '{system_sync_enabled:true,singbox_ntp_enabled:true,ntp_server:$server,ntp_port:$port,ntp_interval:$interval,provider:"unknown",service_name:"",installed_by_rem:false,last_status:"unknown",last_checked_at:null,last_sync_at:null}'
}

time_sync_validate_server() {
  local server=${1:-}
  [[ -n "$server" && ${#server} -le 253 ]] || return 1
  [[ "$server" != *$'\n'* && "$server" != *$'\r'* && "$server" != *$'\t'* ]] || return 1
  [[ "$server" != *'/'* && "$server" != *'"'* && "$server" != *"'"* && "$server" != *'%'* ]] || return 1
  validate_address "$server" >/dev/null 2>&1
}

time_sync_validate_settings_json() {
  local value=$1 server
  jq -e '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    type == "object"
    and (keys | sort) == (["installed_by_rem","last_checked_at","last_status","last_sync_at","ntp_interval","ntp_port","ntp_server","provider","service_name","singbox_ntp_enabled","system_sync_enabled"] | sort)
    and (.system_sync_enabled | type == "boolean")
    and (.singbox_ntp_enabled | type == "boolean")
    and (.ntp_server | type == "string" and length >= 1 and length <= 253)
    and (.ntp_port | type == "number" and floor == . and . >= 1 and . <= 65535)
    and (.ntp_interval == "30m")
    and (.provider == "chrony" or .provider == "systemd-timesyncd" or .provider == "unknown")
    and (.service_name | type == "string" and length <= 128 and test("^[A-Za-z0-9_.@-]*$"))
    and (.installed_by_rem | type == "boolean")
    and (.last_status == "synchronized" or .last_status == "unsynchronized" or .last_status == "unknown" or .last_status == "disabled" or .last_status == "error")
    and (.last_checked_at == null or (.last_checked_at | iso))
    and (.last_sync_at == null or (.last_sync_at | iso))
  ' <<<"$value" >/dev/null 2>&1 || return 1
  server=$(jq -er '.ntp_server' <<<"$value") || return 1
  time_sync_validate_server "$server"
}

time_sync_state_json() {
  local value has_time_sync=0
  if [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]]; then
    if jq -e 'has("time_sync")' "$MANAGER_STATE" >/dev/null 2>&1; then
      has_time_sync=1
    fi
    if (( has_time_sync == 1 )); then
      value=$(jq -ce '.time_sync' "$MANAGER_STATE") || return 1
      time_sync_validate_settings_json "$value" || return 1
      printf '%s' "$value"
      return 0
    fi
  fi
  time_sync_default_json
}

time_sync_migrate_manager_state() {
  [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]] || return 0
  jq -e . "$MANAGER_STATE" >/dev/null 2>&1 || return 1
  local has_time_sync=0
  if jq -e 'has("time_sync")' "$MANAGER_STATE" >/dev/null 2>&1; then
    has_time_sync=1
  fi
  if (( has_time_sync == 1 )); then
    local current
    current=$(jq -ce '.time_sync' "$MANAGER_STATE") || return 1
    time_sync_validate_settings_json "$current" || {
      error 'manager.json 的 time_sync 结构无效；请先使用备份恢复。'
      return 1
    }
    return 0
  fi
  local defaults candidate
  defaults=$(time_sync_default_json) || return 1
  candidate=$(runtime_temp_file manager-time-sync-migration) || return 1
  if ! jq --argjson time_sync "$defaults" '.time_sync=$time_sync' "$MANAGER_STATE" >"$candidate"; then
    rm -f -- "$candidate"
    return 1
  fi
  chmod 600 -- "$candidate" || { rm -f -- "$candidate"; return 1; }
  if ! time_sync_validate_settings_json "$(jq -ce '.time_sync' "$candidate")"; then
    rm -f -- "$candidate"
    return 1
  fi
  atomic_json_write "$candidate" "$MANAGER_STATE" 600 || {
    rm -f -- "$candidate"
    return 1
  }
  rm -f -- "$candidate" || return 1
  info '已为现有 manager.json 补齐系统时间同步和 sing-box NTP 默认设置。'
}

time_sync_chrony_service_name() {
  local candidate path
  if [[ "${INIT_SYSTEM:-systemd}" == systemd ]]; then
    for candidate in chrony chronyd; do
      if service_is_active "$candidate" >/dev/null 2>&1; then
        printf '%s' "$candidate"
        return 0
      fi
    done
    for candidate in chrony chronyd; do
      if service_exists "$candidate" >/dev/null 2>&1; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  else
    for candidate in chronyd chrony; do
      path=$(service_definition_path "$candidate" 2>/dev/null || true)
      if [[ -n "$path" && -x "$path" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

time_sync_timesyncd_service_name() {
  [[ "${INIT_SYSTEM:-systemd}" == systemd ]] || return 1
  if service_exists systemd-timesyncd >/dev/null 2>&1; then
    printf '%s' systemd-timesyncd
    return 0
  fi
  return 1
}

time_sync_chrony_status() {
  local output
  command -v chronyc >/dev/null 2>&1 || return 2
  output=$(chronyc tracking 2>/dev/null) || return 2
  if grep -Eiq '^[[:space:]]*Leap status[[:space:]]*:[[:space:]]*Normal[[:space:]]*$' <<<"$output"; then
    return 0
  fi
  return 1
}

time_sync_timesyncd_status() {
  local synchronized
  command -v timedatectl >/dev/null 2>&1 || return 2
  synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || return 2
  case "${synchronized,,}" in
    yes|true|1) return 0 ;;
    no|false|0) return 1 ;;
    *) return 2 ;;
  esac
}

time_sync_detect_provider() {
  TIME_SYNC_PROVIDER=unknown
  TIME_SYNC_SERVICE=''
  TIME_SYNC_STATUS=unknown
  TIME_SYNC_CONFLICT=0
  local chrony_service='' timesyncd_service='' chrony_active=0 timesyncd_active=0
  local chrony_sync=2 timesyncd_sync=2
  chrony_service=$(time_sync_chrony_service_name 2>/dev/null || true)
  timesyncd_service=$(time_sync_timesyncd_service_name 2>/dev/null || true)
  if [[ -n "$chrony_service" ]] && service_is_active "$chrony_service" >/dev/null 2>&1; then chrony_active=1; fi
  if [[ -n "$timesyncd_service" ]] && service_is_active "$timesyncd_service" >/dev/null 2>&1; then timesyncd_active=1; fi
  if [[ -n "$chrony_service" ]]; then
    if time_sync_chrony_status; then chrony_sync=0; else chrony_sync=$?; fi
  fi
  if [[ -n "$timesyncd_service" ]]; then
    if time_sync_timesyncd_status; then timesyncd_sync=0; else timesyncd_sync=$?; fi
  fi

  if (( chrony_active == 1 && timesyncd_active == 1 )); then
    TIME_SYNC_CONFLICT=1
    warn '检测到 chrony/chronyd 与 systemd-timesyncd 同时运行；拒绝自动停用任一系统 Provider。'
    return 0
  fi
  if (( chrony_sync == 0 )); then
    TIME_SYNC_PROVIDER=chrony
    TIME_SYNC_SERVICE=$chrony_service
    TIME_SYNC_STATUS=synchronized
  elif (( timesyncd_sync == 0 )); then
    TIME_SYNC_PROVIDER=systemd-timesyncd
    TIME_SYNC_SERVICE=$timesyncd_service
    TIME_SYNC_STATUS=synchronized
  elif (( chrony_active == 1 )); then
    TIME_SYNC_PROVIDER=chrony
    TIME_SYNC_SERVICE=$chrony_service
    TIME_SYNC_STATUS=unsynchronized
  elif (( timesyncd_active == 1 )); then
    TIME_SYNC_PROVIDER=systemd-timesyncd
    TIME_SYNC_SERVICE=$timesyncd_service
    TIME_SYNC_STATUS=unsynchronized
  elif [[ -n "$chrony_service" ]]; then
    TIME_SYNC_PROVIDER=chrony
    TIME_SYNC_SERVICE=$chrony_service
  elif [[ -n "$timesyncd_service" ]]; then
    TIME_SYNC_PROVIDER=systemd-timesyncd
    TIME_SYNC_SERVICE=$timesyncd_service
  fi
}

time_sync_timezone() {
  local timezone
  if command -v timedatectl >/dev/null 2>&1 \
    && timezone=$(timedatectl show -p Timezone --value 2>/dev/null) \
    && [[ -n "$timezone" ]]; then
    printf '%s' "$timezone"
  else
    date '+%Z'
  fi
}

time_sync_collect_status() {
  TIME_SYNC_LOCAL=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unknown')
  TIME_SYNC_UTC=$(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || printf 'unknown')
  TIME_SYNC_TIMEZONE=$(time_sync_timezone 2>/dev/null || printf 'unknown')
  time_sync_detect_provider || return 1
  TIME_SYNC_SINGBOX_NTP=false
  TIME_SYNC_SYSTEM_ENABLED=true
  if [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]]; then
    TIME_SYNC_SINGBOX_NTP=$(jq -r '.time_sync.singbox_ntp_enabled // true' "$MANAGER_STATE" 2>/dev/null || printf false)
    TIME_SYNC_SYSTEM_ENABLED=$(jq -r '.time_sync.system_sync_enabled // true' "$MANAGER_STATE" 2>/dev/null || printf true)
  fi
  [[ "$TIME_SYNC_SINGBOX_NTP" == true || "$TIME_SYNC_SINGBOX_NTP" == false ]] || TIME_SYNC_SINGBOX_NTP=false
  [[ "$TIME_SYNC_SYSTEM_ENABLED" == true || "$TIME_SYNC_SYSTEM_ENABLED" == false ]] || TIME_SYNC_SYSTEM_ENABLED=true
}

time_sync_record_status() {
  [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]] || return 0
  time_sync_collect_status || return 1
  local current now updated record_sync=${1:-0} installed_by_rem=false
  current=$(time_sync_state_json) || return 1
  now=$(timestamp_iso) || return 1
  if [[ "${TIME_SYNC_INSTALLED_BY_REM:-0}" == 1 ]]; then installed_by_rem=true; fi
  updated=$(jq --arg provider "$TIME_SYNC_PROVIDER" \
    --arg service "$TIME_SYNC_SERVICE" \
    --arg status "$TIME_SYNC_STATUS" \
    --arg now "$now" \
    --argjson installed "$installed_by_rem" \
    --argjson record_sync "$record_sync" \
    '.provider=$provider | .service_name=$service | .last_status=$status | .last_checked_at=$now
     | if $installed then .installed_by_rem=true else . end
     | if $record_sync == 1 and $status == "synchronized" then .last_sync_at=$now else . end' \
    <<<"$current") || return 1
  time_sync_validate_settings_json "$updated" || return 1
  manager_state_set_json time_sync "$updated"
}

time_sync_package_installed() {
  local package=$1
  case "${PACKAGE_MANAGER:-}" in
    apt-get) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf|yum) rpm -q "$package" >/dev/null 2>&1 ;;
    apk) apk info -e "$package" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

time_sync_install_package() {
  local package=$1
  if time_sync_package_installed "$package"; then
    return 0
  fi
  case "${PACKAGE_MANAGER:-}" in
    apt-get)
      (
        umask 022
        trap apt_source_override_cleanup EXIT
        export DEBIAN_FRONTEND=noninteractive
        apt_update_or_die
        local -a apt_options=()
        if [[ -n "${APT_SOURCE_OVERRIDE:-}" ]]; then
          apt_options=(-o "Dir::Etc::sourcelist=$APT_SOURCE_OVERRIDE" -o 'Dir::Etc::sourceparts=-')
        fi
        apt-get "${apt_options[@]}" install -y --no-install-recommends --no-upgrade "$package"
      ) || return 1
      ;;
    dnf) dnf -y install "$package" || return 1 ;;
    yum) yum -y install "$package" || return 1 ;;
    apk) apk add --no-cache "$package" || return 1 ;;
    *) return 1 ;;
  esac
  TIME_SYNC_INSTALLED_BY_REM=1
}

time_sync_install_provider() {
  local package
  if [[ "$HOST_OS_ID" == debian || "$HOST_OS_ID" == ubuntu ]]; then
    if [[ "$INIT_SYSTEM" == systemd ]]; then
      package=systemd-timesyncd
      if time_sync_install_package "$package"; then
        time_sync_detect_provider
        [[ "$TIME_SYNC_PROVIDER" == systemd-timesyncd ]] && return 0
        # A successful package install must not be followed by a second NTP
        # daemon install merely because the provider could not be queried.
        # Refuse closed here; the caller can report the ambiguous host state
        # and the user can resolve it without creating a daemon conflict.
        error 'systemd-timesyncd 已安装，但无法可靠确认其 Provider 状态；拒绝再安装 chrony 以避免多个 NTP daemon 冲突。'
        return 1
      fi
    fi
    time_sync_install_package chrony || return 1
  elif [[ "$HOST_OS_ID" == centos || "$HOST_OS_ID" == almalinux || "$HOST_OS_ID" == alpine ]]; then
    time_sync_install_package chrony || return 1
  else
    return 1
  fi
  time_sync_detect_provider
  [[ "$TIME_SYNC_PROVIDER" == chrony || "$TIME_SYNC_PROVIDER" == systemd-timesyncd ]]
}

time_sync_enable_provider() {
  local provider=${TIME_SYNC_PROVIDER:-unknown} service=${TIME_SYNC_SERVICE:-}
  [[ "$provider" == chrony || "$provider" == systemd-timesyncd ]] || return 1
  if [[ -z "$service" ]]; then
    if [[ "$provider" == chrony ]]; then service=$(time_sync_chrony_service_name 2>/dev/null || true); fi
    if [[ "$provider" == systemd-timesyncd ]]; then service=systemd-timesyncd; fi
  fi
  [[ -n "$service" ]] || return 1
  TIME_SYNC_SERVICE=$service
  if [[ "$provider" == systemd-timesyncd ]]; then
    if command -v timedatectl >/dev/null 2>&1; then
      timedatectl set-ntp true >/dev/null 2>&1 || true
    fi
    service_start "$service" >/dev/null 2>&1 || return 1
    # systemd-timesyncd is commonly a static unit controlled by timedatectl;
    # a static unit is still enabled in the operational sense.
  else
    service_enable "$service" >/dev/null 2>&1 || return 1
    service_start "$service" >/dev/null 2>&1 || return 1
  fi
  return 0
}

time_sync_prepare_provider() {
  TIME_SYNC_INSTALLED_BY_REM=0
  if ! time_sync_detect_provider; then
    warn '系统时间同步 Provider 状态查询失败；将继续使用 sing-box NTP fallback。'
    return 0
  fi
  if (( TIME_SYNC_CONFLICT != 0 )); then
    warn '检测到多个系统 NTP daemon 同时运行；不擅自停用任一服务，将继续使用现有服务和 sing-box NTP fallback。'
    return 0
  fi
  if [[ "$TIME_SYNC_PROVIDER" == unknown ]]; then
    if ! time_sync_install_provider; then
      warn '没有可用的系统时间同步 Provider，或无法安装/识别合适实现；将继续使用 sing-box NTP fallback。'
      return 0
    fi
  fi
  if ! time_sync_detect_provider; then
    warn '系统时间同步 Provider 安装后无法可靠查询；将继续使用 sing-box NTP fallback。'
    return 0
  fi
  if (( TIME_SYNC_CONFLICT != 0 )); then
    warn 'Provider 安装后检测到多个系统 NTP daemon 同时运行；不擅自停用任一服务。'
    return 0
  fi
  if ! time_sync_enable_provider; then
    warn "无法启用系统时间同步服务：${TIME_SYNC_SERVICE:-unknown}；将继续使用 sing-box NTP fallback。"
    return 0
  fi
  if ! time_sync_collect_status; then
    warn '系统时间同步状态读取失败；将继续使用 sing-box NTP fallback。'
    return 0
  fi
  if [[ "$TIME_SYNC_STATUS" == synchronized ]]; then
    success "系统时间同步已确认（${TIME_SYNC_PROVIDER}）。"
  else
    warn "系统时间同步服务已启用，但当前状态为 ${TIME_SYNC_STATUS}；将继续依赖 sing-box NTP fallback。"
  fi
}

time_sync_print_status() {
  time_sync_collect_status || return 1
  local provider_display service_display system_display singbox_display
  provider_display=${TIME_SYNC_PROVIDER:-unknown}
  service_display=${TIME_SYNC_SERVICE:-未检测到}
  if [[ "$TIME_SYNC_SYSTEM_ENABLED" != true ]]; then
    system_display='✗ Disabled'
  else
    case "$TIME_SYNC_STATUS" in
      synchronized) system_display='✓ Synchronized' ;;
      unsynchronized) system_display='⚠ Unsynchronized' ;;
      *) system_display='? Unknown' ;;
    esac
  fi
  if [[ "$TIME_SYNC_SINGBOX_NTP" == true ]]; then singbox_display='✓ Enabled'; else singbox_display='✗ Disabled'; fi
  printf '本地时间：%s\nUTC：%s\n时区：%s\n系统同步服务：%s（%s）\n系统 NTP：%s\nsing-box NTP：%s\n' \
    "$TIME_SYNC_LOCAL" "$TIME_SYNC_UTC" "$TIME_SYNC_TIMEZONE" "$service_display" "$provider_display" "$system_display" "$singbox_display"
  if [[ "$TIME_SYNC_CONFLICT" == 1 ]]; then
    warn '检测到多个系统 NTP daemon 同时运行；请先停用其中一个，REM 不会擅自接管。'
  elif [[ "$TIME_SYNC_STATUS" != synchronized && "$TIME_SYNC_SINGBOX_NTP" != true ]]; then
    warn '系统时间未同步且 sing-box NTP 已禁用；Shadowsocks 2022 可能因时间偏差无法连接。'
  elif [[ "$TIME_SYNC_STATUS" != synchronized ]]; then
    warn '系统时间同步尚未确认；sing-box NTP fallback 当前已启用。'
  fi
  return 0
}

time_sync_health_warning() {
  if ! time_sync_collect_status; then
    warn '时间同步辅助状态：系统 Provider 状态未知，sing-box NTP fallback 仍由配置决定。'
    return 0
  fi
  if [[ "$TIME_SYNC_SYSTEM_ENABLED" != true || "$TIME_SYNC_STATUS" != synchronized || "$TIME_SYNC_SINGBOX_NTP" != true ]]; then
    warn "时间同步辅助状态：系统=${TIME_SYNC_STATUS}，Provider=${TIME_SYNC_PROVIDER:-unknown}，sing-box NTP=${TIME_SYNC_SINGBOX_NTP}。"
  fi
  return 0
}

time_sync_ss_creation_check() {
  if ! time_sync_collect_status; then
    warn '无法读取服务器系统时间同步状态；将按未知处理。'
    if [[ -f "$MANAGER_STATE" && ! -L "$MANAGER_STATE" ]] \
      && [[ "$(jq -r '.time_sync.singbox_ntp_enabled // true' "$MANAGER_STATE" 2>/dev/null || printf false)" == true ]]; then
      info 'sing-box 内置 NTP：已启用，继续创建节点。'
      return 0
    fi
    prompt_yes_no '系统 NTP 未确认且 sing-box NTP 已禁用，仍要继续创建 Shadowsocks 2022 节点？' n
    return $?
  fi
  if [[ "$TIME_SYNC_STATUS" == synchronized ]]; then
    success '时间同步正常。'
    return 0
  fi
  warn '无法确认服务器系统时间已经同步；Shadowsocks 2022 对时间偏差敏感，服务器与客户端时间偏差过大可能无法连接。'
  if [[ "$TIME_SYNC_SINGBOX_NTP" == true ]]; then
    info 'sing-box 内置 NTP：已启用，继续创建节点。'
    return 0
  fi
  prompt_yes_no '系统 NTP 未确认且 sing-box NTP 已禁用，仍要继续创建 Shadowsocks 2022 节点？' n
}

time_sync_sync_now() {
  time_sync_detect_provider || return 1
  (( TIME_SYNC_CONFLICT == 0 )) || return 1
  if [[ "$TIME_SYNC_PROVIDER" == unknown ]]; then
    time_sync_prepare_provider || return 1
    time_sync_detect_provider || return 1
  fi
  local before after delta=0
  before=$(date +%s) || return 1
  case "$TIME_SYNC_PROVIDER" in
    chrony)
      command -v chronyc >/dev/null 2>&1 || return 1
      if ! chronyc -a makestep >/dev/null 2>&1; then
        chronyc makestep >/dev/null 2>&1 || return 1
      fi
      ;;
    systemd-timesyncd)
      command -v timedatectl >/dev/null 2>&1 || return 1
      timedatectl set-ntp true >/dev/null 2>&1 || return 1
      service_restart "${TIME_SYNC_SERVICE:-systemd-timesyncd}" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  local attempt
  for ((attempt=0; attempt<10; attempt++)); do
    time_sync_detect_provider || return 1
    [[ "$TIME_SYNC_STATUS" == synchronized ]] && break
    sleep 1
  done
  time_sync_detect_provider || return 1
  [[ "$TIME_SYNC_STATUS" == synchronized ]] || {
    time_sync_record_status 0 >/dev/null 2>&1 || true
    return 1
  }
  after=$(date +%s) || return 1
  if [[ "$before" =~ ^-?[0-9]+$ && "$after" =~ ^-?[0-9]+$ ]]; then
    delta=$((after - before))
    (( delta < 0 )) && delta=$((-delta))
  fi
  time_sync_record_status 1 || return 1
  if (( delta >= ${TIME_SYNC_LARGE_STEP_SECONDS:-30} )); then
    local active_status=0
    if declare -F singbox_is_active >/dev/null 2>&1; then
      singbox_is_active || active_status=$?
      if (( active_status == 0 )); then
        info "系统时间校正幅度约 ${delta} 秒，正在重新建立 sing-box 协议状态。"
        singbox_restart || return 1
        singbox_health_check "$NODES_FILE" || return 1
      elif (( active_status != 1 )); then
        return 1
      fi
    fi
  fi
}

time_sync_apply_settings_transaction() {
  local candidate_time_sync=$1 candidate_config active_status=0
  time_sync_validate_settings_json "$candidate_time_sync" || return 1
  manager_state_set_json time_sync "$candidate_time_sync" || return 1
  candidate_config=$(runtime_temp_file config.time-sync) || return 1
  if ! generate_singbox_config "$NODES_FILE" "$candidate_config" \
    || ! singbox_check_config "$candidate_config" >/dev/null 2>&1; then
    rm -f -- "$candidate_config"
    return 1
  fi
  atomic_json_write "$candidate_config" "$SING_BOX_CONFIG" 600 || { rm -f -- "$candidate_config"; return 1; }
  rm -f -- "$candidate_config" || return 1
  singbox_is_active || active_status=$?
  if (( active_status == 0 )); then
    singbox_restart || return 1
    singbox_health_check "$NODES_FILE" || return 1
  elif (( active_status == 1 )); then
    singbox_check_config "$SING_BOX_CONFIG" >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  time_sync_record_status 0 || return 1
}

time_sync_check_action() {
  time_sync_print_status
}

time_sync_sync_action() {
  acquire_manager_lock
  system_mutation_transaction_begin time_sync_sync || return 1
  time_sync_sync_now || return 1
  system_mutation_transaction_commit || return 1
  success '系统时间同步完成。'
}

time_sync_server_action() {
  acquire_manager_lock
  local server current candidate
  printf '请输入 NTP Server（域名或 IP，当前默认回车保留）：\n> '
  IFS= read -r server || return 1
  if [[ -z "$server" ]]; then
    return 0
  fi
  time_sync_validate_server "$server" || { warn 'NTP Server 格式无效。'; return 1; }
  current=$(time_sync_state_json) || return 1
  candidate=$(jq --arg server "$server" '.ntp_server=$server' <<<"$current") || return 1
  system_mutation_transaction_begin time_sync_server || return 1
  time_sync_apply_settings_transaction "$candidate" || return 1
  system_mutation_transaction_commit || return 1
  success "NTP Server 已更新为：$server"
}

time_sync_toggle_action() {
  acquire_manager_lock
  local current enabled candidate
  current=$(time_sync_state_json) || return 1
  enabled=$(jq -r '.singbox_ntp_enabled' <<<"$current") || return 1
  if [[ "$enabled" == true ]]; then
    prompt_yes_no '确认禁用 sing-box NTP？系统 NTP 未同步时 SS2022 可能无法连接。' n || return 0
    candidate=$(jq '.singbox_ntp_enabled=false' <<<"$current") || return 1
  else
    candidate=$(jq '.singbox_ntp_enabled=true' <<<"$current") || return 1
  fi
  system_mutation_transaction_begin time_sync_toggle || return 1
  time_sync_apply_settings_transaction "$candidate" || return 1
  system_mutation_transaction_commit || return 1
  if [[ "$enabled" == true ]]; then success 'sing-box NTP 已禁用。'; else success 'sing-box NTP 已启用。'; fi
}

time_sync_menu() {
  local choice
  while true; do
    time_sync_collect_status || true
    printf '\n时间同步\n系统时间：%s\nUTC：%s\n时区：%s\n系统 NTP：%s\n同步服务：%s\nsing-box NTP：%s\nNTP Server：%s\n\n1. 立即检查时间\n2. 立即同步时间\n3. 修改 NTP Server\n4. 启用 / 禁用 sing-box NTP\n5. 查看时间同步状态\n0. 返回\n> ' \
      "${TIME_SYNC_LOCAL:-unknown}" "${TIME_SYNC_UTC:-unknown}" "${TIME_SYNC_TIMEZONE:-unknown}" \
      "${TIME_SYNC_STATUS:-unknown}" "${TIME_SYNC_SERVICE:-${TIME_SYNC_PROVIDER:-unknown}}" \
      "${TIME_SYNC_SINGBOX_NTP:-unknown}" "$(time_sync_state_json | jq -r '.ntp_server' 2>/dev/null || printf unknown)"
    IFS= read -r choice || return 1
    case "$choice" in
      1) run_menu_action time_sync_check_action ;;
      2) run_menu_action time_sync_sync_action ;;
      3) run_menu_action time_sync_server_action ;;
      4) run_menu_action time_sync_toggle_action ;;
      5) time_sync_print_status ;;
      0) return 0 ;;
      *) warn '无效选项。' ;;
    esac
  done
}
