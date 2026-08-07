#!/usr/bin/env bash
# Common primitives shared by install.sh and the installed manager.

set -Eeuo pipefail
IFS=$'\n\t'

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$COMMON_DIR/.." && pwd)"

DEFAULTS_FILE="${SS_MANAGER_DEFAULTS_FILE:-$PROJECT_ROOT/config/defaults.conf}"
if [[ -r "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

MANAGER_VERSION="${MANAGER_VERSION:-1.0.0}"
PROGRAM_DIR="${PROGRAM_DIR:-/opt/ss-manager}"
CONFIG_DIR="${CONFIG_DIR:-/etc/ss-manager}"
DATA_DIR="${DATA_DIR:-/var/lib/ss-manager}"
RUNTIME_DIR="${RUNTIME_DIR:-/run/ss-manager}"
BACKUP_DIR="${BACKUP_DIR:-$CONFIG_DIR/backups}"
SING_BOX_BINARY="${SING_BOX_BINARY:-/usr/local/bin/sing-box}"
SING_BOX_CONFIG="${SING_BOX_CONFIG:-/etc/sing-box/config.json}"
SING_BOX_SERVICE="${SING_BOX_SERVICE:-sing-box.service}"

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
  load_json_or_default "$COUNTERS_FILE" '{"schema_version":1,"nodes":{}}'
  load_json_or_default "$INTERFACES_FILE" '{"schema_version":1,"interfaces":[]}'
}

atomic_json_write() {
  local source_file=$1
  local destination=$2
  local mode=${3:-600}
  local destination_dir
  destination_dir=$(dirname -- "$destination")
  ensure_dir "$destination_dir" 700
  jq -e . "$source_file" >/dev/null 2>&1 || die "拒绝写入无效 JSON：$source_file"
  local temporary="${destination}.tmp.$$.$RANDOM"
  install -m "$mode" -- "$source_file" "$temporary"
  chmod "$mode" -- "$temporary"
  mv -f -- "$temporary" "$destination"
}

atomic_json_from_stdin() {
  local destination=$1
  local mode=${2:-600}
  local temporary="${destination}.tmp.$$.$RANDOM"
  ensure_dir "$(dirname -- "$destination")" 700
  cat >"$temporary"
  jq -e . "$temporary" >/dev/null 2>&1 || {
    rm -f -- "$temporary"
    die "拒绝写入无效 JSON：$destination"
  }
  install -m "$mode" -- "$temporary" "$destination"
  rm -f -- "$temporary"
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
    printf '%s\n> ' "$prompt"
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
    printf '%s\n> ' "$prompt"
    IFS= read -r -s first || die "读取输入失败。"
    printf '\n请再次输入以确认：\n> '
    IFS= read -r -s second || die "读取输入失败。"
    printf '\n'
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
  [[ "$command_path" == "/usr/local/bin/rem" ]] && [[ -L "$command_path" || -f "$command_path" ]] && grep -q 'ss-manager' "$command_path" 2>/dev/null
}

cleanup_path() {
  local path=$1
  [[ -n "$path" && "$path" != '/' && "$path" != '.' ]] || die "拒绝清理危险路径。"
  rm -f -- "$path"
}

trap_cleanup_file() {
  local path=$1
  trap 'rm -f -- "$path"' RETURN
}
