#!/usr/bin/env bash
# Common primitives shared by install.sh and the installed manager.
# Module constants are consumed by scripts that source this file.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$COMMON_DIR/.." && pwd)"

DEFAULTS_FILE="${SS_MANAGER_DEFAULTS_FILE:-$PROJECT_ROOT/config/defaults.conf}"
if [[ -r "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

VERSION_FILE="${SS_MANAGER_VERSION_FILE:-$PROJECT_ROOT/VERSION}"
if [[ -r "$VERSION_FILE" ]]; then
  IFS= read -r MANAGER_VERSION <"$VERSION_FILE" || true
  MANAGER_VERSION=${MANAGER_VERSION//$'\r'/}
fi
MANAGER_VERSION="${MANAGER_VERSION:-1.0.4}"
[[ "$MANAGER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid manager VERSION: %s\n' "$MANAGER_VERSION" >&2
  exit 1
}
PROGRAM_DIR="${PROGRAM_DIR:-/opt/ss-manager}"
CONFIG_DIR="${CONFIG_DIR:-/etc/ss-manager}"
DATA_DIR="${DATA_DIR:-/var/lib/ss-manager}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ss-manager}"
BACKUP_DIR="${BACKUP_DIR:-$CONFIG_DIR/backups}"
SING_BOX_BINARY="${SING_BOX_BINARY:-/usr/local/bin/sing-box}"
SING_BOX_CONFIG="${SING_BOX_CONFIG:-/etc/sing-box/config.json}"
SING_BOX_SERVICE="${SING_BOX_SERVICE:-sing-box}"

MANAGER_STATE="$CONFIG_DIR/manager.json"
NODES_FILE="$DATA_DIR/nodes.json"
TRAFFIC_FILE="$DATA_DIR/traffic.json"
HISTORY_FILE="$DATA_DIR/traffic-history.json"
COUNTERS_FILE="$DATA_DIR/tc-counters.json"
INTERFACES_FILE="$DATA_DIR/interfaces.json"
TRANSACTION_LOCK="$RUNTIME_DIR/manager.lock"
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_TRAFFIC_SERVICE="ss-manager-traffic.service"
SYSTEMD_TRAFFIC_TIMER="ss-manager-traffic.timer"
OPENRC_DIR="/etc/init.d"
OPENRC_TRAFFIC_SERVICE="ss-manager-traffic"

RED=""
GREEN=""
YELLOW=""
BLUE=""
RESET=""
if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  RESET=$'\033[0m'
fi

timestamp_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
timestamp_compact() { date -u '+%Y%m%d-%H%M%S'; }
timestamp_epoch() { date +%s; }

info() { printf '%s\n' "${BLUE}[INFO]${RESET} $*"; }
success() { printf '%s\n' "${GREEN}[OK]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
error() { printf '%s\n' "${RED}[ERROR]${RESET} $*" >&2; }
die() { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  error "执行失败（行 ${line_no}，退出码 ${exit_code}）。当前状态不会被静默提交。"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "此操作必须以 root 身份执行。"
}

require_cmd() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少必要命令：$command_name。请先运行 install.sh。"
  done
}

ensure_dir() {
  local path=$1
  local mode=${2:-700}
  install -d -m "$mode" -- "$path"
}

ensure_runtime_dirs() {
  ensure_dir "$CONFIG_DIR" 700
  ensure_dir "$DATA_DIR" 700
  ensure_dir "$RUNTIME_DIR" 700
  ensure_dir "$BACKUP_DIR" 700
  ensure_dir "$(dirname -- "$SING_BOX_CONFIG")" 755
}

acquire_manager_lock() {
  require_cmd flock
  ensure_dir "$RUNTIME_DIR" 700
  # Keep FD 9 open for the lifetime of this process.
  exec 9>"$TRANSACTION_LOCK"
  if ! flock -n 9; then
    die "已有 ss-manager 操作正在执行，请稍后重试。"
  fi
  MANAGER_LOCK_HELD=1
}

release_manager_lock() {
  if [[ "${MANAGER_LOCK_HELD:-0}" == 1 ]]; then
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
    MANAGER_LOCK_HELD=0
  fi
}

load_json_or_default() {
  local path=$1
  local default_json=$2
  if [[ ! -f "$path" ]]; then
    printf '%s\n' "$default_json" >"$path"
    chmod 600 -- "$path"
  fi
  jq -e . "$path" >/dev/null 2>&1 || die "JSON 数据损坏：$path。请使用备份恢复。"
}

initialize_state_files() {
  ensure_runtime_dirs
  load_json_or_default "$NODES_FILE" '{"schema_version":1,"nodes":[]}'
  load_json_or_default "$TRAFFIC_FILE" '{"schema_version":1,"nodes":{}}'
  load_json_or_default "$HISTORY_FILE" '{"schema_version":1,"cycles":{}}'
  load_json_or_default "$INTERFACES_FILE" '{"schema_version":1,"interfaces":[]}'
}

validate_installed_state_files() {
  local path
  for path in "$MANAGER_STATE" "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE"; do
    [[ -f "$path" ]] || die "已有安装缺少必要状态文件：$path。为避免清空节点或流量，修复已停止；请先从 $BACKUP_DIR 恢复。"
    jq -e . "$path" >/dev/null 2>&1 || die "JSON 数据损坏：$path。请使用备份恢复。"
  done
  jq -e 'type == "object" and .schema_version == 1' "$MANAGER_STATE" >/dev/null 2>&1 \
    || die 'manager.json 结构无效；请先使用备份恢复。'
  jq -e '.schema_version == 1 and (.nodes | type == "array")' "$NODES_FILE" >/dev/null 2>&1 \
    || die 'nodes.json 结构无效；请先使用备份恢复。'
  jq -e '.schema_version == 1 and (.nodes | type == "object")' "$TRAFFIC_FILE" >/dev/null 2>&1 \
    || die 'traffic.json 结构无效；请先使用备份恢复。'
  jq -e '.schema_version == 1 and (.cycles | type == "object")' "$HISTORY_FILE" >/dev/null 2>&1 \
    || die 'traffic-history.json 结构无效；请先使用备份恢复。'
}

atomic_json_write() {
  local source_file=$1
  local destination=$2
  local mode=${3:-600}
  local destination_dir
  destination_dir=$(dirname -- "$destination")
  ensure_dir "$destination_dir" 700 || return 1
  jq -e . "$source_file" >/dev/null 2>&1 || die "拒绝写入无效 JSON：$source_file"
  local temporary="${destination}.tmp.$$.$RANDOM"
  install -m "$mode" -- "$source_file" "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod "$mode" -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
}

atomic_json_from_stdin() {
  local destination=$1
  local mode=${2:-600}
  local temporary="${destination}.tmp.$$.$RANDOM"
  ensure_dir "$(dirname -- "$destination")" 700 || return 1
  cat >"$temporary" || { rm -f -- "$temporary"; return 1; }
  jq -e . "$temporary" >/dev/null 2>&1 || {
    rm -f -- "$temporary"
    die "拒绝写入无效 JSON：$destination"
  }
  chmod "$mode" -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
}

json_value() {
  local file=$1
  local filter=$2
  jq -er "$filter" "$file"
}

json_value_or() {
  local file=$1
  local filter=$2
  local fallback=$3
  jq -r --arg fallback "$fallback" "try ($filter) catch \$fallback" "$file"
}

trim_spaces() {
  local value=$1
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

read_nonempty() {
  local prompt=$1
  local value
  while true; do
    # Callers use command substitution to capture only the entered value.
    # Keep interactive prompts off stdout so they cannot become part of it.
    printf '%s\n> ' "$prompt" >&2
    IFS= read -r value || die "读取输入失败。"
    value=$(trim_spaces "$value")
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "输入不能为空。"
  done
}

read_secret_confirmed() {
  local prompt=$1
  local first second
  while true; do
    printf '%s\n> ' "$prompt" >&2
    IFS= read -r -s first || die "读取输入失败。"
    printf '\n请再次输入以确认：\n> ' >&2
    IFS= read -r -s second || die "读取输入失败。"
    printf '\n' >&2
    [[ -n "$first" ]] || { warn "密钥不能为空。"; continue; }
    [[ "$first" == "$second" ]] || { warn "两次输入不一致。"; continue; }
    printf '%s' "$first"
    return 0
  done
}

prompt_yes_no() {
  local prompt=$1
  local default=${2:-n}
  local answer
  while true; do
    if [[ "$default" == y ]]; then
      printf '%s [Y/n] ' "$prompt"
    else
      printf '%s [y/N] ' "$prompt"
    fi
    IFS= read -r answer || die "读取输入失败。"
    answer=$(tr '[:upper:]' '[:lower:]' <<<"$(trim_spaces "$answer")")
    [[ -z "$answer" ]] && answer=$default
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

validate_name() {
  local value=$1
  [[ -n "$value" ]] || return 1
  [[ ${#value} -le 64 ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 1
  [[ "$value" != *$'\033'* ]] || return 1
  [[ "$value" != */* && "$value" != *\\* ]] || return 1
  ! LC_ALL=C grep -q '[[:cntrl:]]' <<<"$value"
}

validate_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_limit_mbps() {
  local value=$1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v v="$value" 'BEGIN { exit !(v >= 0 && v <= 1000000) }'
}

validate_reset_day() {
  local value=$1
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 28 ))
}

validate_address() {
  local value=$1
  python3 - "$value" <<'PY'
import ipaddress
import re
import sys

value = sys.argv[1]
try:
    address = ipaddress.ip_address(value)
    print("ipv4" if address.version == 4 else "ipv6")
    raise SystemExit(0)
except ValueError:
    pass

if len(value) > 253 or value.endswith(".") or ".." in value:
    raise SystemExit(1)
labels = value.split(".")
if any(not label or len(label) > 63 for label in labels):
    raise SystemExit(1)
if any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label) for label in labels):
    raise SystemExit(1)
print("domain")
PY
}

validate_base64_key() {
  local value=$1
  local expected_bytes=$2
  [[ "$value" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  local decoded_size
  decoded_size=$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c)
  [[ "$decoded_size" -eq "$expected_bytes" ]]
}

generate_random_key() {
  local key_bytes=$1
  local generated=''
  if [[ -x "$SING_BOX_BINARY" ]]; then
    generated=$("$SING_BOX_BINARY" generate rand --base64 "$key_bytes" 2>/dev/null || true)
  fi
  if [[ -z "$generated" ]]; then
    require_cmd openssl base64
    generated=$(openssl rand -base64 "$key_bytes" | tr -d '\r\n')
  fi
  validate_base64_key "$generated" "$key_bytes" || die "安全随机密钥生成失败，已拒绝创建节点。"
  printf '%s' "$generated"
}

method_key_bytes() {
  case "$1" in
    2022-blake3-aes-128-gcm) printf '16' ;;
    2022-blake3-aes-256-gcm) printf '32' ;;
    *) return 1 ;;
  esac
}

validate_method() {
  [[ "$1" == '2022-blake3-aes-128-gcm' || "$1" == '2022-blake3-aes-256-gcm' ]]
}

bytes_from_gb() {
  local value=$1
  jq -nr --arg value "$value" '
    if ($value | test("^[0-9]+([.][0-9]+)?$"))
    then (($value | tonumber) * 1000000000 | floor)
    else error("invalid GB")
    end
  '
}

format_bytes() {
  local bytes=${1:-0}
  awk -v value="$bytes" '
    function human(v, unit) {
      split("B KiB MiB GiB TiB PiB", units, " ")
      unit = 1
      while (v >= 1024 && unit < 6) { v /= 1024; unit++ }
      if (unit == 1) return sprintf("%d %s", v, units[unit])
      return sprintf("%.2f %s", v, units[unit])
    }
    BEGIN { print human(value) }
  '
}

format_mbps() {
  local value=${1:-0}
  [[ "$value" == 0 || "$value" == 0.0 ]] && printf '不限速' || printf '%s Mbps' "$value"
}

status_label() {
  case "$1" in
    enabled) printf '运行中' ;;
    disabled_manual) printf '手动停用' ;;
    disabled_quota) printf '超额停用' ;;
    disabled_error) printf '错误停用' ;;
    *) printf '%s' "$1" ;;
  esac
}

url_encode() {
  jq -rn --arg value "$1" '$value|@uri'
}

is_command_from_manager() {
  local command_path=$1
  [[ "$command_path" == "/usr/local/bin/rem" ]] || return 1
  if [[ -L "$command_path" ]]; then
    [[ "$(readlink -f -- "$command_path" 2>/dev/null || true)" == "$PROGRAM_DIR/ss-manager.sh" ]]
    return
  fi
  [[ -f "$command_path" ]] || return 1
  grep -Fqx "exec $PROGRAM_DIR/ss-manager.sh \"\$@\"" "$command_path" 2>/dev/null
}

cleanup_path() {
  local path=$1
  [[ -n "$path" && "$path" != '/' && "$path" != '.' ]] || die "拒绝清理危险路径。"
  rm -f -- "$path"
}

assert_standard_destructive_paths() {
  [[ "$PROGRAM_DIR" == /opt/ss-manager ]] || die "拒绝对非标准程序目录执行递归替换/卸载：$PROGRAM_DIR"
  [[ "$CONFIG_DIR" == /etc/ss-manager ]] || die "拒绝对非标准配置目录执行递归卸载：$CONFIG_DIR"
  [[ "$DATA_DIR" == /var/lib/ss-manager ]] || die "拒绝对非标准数据目录执行递归卸载：$DATA_DIR"
  [[ "$RUNTIME_DIR" == /run/ss-manager ]] || die "拒绝使用非标准运行目录：$RUNTIME_DIR"
  [[ "$BACKUP_DIR" == /etc/ss-manager/backups ]] || die "拒绝对非标准备份目录执行递归卸载：$BACKUP_DIR"
  [[ "$SING_BOX_BINARY" == /usr/local/bin/sing-box ]] || die "拒绝替换或删除非标准 sing-box 路径：$SING_BOX_BINARY"
  [[ "$SING_BOX_CONFIG" == /etc/sing-box/config.json ]] || die "拒绝替换或删除非标准 sing-box 配置：$SING_BOX_CONFIG"
}

trap_cleanup_file() {
  local path=$1
  trap 'rm -f -- "$path"' RETURN
}
