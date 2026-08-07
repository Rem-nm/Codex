#!/bin/sh
# Small public installer entry point. It fetches the complete modular project
# before invoking install.sh; running install.sh alone from stdin is unsupported.

set -eu

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail '请以 root 身份执行安装命令。'

if [ ! -r /etc/os-release ]; then
  fail '无法识别 Linux 发行版：缺少 /etc/os-release。'
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu|centos|almalinux|alpine) ;;
  *) fail "不支持的发行版：${PRETTY_NAME:-${ID:-unknown}}。" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64|aarch64|arm64) ;;
  *) fail "不支持的 CPU 架构：$arch。仅支持 amd64 与 arm64。" ;;
esac

if [ "${ID:-}" = alpine ]; then
  # A minimal Alpine image normally has BusyBox wget but not Bash/curl/tar.
  apk add --no-cache bash ca-certificates curl tar >/dev/null \
    || fail 'Alpine 基础安装依赖下载失败。'
fi

command -v bash >/dev/null 2>&1 || fail '系统缺少 Bash。'
command -v tar >/dev/null 2>&1 || fail '系统缺少 tar。'

ref=${SS_MANAGER_REF:-codex/ss2022-manager}
case "$ref" in
  ''|/*|*..*|*[!A-Za-z0-9._/-]*) fail 'SS_MANAGER_REF 包含不安全字符。' ;;
esac

tmp_dir=$(mktemp -d) || fail '无法创建临时目录。'
archive="$tmp_dir/Codex.tar.gz"
archive_list="$tmp_dir/archive.list"
cleanup() {
  [ -n "${tmp_dir:-}" ] && [ "$tmp_dir" != / ] && rm -rf -- "$tmp_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

archive_url="https://github.com/Rem-nm/Codex/archive/refs/heads/$ref.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --max-time 120 --output "$archive" -- "$archive_url" \
    || fail '无法从 Rem-nm/Codex 下载项目归档。'
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$archive" -- "$archive_url" \
    || fail '无法从 Rem-nm/Codex 下载项目归档。'
else
  fail '系统缺少 curl 或 wget。'
fi

tar -tzf "$archive" >"$archive_list" || fail '项目归档无法读取。'
if ! awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$archive_list"; then
  fail '项目归档包含不安全路径，已停止解压。'
fi
tar -xzf "$archive" -C "$tmp_dir" --strip-components=1

[ -f "$tmp_dir/Ss2022/install.sh" ] || fail '项目归档缺少 Ss2022/install.sh。'
[ -f "$tmp_dir/Ss2022/lib/common.sh" ] || fail '项目归档缺少必要模块。'
[ -f "$tmp_dir/Ss2022/VERSION" ] || fail '项目归档缺少 VERSION。'

bash "$tmp_dir/Ss2022/install.sh"
