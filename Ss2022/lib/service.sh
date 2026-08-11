#!/usr/bin/env bash
# Init-system abstraction for systemd and Alpine OpenRC.

service_validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "无效的服务名称：$1"
}

service_systemd_unit_name() {
  local name=$1
  service_validate_name "$name"
  case "$name" in
    *.service|*.timer) printf '%s' "$name" ;;
    *) printf '%s.service' "$name" ;;
  esac
}

service_openrc_name() {
  local name=$1
  service_validate_name "$name"
  name=${name%.service}
  name=${name%.timer}
  printf '%s' "$name"
}

service_definition_path() {
  local name=$1 unit
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    unit=$(service_systemd_unit_name "$name") || return 1
    printf '%s/%s' "$SYSTEMD_DIR" "$unit"
  else
    unit=$(service_openrc_name "$name") || return 1
    printf '%s/%s' "$OPENRC_DIR" "$unit"
  fi
}

service_definition_is_managed() {
  local path
  path=$(service_definition_path "$1") || return 1
  [[ -f "$path" && ! -L "$path" && -O "$path" ]] \
    && grep -q '^# Managed by Ss2022$' "$path"
}

service_definition_path_present() {
  local path
  path=$(service_definition_path "$1") || return 1
  [[ -e "$path" || -L "$path" ]]
}

service_exists() {
  local name=$1 path unit output state status=0
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    unit=$(service_systemd_unit_name "$name") || return 2
    # systemd 219 (still shipped by CentOS 7) supports property filtering but
    # predates `systemctl --value`.  Parse the single `LoadState=...` record so
    # the same fail-closed tri-state contract works on every supported host.
    output=$(systemctl show --property=LoadState "$unit" 2>/dev/null) || status=$?
    [[ "$output" == LoadState=* && "$output" != *$'\n'* ]] || return 2
    state=${output#LoadState=}
    # A known not-found load state proves absence.  Empty output or a failed
    # query is operationally ambiguous and must never be treated as absence by
    # ownership, rollback or uninstall code.
    [[ "$state" != not-found ]] || return 1
    (( status == 0 )) && [[ -n "$state" ]] || return 2
    return 0
  else
    path=$(service_definition_path "$name") || return 1
    [[ -x "$path" ]]
  fi
}

service_manager_reload() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl daemon-reload
  fi
}

service_enable() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl enable "$(service_systemd_unit_name "$name")"
  else
    rc-update add "$(service_openrc_name "$name")" default
  fi
}

service_is_enabled() {
  local name=$1 state output status=0
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    state=$(systemctl is-enabled "$(service_systemd_unit_name "$name")" 2>/dev/null) || status=$?
    case "$state" in
      enabled|enabled-runtime|linked|linked-runtime|alias) return 0 ;;
      disabled|static|indirect|generated|transient|masked|masked-runtime) return 1 ;;
      not-found) return 1 ;;
      '')
        # Debian 11/systemd 247 can return an empty result for a unit that
        # does not exist.  Prove absence through LoadState before treating
        # the empty is-enabled response as an operationally unknown state.
        local presence_status=0
        service_exists "$name" || presence_status=$?
        (( presence_status == 1 )) && return 1
        return 2
        ;;
      *)
        # Keep fail-closed behavior for unexpected states, but do not turn a
        # nonzero is-enabled status into a false ownership conflict when the
        # unit is demonstrably absent.
        if (( status != 0 )); then
          local presence_status=0
          service_exists "$name" || presence_status=$?
          (( presence_status == 1 )) && return 1
        fi
        return 2
        ;;
    esac
  else
    output=$(rc-update show default 2>/dev/null) || return 2
    awk -v service="$(service_openrc_name "$name")" '$1 == service {found=1} END {exit !found}' <<<"$output"
  fi
}

service_disable() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl disable "$(service_systemd_unit_name "$name")"
  else
    rc-update del "$(service_openrc_name "$name")" default
  fi
}

service_start() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl start "$(service_systemd_unit_name "$name")"
  else
    rc-service "$(service_openrc_name "$name")" start
  fi
}

service_stop() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl stop "$(service_systemd_unit_name "$name")"
  else
    rc-service "$(service_openrc_name "$name")" stop
  fi
}

service_restart() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl restart "$(service_systemd_unit_name "$name")"
  else
    rc-service "$(service_openrc_name "$name")" restart
  fi
}

service_is_active() {
  local name=$1 state status=0
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    state=$(systemctl is-active "$(service_systemd_unit_name "$name")" 2>/dev/null) || status=$?
    case "$state" in
      active|reloading|activating|deactivating) return 0 ;;
      inactive|failed) return 1 ;;
      unknown)
        local presence_status=0
        service_exists "$name" || presence_status=$?
        (( presence_status == 1 )) && return 1
        return 2
        ;;
      '') return 2 ;;
      *) return 2 ;;
    esac
  else
    rc-service "$(service_openrc_name "$name")" status >/dev/null 2>&1 || status=$?
    case "$status" in
      0) return 0 ;;
      3) return 1 ;;
      *)
        local presence_status=0
        service_exists "$name" || presence_status=$?
        (( presence_status == 1 )) && return 1
        return 2
        ;;
    esac
  fi
}

service_confirm_inactive() {
  local status=0
  service_is_active "$1" || status=$?
  (( status == 1 ))
}

service_confirm_disabled() {
  local status=0
  service_is_enabled "$1" || status=$?
  (( status == 1 ))
}

service_status() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl status "$(service_systemd_unit_name "$name")" --no-pager || true
  else
    rc-service "$(service_openrc_name "$name")" status || true
  fi
}

service_recent_logs() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    journalctl -u "$(service_systemd_unit_name "$name")" --output cat -n 80 --no-pager || true
  else
    info 'OpenRC 不提供 journald；以下显示当前服务状态。sing-box 访问日志仍保持关闭。'
    service_status "$name"
  fi
}

service_remove_managed_definition() {
  local name=$1 path presence_status=0
  path=$(service_definition_path "$name") || return 1
  if service_definition_path_present "$name"; then
    service_definition_is_managed "$name" || {
      error "拒绝删除不受 Ss2022 管理的服务定义：$path"
      return 1
    }
    rm -f -- "$path" || return 1
    service_manager_reload || return 1
  else
    service_exists "$name" || presence_status=$?
    case "$presence_status" in
      0)
        error "同名服务来自其他系统路径，拒绝删除或假定已清理：$name"
        return 1
        ;;
      1) ;;
      *)
        error "无法可靠查询同名服务是否仍存在：$name"
        return 1
        ;;
    esac
  fi
}

check_manager_maintenance_service_files() {
  local source destination unit presence_status
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for unit in "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"; do
      destination=$(service_definition_path "$unit") || return 1
      if service_definition_path_present "$unit" && ! service_definition_is_managed "$unit"; then
        die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
      fi
      if ! service_definition_path_present "$unit"; then
        presence_status=0
        service_exists "$unit" || presence_status=$?
        (( presence_status != 2 )) || die "无法可靠查询同名维护服务 $unit；拒绝在状态未知时接管。"
        (( presence_status != 0 )) || die "系统已有同名维护服务 $unit，且来自其他系统路径；拒绝接管。"
      fi
      source="$PROGRAM_DIR/systemd/$unit"
      [[ -f "$source" && ! -L "$source" ]] || die "缺少常规 systemd 模板或模板为符号链接：$source"
    done
  else
    destination=$(service_definition_path "$OPENRC_TRAFFIC_SERVICE") || return 1
    if service_definition_path_present "$OPENRC_TRAFFIC_SERVICE" && ! service_definition_is_managed "$OPENRC_TRAFFIC_SERVICE"; then
      die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
    fi
    source="$PROGRAM_DIR/openrc/$OPENRC_TRAFFIC_SERVICE"
    [[ -f "$source" && ! -L "$source" ]] || die "缺少常规 OpenRC 模板或模板为符号链接：$source"
    [[ -f "$PROGRAM_DIR/openrc/ss-manager-traffic-loop.sh" && ! -L "$PROGRAM_DIR/openrc/ss-manager-traffic-loop.sh" \
      && -x "$PROGRAM_DIR/openrc/ss-manager-traffic-loop.sh" ]] || die '缺少常规 OpenRC 流量维护循环或文件为符号链接。'
  fi
}

install_manager_maintenance_service_files() {
  local source destination unit
  check_manager_maintenance_service_files
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for unit in "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"; do
      destination=$(service_definition_path "$unit") || return 1
      source="$PROGRAM_DIR/systemd/$unit"
      atomic_file_write "$source" "$destination" 644 755 || return 1
    done
  else
    destination=$(service_definition_path "$OPENRC_TRAFFIC_SERVICE") || return 1
    source="$PROGRAM_DIR/openrc/$OPENRC_TRAFFIC_SERVICE"
    atomic_file_write "$source" "$destination" 755 755 || return 1
  fi
  service_manager_reload || return 1
}

enable_manager_maintenance_service() {
  local name active_status=0 enabled_status=0
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    name=$SYSTEMD_TRAFFIC_TIMER
  else
    name=$OPENRC_TRAFFIC_SERVICE
  fi
  service_enable "$name" >/dev/null || return 1
  service_is_enabled "$name" || enabled_status=$?
  (( enabled_status == 0 )) || return 1
  service_is_active "$name" || active_status=$?
  (( active_status != 2 )) || return 1
  if (( active_status == 1 )); then
    service_start "$name" >/dev/null || return 1
    active_status=0
    service_is_active "$name" || active_status=$?
    (( active_status == 0 )) || return 1
  fi
}

remove_manager_maintenance_service_files() {
  local name active_status enabled_status presence_status
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for name in "$SYSTEMD_TRAFFIC_TIMER" "$SYSTEMD_TRAFFIC_SERVICE"; do
      if ! service_definition_path_present "$name"; then
        presence_status=0
        service_exists "$name" || presence_status=$?
        (( presence_status != 2 )) || { error "无法可靠查询同名服务是否存在：$name"; return 1; }
        (( presence_status != 0 )) || { error "检测到同名但不受 Ss2022 管理的服务：$name"; return 1; }
        continue
      fi
      service_definition_is_managed "$name" \
        || { error "拒绝停止或删除不受 Ss2022 管理的服务：$name"; return 1; }
      active_status=0
      service_is_active "$name" || active_status=$?
      (( active_status != 2 )) || return 1
      if (( active_status == 0 )); then
        service_stop "$name" >/dev/null 2>&1 || return 1
        active_status=0
        service_is_active "$name" || active_status=$?
        (( active_status == 1 )) || return 1
      fi
      enabled_status=0
      service_is_enabled "$name" || enabled_status=$?
      (( enabled_status != 2 )) || return 1
      if (( enabled_status == 0 )); then
        service_disable "$name" >/dev/null 2>&1 || return 1
        enabled_status=0
        service_is_enabled "$name" || enabled_status=$?
        (( enabled_status == 1 )) || return 1
      fi
      service_remove_managed_definition "$name" || return 1
    done
  else
    name=$OPENRC_TRAFFIC_SERVICE
    if ! service_definition_path_present "$name"; then
      presence_status=0
      service_exists "$name" || presence_status=$?
      (( presence_status != 2 )) || { error "无法可靠查询同名服务是否存在：$name"; return 1; }
      (( presence_status != 0 )) || { error "检测到同名但不受 Ss2022 管理的服务：$name"; return 1; }
      service_manager_reload >/dev/null 2>&1 || return 1
      return 0
    fi
    service_definition_is_managed "$name" \
      || { error "拒绝停止或删除不受 Ss2022 管理的服务：$name"; return 1; }
    active_status=0
    service_is_active "$name" || active_status=$?
    (( active_status != 2 )) || return 1
    if (( active_status == 0 )); then
      service_stop "$name" >/dev/null 2>&1 || return 1
      active_status=0
      service_is_active "$name" || active_status=$?
      (( active_status == 1 )) || return 1
    fi
    enabled_status=0
    service_is_enabled "$name" || enabled_status=$?
    (( enabled_status != 2 )) || return 1
    if (( enabled_status == 0 )); then
      service_disable "$name" >/dev/null 2>&1 || return 1
      enabled_status=0
      service_is_enabled "$name" || enabled_status=$?
      (( enabled_status == 1 )) || return 1
    fi
    service_remove_managed_definition "$name" || return 1
  fi
  service_manager_reload >/dev/null 2>&1 || return 1
}
