#!/usr/bin/env bash
# Operating system, package manager, kernel capability and interface helpers.

detect_host() {
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版：缺少 /etc/os-release。"
  # shellcheck disable=SC1091
  source /etc/os-release
  HOST_OS_ID=${ID:-unknown}
  HOST_OS_VERSION=${VERSION_ID:-unknown}
  HOST_OS_NAME=${PRETTY_NAME:-$HOST_OS_ID}

  case "$HOST_OS_ID" in
    debian)
      case "$HOST_OS_VERSION" in
        11*|12*) ;;
        *) die "仅支持 Debian 11/12，当前为 $HOST_OS_NAME。" ;;
      esac
      PACKAGE_MANAGER=apt-get
      INIT_SYSTEM=systemd
      ;;
    ubuntu)
      PACKAGE_MANAGER=apt-get
      INIT_SYSTEM=systemd
      ;;
    centos)
      PACKAGE_MANAGER=$(command -v dnf >/dev/null 2>&1 && printf dnf || printf yum)
      INIT_SYSTEM=systemd
      ;;
    almalinux)
      PACKAGE_MANAGER=$(command -v dnf >/dev/null 2>&1 && printf dnf || printf yum)
      INIT_SYSTEM=systemd
      ;;
    alpine)
      PACKAGE_MANAGER=apk
      INIT_SYSTEM=openrc
      ;;
    *)
      die "不支持的发行版：$HOST_OS_NAME。支持 Debian 11/12、Ubuntu、CentOS、AlmaLinux、Alpine Linux。"
      ;;
  esac

  HOST_ARCH_RAW=$(uname -m)
  case "$HOST_ARCH_RAW" in
    x86_64|amd64) HOST_ARCH=amd64 ;;
    aarch64|arm64) HOST_ARCH=arm64 ;;
    *) die "不支持的 CPU 架构：$HOST_ARCH_RAW。优先支持 amd64 与 arm64。" ;;
  esac

  (( BASH_VERSINFO[0] >= 4 )) || die "Bash 版本过低，需要 Bash 4 或更高版本。"
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd/systemctl，无法管理 sing-box 服务。"
  elif [[ "$INIT_SYSTEM" == openrc ]]; then
    command -v apk >/dev/null 2>&1 || die "Alpine Linux 缺少 apk，无法安全安装依赖。"
  fi
  export HOST_OS_ID HOST_OS_VERSION HOST_OS_NAME PACKAGE_MANAGER INIT_SYSTEM HOST_ARCH_RAW HOST_ARCH
}

package_list() {
  cat <<'EOF'
ca-certificates
curl
gzip
jq
openssl
python3
tar
util-linux
coreutils
findutils
EOF
  if [[ "$PACKAGE_MANAGER" == apt-get ]]; then
    printf '%s\n' iproute2 procps qrencode
  elif [[ "$PACKAGE_MANAGER" == dnf ]]; then
    printf '%s\n' iproute iproute-tc procps-ng qrencode
  elif [[ "$PACKAGE_MANAGER" == yum ]]; then
    # CentOS 7 commonly ships tc inside iproute rather than a separate
    # iproute-tc package. Keep yum compatible with that layout.
    printf '%s\n' iproute procps-ng qrencode
  else
    printf '%s\n' bash iproute2 openrc
  fi
}

install_packages() {
  detect_host
  local -a packages=()
  mapfile -t packages < <(package_list)
  case "$PACKAGE_MANAGER" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      dnf -y install "${packages[@]}" || {
        warn "当前 DNF 仓库未提供 qrencode，尝试启用发行版提供的 EPEL 仓库。"
        dnf -y install epel-release
        dnf -y install "${packages[@]}"
      }
      ;;
    yum)
      yum -y install "${packages[@]}" || {
        warn "当前 YUM 仓库未提供 qrencode，尝试启用发行版提供的 EPEL 仓库。"
        yum -y install epel-release
        yum -y install "${packages[@]}"
      }
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      if ! command -v sysctl >/dev/null 2>&1; then
        apk add --no-cache procps-ng \
          || apk add --no-cache procps \
          || die 'Alpine 软件源未提供 procps-ng/procps，无法安装 sysctl。'
      fi
      if ! command -v qrencode >/dev/null 2>&1; then
        if ! apk add --no-cache libqrencode-tools; then
          # Older Alpine branches provided the executable from libqrencode.
          apk add --no-cache libqrencode || die 'Alpine 软件源未提供 qrencode；请确认已启用与当前版本匹配的官方 community 仓库。'
        fi
      fi
      ;;
    *) die "未识别的包管理器：$PACKAGE_MANAGER。" ;;
  esac
  require_cmd awk base64 curl date find flock grep install ip jq mktemp openssl python3 qrencode readlink sed sha256sum shuf ss sysctl tar tc tr uname wc
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    require_cmd systemctl journalctl
  else
    require_cmd rc-service rc-update supervise-daemon
    [[ -x /sbin/openrc-run ]] || die "Alpine Linux 缺少 /sbin/openrc-run，无法安装 OpenRC 服务。"
    [[ -d /run/openrc ]] || die "当前 Alpine 系统并非由 OpenRC 启动，无法可靠管理长期服务。"
  fi
}

manager_state_set_json() {
  local key=$1
  local value_json=$2
  [[ -f "$MANAGER_STATE" ]] || die "manager.json 不存在，无法写入系统能力状态。"
  jq -e --arg key "$key" --argjson value "$value_json" '.[$key] = $value' "$MANAGER_STATE" \
    | atomic_json_from_stdin "$MANAGER_STATE" 600
}

manager_state_get() {
  local key=$1
  local fallback=${2:-null}
  if [[ -f "$MANAGER_STATE" ]]; then
    jq -r --arg key "$key" --arg fallback "$fallback" 'if has($key) and .[$key] != null then .[$key] else $fallback end' "$MANAGER_STATE"
  else
    printf '%s\n' "$fallback"
  fi
}

sysctl_read() {
  local key=$1
  sysctl -n "$key" 2>/dev/null || true
}

configure_bbr() {
  require_cmd sysctl
  local current allowed previous
  current=$(sysctl_read net.ipv4.tcp_congestion_control)
  allowed=$(sysctl_read net.ipv4.tcp_allowed_congestion_control)
  if [[ "$current" == bbr ]]; then
    success "BBR 已启用，无需重复修改。"
    manager_state_set_json bbr_supported true
    manager_state_set_json bbr_enabled true
    return 0
  fi
  if [[ " $allowed " != *" bbr "* ]]; then
    warn "当前内核不支持 BBR（允许的拥塞控制：${allowed:-未知}），不会升级内核。"
    manager_state_set_json bbr_supported false
    manager_state_set_json bbr_enabled false
    return 0
  fi

  previous=$(jq -r '.bbr_previous // empty' "$MANAGER_STATE" 2>/dev/null || true)
  [[ -n "$previous" ]] || manager_state_set_json bbr_previous "$(jq -Rn --arg value "$current" '$value')"
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  local sysctl_file='/etc/sysctl.d/99-ss-manager.conf'
  if [[ -e "$sysctl_file" ]] && ! grep -q '^# Managed by Ss2022$' "$sysctl_file"; then
    warn "$sysctl_file 已存在且不是本项目创建，已开启当前会话 BBR，但不覆盖该文件。"
  else
    ensure_dir /etc/sysctl.d 755
    {
      printf '%s\n' '# Managed by Ss2022'
      printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr'
    } >"$RUNTIME_DIR/bbr.sysctl.tmp"
    install -m 644 -- "$RUNTIME_DIR/bbr.sysctl.tmp" "$sysctl_file"
    rm -f -- "$RUNTIME_DIR/bbr.sysctl.tmp"
    manager_state_set_json bbr_persistent true
  fi
  manager_state_set_json bbr_supported true
  manager_state_set_json bbr_enabled true
  success "已启用 BBR。"
}

configure_tcp_fast_open_kernel() {
  require_cmd sysctl
  local proc='/proc/sys/net/ipv4/tcp_fastopen'
  if [[ ! -r "$proc" ]]; then
    warn "当前内核未提供 TCP Fast Open 参数，已跳过。"
    manager_state_set_json tfo_kernel_supported false
    manager_state_set_json tfo_kernel_enabled false
    return 0
  fi
  local current new
  current=$(cat "$proc")
  [[ "$current" =~ ^[0-9]+$ ]] || {
    warn "无法解析 TCP Fast Open 内核参数，已跳过。"
    manager_state_set_json tfo_kernel_supported false
    manager_state_set_json tfo_kernel_enabled false
    return 0
  }
  if (( (current & 2) != 0 )); then
    success "TCP Fast Open 服务端内核支持已启用。"
    manager_state_set_json tfo_kernel_supported true
    manager_state_set_json tfo_kernel_enabled true
    return 0
  fi
  new=$((current | 2))
  if ! sysctl -w "net.ipv4.tcp_fastopen=$new" >/dev/null; then
    warn "当前内核拒绝开启 TCP Fast Open，已跳过。"
    manager_state_set_json tfo_kernel_supported false
    manager_state_set_json tfo_kernel_enabled false
    return 0
  fi
  manager_state_set_json tfo_kernel_supported true
  manager_state_set_json tfo_kernel_enabled true
  manager_state_set_json tfo_kernel_previous "$current"

  local sysctl_file='/etc/sysctl.d/99-ss-manager.conf'
  if [[ -e "$sysctl_file" ]] && ! grep -q '^# Managed by Ss2022$' "$sysctl_file"; then
    warn "$sysctl_file 已存在且不是本项目创建，已开启当前会话 TFO，但不覆盖该文件。"
  else
    ensure_dir /etc/sysctl.d 755
    if [[ -f "$sysctl_file" ]]; then
      grep -v '^net\.ipv4\.tcp_fastopen=' "$sysctl_file" >"$RUNTIME_DIR/tfo.sysctl.tmp" || true
    else
      printf '%s\n' '# Managed by Ss2022' >"$RUNTIME_DIR/tfo.sysctl.tmp"
    fi
    printf '%s\n' "net.ipv4.tcp_fastopen=$new" >>"$RUNTIME_DIR/tfo.sysctl.tmp"
    install -m 644 -- "$RUNTIME_DIR/tfo.sysctl.tmp" "$sysctl_file"
    rm -f -- "$RUNTIME_DIR/tfo.sysctl.tmp"
    manager_state_set_json tfo_persistent true
  fi
}

detect_listen_mode() {
  local ipv6_available='false'
  local bind_v6_only='0'
  if [[ -s /proc/net/if_inet6 ]] && [[ "$(sysctl_read net.ipv6.conf.all.disable_ipv6)" != 1 ]]; then
    ipv6_available='true'
    bind_v6_only=$(sysctl_read net.ipv6.bindv6only)
  fi

  if [[ "$ipv6_available" == true && "$bind_v6_only" != 1 ]]; then
    manager_state_set_json listen_mode '"dual"'
    manager_state_set_json listen_address '"::"'
  elif [[ "$ipv6_available" == true ]]; then
    manager_state_set_json listen_mode '"family-specific"'
    manager_state_set_json listen_address '"::"'
    warn "系统启用了 IPv6 但 bindv6only=1，节点会按家庭选择 IPv4/IPv6 监听地址。"
  else
    manager_state_set_json listen_mode '"ipv4"'
    manager_state_set_json listen_address '"0.0.0.0"'
  fi
}

detect_traffic_interfaces() {
  require_cmd ip jq
  local -a interfaces=()
  local interface
  while IFS= read -r interface; do
    [[ -n "$interface" ]] && interfaces+=("$interface")
  done < <(ip -o route show default 2>/dev/null | awk '$1 == "default" { for (i=1;i<=NF;i++) if ($i == "dev") print $(i+1) }')
  while IFS= read -r interface; do
    [[ -n "$interface" ]] && interfaces+=("$interface")
  done < <(ip -o -6 route show default 2>/dev/null | awk '$1 == "default" { for (i=1;i<=NF;i++) if ($i == "dev") print $(i+1) }')

  if ((${#interfaces[@]} == 0)); then
    warn "没有检测到默认路由接口，流量统计/限速将在接口配置后可用。"
  fi
  printf '%s\n' "${interfaces[@]}" | awk 'NF && !seen[$0]++' \
    | jq -Rsc '{schema_version:1,interfaces:(split("\n")|map(select(length>0)))}' \
    | atomic_json_from_stdin "$INTERFACES_FILE" 600
}

traffic_interfaces() {
  if [[ -f "$INTERFACES_FILE" ]]; then
    jq -r '.interfaces[]?' "$INTERFACES_FILE"
  fi
}

discover_public_ip() {
  local family=$1
  local endpoint candidate
  local -a endpoints=()
  if [[ "$family" == ipv4 ]]; then
    endpoints=("${PUBLIC_IPV4_ENDPOINTS[@]}")
  else
    endpoints=("${PUBLIC_IPV6_ENDPOINTS[@]}")
  fi
  for endpoint in "${endpoints[@]}"; do
    candidate=$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --max-time 5 -- "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n "$candidate" ]] || continue
    local detected_type
    detected_type=$(validate_address "$candidate" 2>/dev/null || true)
    if [[ "$detected_type" == "$family" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

node_listener_for_family() {
  local address_type=$1
  local mode
  mode=$(manager_state_get listen_mode ipv4)
  case "$mode" in
    dual) printf '::' ;;
    ipv4) printf '0.0.0.0' ;;
    family-specific)
      [[ "$address_type" == ipv6 ]] && printf '::' || printf '0.0.0.0'
      ;;
    *) printf '0.0.0.0' ;;
  esac
}

restore_kernel_settings_on_uninstall() {
  local sysctl_file='/etc/sysctl.d/99-ss-manager.conf'
  if [[ -f "$sysctl_file" ]] && grep -q '^# Managed by Ss2022$' "$sysctl_file"; then
    rm -f -- "$sysctl_file"
    if command -v sysctl >/dev/null 2>&1; then
      sysctl --system >/dev/null 2>&1 || true
    fi
  fi
  local previous
  previous=$(manager_state_get bbr_previous '')
  if [[ -n "$previous" && "$previous" != null ]] && command -v sysctl >/dev/null 2>&1; then
    sysctl -w "net.ipv4.tcp_congestion_control=$previous" >/dev/null 2>&1 || true
  fi
  previous=$(manager_state_get tfo_kernel_previous '')
  if [[ -n "$previous" && "$previous" != null ]] && command -v sysctl >/dev/null 2>&1; then
    sysctl -w "net.ipv4.tcp_fastopen=$previous" >/dev/null 2>&1 || true
  fi
}
