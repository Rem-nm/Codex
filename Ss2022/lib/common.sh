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
MANAGER_VERSION="${MANAGER_VERSION:-1.0.20}"
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
MANAGED_SYSCTL_FILE="${SS_MANAGER_SYSCTL_FILE:-/etc/sysctl.d/99-ss-manager.conf}"

MANAGER_STATE="$CONFIG_DIR/manager.json"
NODES_FILE="$DATA_DIR/nodes.json"
TRAFFIC_FILE="$DATA_DIR/traffic.json"
HISTORY_FILE="$DATA_DIR/traffic-history.json"
COUNTERS_FILE="$DATA_DIR/tc-counters.json"
INTERFACES_FILE="$DATA_DIR/interfaces.json"
TRANSACTION_LOCK="$RUNTIME_DIR/manager.lock"
STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
MAX_SAFE_JSON_INTEGER=9007199254740991
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
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || {
      error "拒绝把非普通目录或符号链接用作管理目录：$path"
      return 1
    }
  fi
  install -d -m "$mode" -- "$path" || return 1
  [[ -d "$path" && ! -L "$path" ]]
}

ensure_runtime_dirs() {
  ensure_dir "$CONFIG_DIR" 700 || return 1
  ensure_dir "$DATA_DIR" 700 || return 1
  ensure_dir "$RUNTIME_DIR" 700 || return 1
  ensure_dir "$BACKUP_DIR" 700 || return 1
  ensure_dir "$(dirname -- "$SING_BOX_CONFIG")" 755 || return 1
}

runtime_temp_file() {
  local prefix=${1:-temporary}
  [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  ensure_dir "$RUNTIME_DIR" 700 || return 1
  local path
  path=$(mktemp "$RUNTIME_DIR/${prefix}.XXXXXXXX") || return 1
  [[ -f "$path" && ! -L "$path" ]] || { rm -f -- "$path"; return 1; }
  chmod 600 -- "$path" || { rm -f -- "$path"; return 1; }
  printf '%s' "$path"
}

runtime_temp_dir() {
  local prefix=${1:-temporary}
  [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  ensure_dir "$RUNTIME_DIR" 700 || return 1
  local path
  path=$(mktemp -d "$RUNTIME_DIR/${prefix}.XXXXXXXX") || return 1
  [[ -d "$path" && ! -L "$path" ]] || { rm -rf -- "$path"; return 1; }
  chmod 700 -- "$path" || { rm -rf -- "$path"; return 1; }
  printf '%s' "$path"
}

acquire_manager_lock() {
  require_cmd flock
  ensure_dir "$RUNTIME_DIR" 700 || return 1
  if [[ -e "$TRANSACTION_LOCK" || -L "$TRANSACTION_LOCK" ]]; then
    [[ -f "$TRANSACTION_LOCK" && ! -L "$TRANSACTION_LOCK" && -O "$TRANSACTION_LOCK" ]] \
      || die "manager 锁路径不是 root 所有的常规文件：$TRANSACTION_LOCK"
  fi
  # Keep FD 9 open for the lifetime of this process.
  exec 9>>"$TRANSACTION_LOCK" || return 1
  if [[ ! -f "$TRANSACTION_LOCK" || -L "$TRANSACTION_LOCK" || ! -O "$TRANSACTION_LOCK" ]] \
    || ! chmod 600 -- "$TRANSACTION_LOCK"; then
    exec 9>&-
    return 1
  fi
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
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -f "$path" && ! -L "$path" ]] || {
      error "JSON 状态路径不是常规文件：$path"
      return 1
    }
  else
    printf '%s\n' "$default_json" | atomic_json_from_stdin "$path" 600 || return 1
  fi
  jq -e . "$path" >/dev/null 2>&1 || { error "JSON 数据损坏：$path。请使用备份恢复。"; return 1; }
}

initialize_state_files() {
  ensure_runtime_dirs || return 1
  load_json_or_default "$NODES_FILE" '{"schema_version":1,"nodes":[]}' || return 1
  load_json_or_default "$TRAFFIC_FILE" '{"schema_version":1,"nodes":{}}' || return 1
  load_json_or_default "$HISTORY_FILE" '{"schema_version":1,"cycles":{}}' || return 1
  load_json_or_default "$INTERFACES_FILE" '{"schema_version":1,"interfaces":[]}' || return 1
}

validate_installed_state_files() {
  local path
  for path in "$MANAGER_STATE" "$NODES_FILE" "$TRAFFIC_FILE" "$HISTORY_FILE" "$INTERFACES_FILE"; do
    [[ -f "$path" && ! -L "$path" ]] || die "已有安装缺少常规状态文件或路径为符号链接：$path。为避免清空节点或流量，修复已停止；请先从 $BACKUP_DIR 恢复。"
    jq -e . "$path" >/dev/null 2>&1 || die "JSON 数据损坏：$path。请使用备份恢复。"
  done
  validate_manager_state_semantic "$MANAGER_STATE" || die 'manager.json 语义无效；请先使用备份恢复。'
  validate_nodes_file_semantic "$NODES_FILE" || die 'nodes.json 语义无效；请先使用备份恢复。'
  # Versions before 1.0.4 kept the tc kernel baseline in a separate
  # tc-counters.json file.  Keep accepting that exact, structurally safe
  # legacy form long enough for the install transaction to migrate it.  Do
  # not write anything here: the transaction must snapshot the old state
  # before the migration so a later failure can restore it byte-for-byte.
  LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION=0
  if ! validate_traffic_file_semantic "$TRAFFIC_FILE" "$NODES_FILE"; then
    if traffic_legacy_file_semantic "$TRAFFIC_FILE" "$NODES_FILE"; then
      LEGACY_TRAFFIC_STATE_NEEDS_MIGRATION=1
      warn '检测到旧版 traffic.json，将在安装事务中补齐内核计数基线；累计流量和节点数据不会被覆盖。'
    else
      die 'traffic.json 语义或节点关联无效；请先使用备份恢复。'
    fi
  fi
  validate_history_file_semantic "$HISTORY_FILE" || die 'traffic-history.json 语义无效；请先使用备份恢复。'
  validate_interfaces_file_semantic "$INTERFACES_FILE" || die 'interfaces.json 语义无效；请先使用备份恢复。'
  local plan_file="$DATA_DIR/bandwidth-plan.json"
  if [[ -e "$plan_file" || -L "$plan_file" ]]; then
    [[ -f "$plan_file" && ! -L "$plan_file" ]] \
      || die 'bandwidth-plan.json 不是常规文件；无法安全证明 tc 规则所有权。'
    validate_bandwidth_plan_semantic "$plan_file" || die 'bandwidth-plan.json 语义无效；无法安全证明 tc 规则所有权。'
    validate_bandwidth_plan_against_state "$plan_file" "$NODES_FILE" "$INTERFACES_FILE" \
      || die 'bandwidth-plan.json 与节点或接口状态不一致；无法安全证明 tc 规则所有权。'
    jq -e --slurpfile manager "$MANAGER_STATE" '
      (($manager[0].tc_pref // .pref) == .pref)
      and (($manager[0].tc_ipv6_pref // (.pref + 1)) == (.pref + 1))
    ' "$plan_file" >/dev/null 2>&1 \
      || die 'bandwidth-plan.json 与 manager tc 优先级状态不一致；拒绝继续修改规则。'
  fi
}

durable_sync_path() {
  local path=$1
  [[ -e "$path" && ! -L "$path" ]] || return 1
  python3 - "$path" <<'PY'
import os
import sys

path = sys.argv[1]
if os.name == "nt":
    raise SystemExit(0)
flags = os.O_RDONLY
if hasattr(os, "O_DIRECTORY") and os.path.isdir(path):
    flags |= os.O_DIRECTORY
fd = os.open(path, flags)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

durable_sync_tree() {
  local root=$1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  python3 - "$root" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
if os.name == "nt":
    raise SystemExit(0)

def sync_regular(path):
    mode = os.lstat(path).st_mode
    if not stat.S_ISREG(mode):
        return
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

directories = []
for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    # Do not traverse directory symlinks. Their directory entry is made
    # durable when the containing real directory is fsynced.
    dirnames[:] = [
        name for name in dirnames
        if not stat.S_ISLNK(os.lstat(os.path.join(current, name)).st_mode)
    ]
    directories.append(current)
    for name in filenames:
        sync_regular(os.path.join(current, name))

flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
for directory in reversed(directories):
    fd = os.open(directory, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

atomic_replace_regular_file() {
  local temporary=$1 destination=$2
  [[ -f "$temporary" && ! -L "$temporary" ]] || {
    error "拒绝原子替换非普通临时文件：$temporary"
    return 1
  }
  # POSIX/BusyBox mv does not provide GNU mv's -T option.  Explicitly reject
  # a directory (including a symlink resolving to one), otherwise mv would
  # place the temporary file inside it instead of replacing the target path.
  [[ ! -d "$destination" ]] || {
    error "拒绝用文件替换目录：$destination"
    return 1
  }
  mv -f -- "$temporary" "$destination"
}

atomic_move_directory_to_absent_path() {
  local source=$1 destination=$2 source_parent destination_parent
  [[ -d "$source" && ! -L "$source" ]] || {
    error "拒绝移动非普通目录：$source"
    return 1
  }
  # The parents used by Ss2022 are root-owned.  Checking both -e and -L also
  # rejects a broken destination symlink before the same-filesystem rename.
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    error "目录发布目标已存在：$destination"
    return 1
  }
  source_parent=$(dirname -- "$source") || return 1
  destination_parent=$(dirname -- "$destination") || return 1
  [[ "$source_parent" == "$destination_parent" ]] || {
    error '拒绝跨目录执行原子目录移动。'
    return 1
  }
  mv -- "$source" "$destination"
}

atomic_json_write() {
  local source_file=$1
  local destination=$2
  local mode=${3:-600}
  local destination_dir
  destination_dir=$(dirname -- "$destination") || return 1
  ensure_dir "$destination_dir" 700 || return 1
  jq -e . "$source_file" >/dev/null 2>&1 || { error "拒绝写入无效 JSON：$source_file"; return 1; }
  local temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXXXX") || return 1
  [[ -f "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
  install -m "$mode" -- "$source_file" "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod "$mode" -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$temporary" || { rm -f -- "$temporary"; return 1; }
  atomic_replace_regular_file "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$destination_dir" || return 1
}

atomic_json_from_stdin() {
  local destination=$1
  local mode=${2:-600}
  ensure_dir "$(dirname -- "$destination")" 700 || return 1
  local temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXXXX") || return 1
  [[ -f "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
  cat >"$temporary" || { rm -f -- "$temporary"; return 1; }
  jq -e . "$temporary" >/dev/null 2>&1 || {
    rm -f -- "$temporary"
    error "拒绝写入无效 JSON：$destination"
    return 1
  }
  chmod "$mode" -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$temporary" || { rm -f -- "$temporary"; return 1; }
  atomic_replace_regular_file "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$(dirname -- "$destination")" || return 1
}

atomic_file_write() {
  local source_file=$1 destination=$2 mode=${3:-600} parent_mode=${4:-755}
  local destination_dir temporary
  destination_dir=$(dirname -- "$destination") || return 1
  ensure_dir "$destination_dir" "$parent_mode" || return 1
  temporary=$(mktemp "${destination}.tmp.XXXXXXXX") || return 1
  [[ -f "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$temporary"; return 1; }
  install -m "$mode" -- "$source_file" "$temporary" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$temporary" || { rm -f -- "$temporary"; return 1; }
  atomic_replace_regular_file "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$destination_dir" || return 1
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
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
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
  [[ "$port" =~ ^[1-9][0-9]*$ ]] || return 1
  ((${#port} <= 5)) || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_limit_mbps() {
  local value=$1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v v="$value" 'BEGIN { exit !(v >= 0 && v <= 1000000) }'
}

validate_reset_day() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  ((${#value} <= 2)) || return 1
  (( value >= 1 && value <= 28 ))
}

validate_address() {
  local value=$1
  python3 - "$value" <<'PY'
import ipaddress
import re
import sys

value = sys.argv[1]
if "%" in value:
    # Scoped IPv6 literals are interface-local and are not portable client
    # share addresses for this manager.
    raise SystemExit(1)
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

validate_manager_state_semantic() {
  local source=$1
  jq -e '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    type == "object" and .schema_version == 1
    and (.manager_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$"))
    and (.init_system == "systemd" or .init_system == "openrc")
    and (.install_completed | type == "boolean")
    and (.created_at | iso)
    and (.sing_box_version | type == "string" and (. == "" or test("^[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$")))
    and (.sing_box_binary_managed | type == "boolean")
    and ((has("sing_box_binary_sha256") | not) or
      (.sing_box_binary_sha256 | type == "string" and (. == "" or test("^[A-Fa-f0-9]{64}$"))))
    and ((.sing_box_version_lock == null) or (.sing_box_version_lock | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$")))
    and (((.listen_mode == "ipv4") and (.listen_address == "0.0.0.0"))
      or ((.listen_mode == "dual" or .listen_mode == "family-specific") and (.listen_address == "::")))
    and (. as $state | all(["tfo_kernel_supported","tfo_kernel_enabled","tfo_config_supported","bbr_supported","bbr_enabled"][];
      . as $key | ($state | has($key) | not) or ($state[$key] | type == "boolean")))
    and ((has("quota_include_unauthenticated_upload") | not) or (.quota_include_unauthenticated_upload | type == "boolean"))
    and ((has("tc_capabilities_verified") | not) or (.tc_capabilities_verified | type == "boolean"))
    and ((has("tc_capability_signature") | not) or (.tc_capability_signature | type == "string" and length <= 512))
    and ((has("tc_pref") | not) or (.tc_pref | type == "number" and floor == . and . >= 100 and . <= 65500))
    and ((has("tc_ipv6_pref") | not) or (.tc_ipv6_pref | type == "number" and floor == . and . >= 101 and . <= 65501))
    and ((((has("tc_pref") and has("tc_ipv6_pref")) | not)) or (.tc_ipv6_pref == (.tc_pref + 1)))
    and (((.tfo_kernel_enabled // false) | not) or (.tfo_kernel_supported // false))
    and (((.bbr_enabled // false) | not) or (.bbr_supported // false))
    and ((has("bbr_previous") | not) or (.bbr_previous | type == "string" and length <= 64 and test("^[A-Za-z0-9_.-]+$")))
    and ((has("tfo_kernel_previous") | not) or
      ((.tfo_kernel_previous | type == "number" and floor == . and . >= 0 and . <= 4294967295)
        or (.tfo_kernel_previous | type == "string" and test("^[0-9]{1,10}$"))))
    and (. as $state | all(["bbr_persistent","tfo_persistent"][];
      . as $key | ($state | has($key) | not) or ($state[$key] | type == "boolean")))
    and ((has("tc_clsact_interfaces") | not) or
      ((.tc_clsact_interfaces | type == "array")
        and all(.tc_clsact_interfaces[]; type == "string" and test("^[A-Za-z0-9_.-]{1,15}$"))
        and ([.tc_clsact_interfaces[]] | length == (unique | length))))
  ' "$source" >/dev/null 2>&1
}

validate_nodes_file_semantic() {
  local source=$1
  jq -e --argjson max "$MAX_SAFE_JSON_INTEGER" '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    def uint: type == "number" and . >= 0 and . <= $max and floor == .;
    def limit: type == "number" and . >= 0 and . <= 1000000;
    .schema_version == 1 and (.nodes | type == "array")
    and all(.nodes[];
      (keys | sort) == (["address","address_type","created_at","download_limit_mbps","last_reset_at","method","name","next_reset_at","node_id","password","port","quota_bytes","reset_day","status","status_reason","updated_at","upload_limit_mbps"] | sort)
      and (.node_id | type == "string" and test("^[a-f0-9]{32}$"))
      and (.name | type == "string")
      and (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm")
      and (.password | type == "string")
      and (.port | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.address | type == "string")
      and (.address_type == "ipv4" or .address_type == "ipv6" or .address_type == "domain")
      and (.status == "enabled" or .status == "disabled_manual" or .status == "disabled_quota" or .status == "disabled_error")
      and (.status_reason | type == "string" and length <= 512)
      and (.quota_bytes | uint)
      and (.reset_day | type == "number" and floor == . and . >= 1 and . <= 28)
      and (.upload_limit_mbps | limit) and (.download_limit_mbps | limit)
      and (.created_at | iso) and (.updated_at | iso) and (.last_reset_at | iso) and (.next_reset_at | iso)
      and (.created_at <= .updated_at) and (.last_reset_at < .next_reset_at)
    )
    and ([.nodes[].node_id] | length == (unique | length))
    and ([.nodes[].name | ascii_downcase] | length == (unique | length))
    and ([.nodes[].port] | length == (unique | length))
  ' "$source" >/dev/null 2>&1 || return 1

  local node method detected node_lines
  node_lines=$(jq -c '.nodes[]' "$source") || return 1
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    validate_name "$(jq -er '.name' <<<"$node")" || return 1
    method=$(jq -er '.method' <<<"$node") || return 1
    validate_base64_key "$(jq -er '.password' <<<"$node")" "$(method_key_bytes "$method")" || return 1
    detected=$(validate_address "$(jq -er '.address' <<<"$node")") || return 1
    [[ "$detected" == "$(jq -er '.address_type' <<<"$node")" ]] || return 1
  done <<<"$node_lines"
}

validate_traffic_file_semantic() {
  local source=$1 nodes_source=${2:-}
  jq -e --argjson max "$MAX_SAFE_JSON_INTEGER" '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    def uint: type == "number" and . >= 0 and . <= $max and floor == .;
    .schema_version == 1 and (.nodes | type == "object")
    and all(.nodes | to_entries[];
      (.key | test("^[a-f0-9]{32}$"))
      and (.value | type == "object")
      and (. as $entry | all(["current_upload_bytes","current_download_bytes","total_upload_bytes","total_download_bytes","upload_kernel_bytes","download_kernel_bytes","quota_bytes"][];
        . as $key | $entry.value[$key] | uint))
      and (.value.reset_day | type == "number" and floor == . and . >= 1 and . <= 28)
      and (.value.last_reset_at | iso) and (.value.next_reset_at | iso) and (.value.updated_at | iso)
      and (.value.last_reset_at < .value.next_reset_at)
    )
  ' "$source" >/dev/null 2>&1 || return 1
  if [[ -n "$nodes_source" ]]; then
    jq -e --slurpfile nodes "$nodes_source" '
      ([.nodes | keys[]] | sort) == ([$nodes[0].nodes[].node_id] | sort)
      and (. as $traffic | all($nodes[0].nodes[];
        . as $node | ($traffic.nodes[$node.node_id].quota_bytes == $node.quota_bytes)
        and ($traffic.nodes[$node.node_id].reset_day == $node.reset_day)))
    ' "$source" >/dev/null 2>&1 || return 1
  fi
}

validate_history_file_semantic() {
  local source=$1
  jq -e --argjson max "$MAX_SAFE_JSON_INTEGER" '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    def uint: type == "number" and . >= 0 and . <= $max and floor == .;
    def clean_name: type == "string" and length >= 1 and length <= 64 and (test("[\\u0000-\\u001f\\u007f]") | not);
    def traffic_snapshot:
      type == "object"
      and (. as $entry | all(["current_upload_bytes","current_download_bytes","total_upload_bytes","total_download_bytes","quota_bytes"][];
        . as $key | $entry[$key] | uint))
      and (. as $entry | all(["upload_kernel_bytes","download_kernel_bytes"][];
        . as $key | ($entry | has($key) | not) or ($entry[$key] | uint)))
      and (.reset_day | type == "number" and floor == . and . >= 1 and . <= 28)
      and (.last_reset_at | iso) and (.next_reset_at | iso)
      and ((has("updated_at") | not) or (.updated_at | iso))
      and (.last_reset_at < .next_reset_at);
    .schema_version == 1 and (.cycles | type == "object")
    and ((.deleted_nodes // {}) | type == "object")
    and all(.cycles | to_entries[];
      (.key | test("^[a-f0-9]{32}$")) and (.value.node_name | clean_name)
      and (.value.entries | type == "array")
      and ([.value.entries[].period] | length == (unique | length))
      and all(.value.entries[];
        (.period | type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])$"))
        and (.period_start_at | iso) and (.period_end_at | iso) and (.closed_at | iso)
        and (.period_start_at < .period_end_at)
        and (.upload_bytes | uint) and (.download_bytes | uint) and (.total_bytes | uint)
        and (.total_bytes == (.upload_bytes + .download_bytes))))
    and all((.deleted_nodes // {}) | to_entries[];
      (.key | test("^[a-f0-9]{32}$")) and (.value.node_name | clean_name)
      and (.value.deleted_at | iso) and (.value.traffic | traffic_snapshot))
  ' "$source" >/dev/null 2>&1
}

validate_interfaces_file_semantic() {
  local source=$1
  jq -e '
    .schema_version == 1 and (.interfaces | type == "array")
    and all(.interfaces[]; type == "string" and test("^[A-Za-z0-9_.-]{1,15}$"))
    and ([.interfaces[]] | length == (unique | length))
  ' "$source" >/dev/null 2>&1
}

validate_bandwidth_plan_semantic() {
  local source=$1
  jq -e '
    def iso: type == "string" and ((try fromdateiso8601 catch null) != null);
    .schema_version == 2
    and (.pref | type == "number" and floor == . and . >= 100 and . <= 65500)
    and (.boot_id == "unknown" or (.boot_id | type == "string" and test("^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$")))
    and (.interfaces | type == "array")
    and all(.interfaces[]; type == "string" and test("^[A-Za-z0-9_.-]{1,15}$"))
    and ([.interfaces[]] | length == (unique | length))
    and (.updated_at | iso)
    and (.actions | type == "array")
    and ((has("families") | not) or
      ((.families | type == "array")
        and (.families | length >= 1)
        and all(.families[]; . == "ip" or . == "ipv6")
        and ([.families[]] | length == (unique | length))))
    and all(.actions[];
      (.node_id | type == "string" and test("^[a-f0-9]{32}$"))
      and (.direction == "ingress" or .direction == "egress")
      and (.port | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.kind == "gact" or .kind == "police")
      and (.index | type == "number" and floor == . and . > 0 and . <= 4294967295)
      and (.cookie | type == "string" and test("^[a-f0-9]{32}$"))
      and (.limit_mbps | type == "number" and . >= 0 and . <= 1000000))
    and ([.actions[].index] | length == (unique | length))
    and ([.actions[] | [.node_id,.direction] | join(":")] | length == (unique | length))
  ' "$source" >/dev/null 2>&1
}

validate_bandwidth_plan_against_state() {
  local plan_source=$1 nodes_source=$2 interfaces_source=$3
  jq -e --slurpfile nodes "$nodes_source" --slurpfile interfaces "$interfaces_source" '
    (.interfaces | unique | sort) == ($interfaces[0].interfaces | unique | sort)
    and (. as $plan | all($nodes[0].nodes[] | select(.status == "enabled");
      . as $node
      | ([ $plan.actions[] | select(.node_id == $node.node_id) ] | length) == 2
      and all(["ingress","egress"][];
        . as $direction
        | [ $plan.actions[] | select(.node_id == $node.node_id and .direction == $direction) ] as $matches
        | ($matches | length) == 1
        and ($matches[0].port == $node.port)
        and ($matches[0].limit_mbps == (if $direction == "ingress" then $node.upload_limit_mbps else $node.download_limit_mbps end))
        and ($matches[0].kind == (if $matches[0].limit_mbps == 0 then "gact" else "police" end)))))
    and all(.actions[];
      . as $action
      | any($nodes[0].nodes[]; .status == "enabled" and .node_id == $action.node_id))
  ' "$plan_source" >/dev/null 2>&1
}

validate_base64_key() {
  local value=$1
  local expected_bytes=$2
  [[ "$value" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  local decoded_size
  decoded_size=$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c) || return 1
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
    generated=$(openssl rand -base64 "$key_bytes" | tr -d '\r\n') || die 'OpenSSL 安全随机密钥生成失败。'
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
  python3 - "$value" "$MAX_SAFE_JSON_INTEGER" <<'PY'
from decimal import Decimal, InvalidOperation, ROUND_FLOOR
import re
import sys

value, maximum = sys.argv[1], int(sys.argv[2])
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
    raise SystemExit(1)
try:
    result = int((Decimal(value) * Decimal(1000000000)).to_integral_value(rounding=ROUND_FLOOR))
except (InvalidOperation, OverflowError):
    raise SystemExit(1)
if result < 0 or result > maximum:
    raise SystemExit(1)
print(result)
PY
}

validate_safe_uint() {
  local value=$1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  python3 - "$value" "$MAX_SAFE_JSON_INTEGER" <<'PY'
import sys
value = int(sys.argv[1])
maximum = int(sys.argv[2])
raise SystemExit(0 if 0 <= value <= maximum else 1)
PY
}

safe_add_bytes() {
  python3 - "$1" "$2" "$MAX_SAFE_JSON_INTEGER" <<'PY'
import sys
a, b, maximum = map(int, sys.argv[1:])
result = a + b
if a < 0 or b < 0 or result > maximum:
    raise SystemExit(1)
print(result)
PY
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
  # Sensitive URI components must not be placed in jq's argv, where another
  # local user could observe them through the process table on some systems.
  printf '%s' "$1" | jq -Rr '@uri'
}

is_command_from_manager() {
  local command_path=$1
  [[ "$command_path" == "/usr/local/bin/rem" ]] || return 1
  if [[ -L "$command_path" ]]; then
    [[ "$(readlink -f -- "$command_path" 2>/dev/null || true)" == "$PROGRAM_DIR/ss-manager.sh" ]]
    return
  fi
  [[ -f "$command_path" && -O "$command_path" ]] || return 1
  local -a wrapper_lines=()
  mapfile -t wrapper_lines <"$command_path" || return 1
  [[ "${wrapper_lines[0]:-}" == '#!/usr/bin/env bash' ]] || return 1
  # Accept the exact two-line wrapper shipped by older releases.
  if (( ${#wrapper_lines[@]} == 2 )); then
    [[ "${wrapper_lines[1]}" == "exec $PROGRAM_DIR/ss-manager.sh \"\$@\"" ]]
    return
  fi
  # New recovery-aware wrappers carry an explicit ownership marker. Requiring
  # it prevents a foreign script that merely mentions our exec line from being
  # mistaken for a replaceable Ss2022 command.
  [[ "${wrapper_lines[1]:-}" == '# Managed by Ss2022' ]] || return 1
  grep -Fqx "  exec $PROGRAM_DIR/ss-manager.sh \"\$@\"" "$command_path" 2>/dev/null \
    && grep -Fq '/opt/ss-manager.install-old.*/ss-manager.sh' "$command_path" 2>/dev/null \
    && grep -Fq '/opt/ss-manager.update-old.*/ss-manager.sh' "$command_path" 2>/dev/null
}

install_rem_command() {
  local destination=/usr/local/bin/rem temporary wrapper
  [[ -d /usr/local/bin ]] || install -d -m 755 -- /usr/local/bin || return 1
  wrapper=$(runtime_temp_file rem.wrapper) || return 1
  cat >"$wrapper" <<'EOF' || { rm -f -- "$wrapper"; return 1; }
#!/usr/bin/env bash
# Managed by Ss2022
set -u

if [[ -f /opt/ss-manager/ss-manager.sh && ! -L /opt/ss-manager/ss-manager.sh \
  && -x /opt/ss-manager/ss-manager.sh && -O /opt/ss-manager/ss-manager.sh ]]; then
  exec /opt/ss-manager/ss-manager.sh "$@"
fi

# A power loss in the tiny interval between two directory renames can leave
# the durable transaction journal intact while the canonical entry is absent.
# Execute the one root-owned previous program so it can perform startup
# recovery. Refuse ambiguity instead of choosing an arbitrary directory.
shopt -s nullglob
recovery=''
for candidate in /opt/ss-manager.install-old.*/ss-manager.sh /opt/ss-manager.update-old.*/ss-manager.sh; do
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" && -O "$candidate" ]] || continue
  if [[ -n "$recovery" ]]; then
    printf '[ERROR] 检测到多个 manager 恢复入口，请重新运行固定版本 install.sh。\n' >&2
    exit 1
  fi
  recovery=$candidate
done
if [[ -n "$recovery" ]]; then
  exec "$recovery" "$@"
fi
printf '[ERROR] /opt/ss-manager/ss-manager.sh 不存在；请重新运行固定版本 install.sh 恢复。\n' >&2
exit 1
EOF
  temporary=$(mktemp /usr/local/bin/.rem.ss-manager.XXXXXXXX) || { rm -f -- "$wrapper"; return 1; }
  [[ -f "$temporary" && ! -L "$temporary" ]] || { rm -f -- "$wrapper" "$temporary"; return 1; }
  install -m 755 -- "$wrapper" "$temporary" || { rm -f -- "$wrapper" "$temporary"; return 1; }
  rm -f -- "$wrapper" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path "$temporary" || { rm -f -- "$temporary"; return 1; }
  atomic_replace_regular_file "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
  durable_sync_path /usr/local/bin || return 1
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
  [[ "$MANAGED_SYSCTL_FILE" == /etc/sysctl.d/99-ss-manager.conf ]] || die "拒绝替换或删除非标准 sysctl 路径：$MANAGED_SYSCTL_FILE"
  local directory
  local -a protected_directories=(
    /opt /etc /var /var/lib /run /usr /usr/local /usr/local/bin
    /etc/sing-box /etc/sysctl.d
    "$PROGRAM_DIR" "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
  )
  if [[ "${INIT_SYSTEM:-}" == systemd ]]; then
    protected_directories+=(/etc/systemd /etc/systemd/system)
  elif [[ "${INIT_SYSTEM:-}" == openrc ]]; then
    protected_directories+=(/etc/init.d /etc/runlevels)
  fi
  for directory in "${protected_directories[@]}"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      [[ -d "$directory" && ! -L "$directory" ]] \
        || die "拒绝通过非普通目录或符号链接执行系统写入/删除：$directory"
    fi
  done
}

trap_cleanup_file() {
  local path=$1
  trap 'rm -f -- "$path"' RETURN
}
