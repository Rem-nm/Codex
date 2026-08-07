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
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    printf '%s/%s' "$SYSTEMD_DIR" "$(service_systemd_unit_name "$name")"
  else
    printf '%s/%s' "$OPENRC_DIR" "$(service_openrc_name "$name")"
  fi
}

service_definition_is_managed() {
  local path
  path=$(service_definition_path "$1")
  [[ -f "$path" ]] && grep -q '^# Managed by Ss2022$' "$path"
}

service_exists() {
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl cat "$(service_systemd_unit_name "$name")" >/dev/null 2>&1
  else
    [[ -x "$(service_definition_path "$name")" ]]
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
  local name=$1
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    systemctl is-active --quiet "$(service_systemd_unit_name "$name")"
  else
    rc-service "$(service_openrc_name "$name")" status >/dev/null 2>&1
  fi
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
  local name=$1 path
  path=$(service_definition_path "$name")
  if service_definition_is_managed "$name"; then
    rm -f -- "$path"
    service_manager_reload
  fi
}

check_manager_maintenance_service_files() {
  local source destination unit
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for unit in "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"; do
      destination=$(service_definition_path "$unit")
      if [[ -f "$destination" ]] && ! service_definition_is_managed "$unit"; then
        die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
      fi
      source="$PROGRAM_DIR/systemd/$unit"
      [[ -f "$source" ]] || die "缺少 systemd 模板：$source"
    done
  else
    destination=$(service_definition_path "$OPENRC_TRAFFIC_SERVICE")
    if [[ -f "$destination" ]] && ! service_definition_is_managed "$OPENRC_TRAFFIC_SERVICE"; then
      die "$destination 已存在且不是本项目创建，拒绝静默覆盖。"
    fi
    source="$PROGRAM_DIR/openrc/$OPENRC_TRAFFIC_SERVICE"
    [[ -f "$source" ]] || die "缺少 OpenRC 模板：$source"
    [[ -x "$PROGRAM_DIR/openrc/ss-manager-traffic-loop.sh" ]] || die '缺少 OpenRC 流量维护循环。'
  fi
}

install_manager_maintenance_service_files() {
  local source destination unit
  check_manager_maintenance_service_files
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for unit in "$SYSTEMD_TRAFFIC_SERVICE" "$SYSTEMD_TRAFFIC_TIMER"; do
      destination=$(service_definition_path "$unit")
      source="$PROGRAM_DIR/systemd/$unit"
      install -m 644 -- "$source" "$destination"
    done
  else
    destination=$(service_definition_path "$OPENRC_TRAFFIC_SERVICE")
    source="$PROGRAM_DIR/openrc/$OPENRC_TRAFFIC_SERVICE"
    install -m 755 -- "$source" "$destination"
  fi
  service_manager_reload
}

enable_manager_maintenance_service() {
  local name
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    name=$SYSTEMD_TRAFFIC_TIMER
  else
    name=$OPENRC_TRAFFIC_SERVICE
  fi
  service_enable "$name" >/dev/null
  if ! service_is_active "$name"; then
    service_start "$name" >/dev/null
  fi
}

remove_manager_maintenance_service_files() {
  local name
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    for name in "$SYSTEMD_TRAFFIC_TIMER" "$SYSTEMD_TRAFFIC_SERVICE"; do
      service_stop "$name" >/dev/null 2>&1 || true
      service_disable "$name" >/dev/null 2>&1 || true
      service_remove_managed_definition "$name"
    done
  else
    name=$OPENRC_TRAFFIC_SERVICE
    service_stop "$name" >/dev/null 2>&1 || true
    service_disable "$name" >/dev/null 2>&1 || true
    service_remove_managed_definition "$name"
  fi
  service_manager_reload >/dev/null 2>&1 || true
}
