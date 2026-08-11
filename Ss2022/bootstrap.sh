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

# Validate immutable inputs before even the Alpine bootstrap dependency step.
commit=${SS_MANAGER_COMMIT:-}
archive_sha256=${SS_MANAGER_ARCHIVE_SHA256:-}
case "$commit" in
  *[!0-9A-Fa-f]*|'') fail '必须设置 40 位 SS_MANAGER_COMMIT；拒绝以 root 跟随可变分支。' ;;
esac
[ "${#commit}" -eq 40 ] || fail 'SS_MANAGER_COMMIT 必须是完整的 40 位 Git 提交 SHA。'
case "$archive_sha256" in
  *[!0-9A-Fa-f]*|'') fail '必须设置 64 位 SS_MANAGER_ARCHIVE_SHA256。' ;;
esac
[ "${#archive_sha256}" -eq 64 ] || fail 'SS_MANAGER_ARCHIVE_SHA256 必须是 64 位 SHA256。'

if [ "${ID:-}" = alpine ]; then
  # A minimal Alpine image normally has BusyBox wget but not Bash/curl/tar.
  apk add --no-cache bash ca-certificates curl tar >/dev/null \
    || fail 'Alpine 基础安装依赖下载失败。'
fi

command -v bash >/dev/null 2>&1 || fail '系统缺少 Bash。'
command -v tar >/dev/null 2>&1 || fail '系统缺少 tar。'
command -v sha256sum >/dev/null 2>&1 || fail '系统缺少 sha256sum。'

tmp_dir=$(mktemp -d) || fail '无法创建临时目录。'
archive="$tmp_dir/Codex.tar.gz"
archive_list="$tmp_dir/archive.list"
# shellcheck disable=SC2317 # invoked indirectly by the EXIT trap
cleanup() {
  if [ -n "${tmp_dir:-}" ] && [ "$tmp_dir" != / ]; then
    rm -rf -- "$tmp_dir" || true
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

archive_url="https://github.com/Rem-nm/Codex/archive/$commit.tar.gz"
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

actual_sha256=$(sha256sum "$archive" | awk '{print $1}') \
  || fail '无法计算项目归档 SHA256。'
[ "$(printf '%s' "$actual_sha256" | tr 'A-F' 'a-f')" = "$(printf '%s' "$archive_sha256" | tr 'A-F' 'a-f')" ] \
  || fail '项目归档 SHA256 不匹配；拒绝执行任何项目脚本。'

tar -tzf "$archive" >"$archive_list" || fail '项目归档无法读取。'
if ! awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$archive_list"; then
  fail '项目归档包含不安全路径，已停止解压。'
fi
if tar -tvzf "$archive" | awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {bad=1} END {exit bad}'; then :; else
  fail '项目归档包含链接、设备或其他非普通条目，已停止解压。'
fi
tar -xzf "$archive" -C "$tmp_dir" --strip-components=1 --no-same-owner --no-same-permissions

[ -f "$tmp_dir/Ss2022/install.sh" ] || fail '项目归档缺少 Ss2022/install.sh。'
[ -f "$tmp_dir/Ss2022/lib/common.sh" ] || fail '项目归档缺少必要模块。'
[ -f "$tmp_dir/Ss2022/VERSION" ] || fail '项目归档缺少 VERSION。'

# When this entry point is started as `wget -qO- ... | sh`, stdin belongs to
# the bootstrap source and is already exhausted by the time install.sh asks a
# takeover question.  Reattach the child to the controlling terminal for the
# interactive case; keep stdin unchanged for callers that deliberately run in
# a non-interactive environment without a tty.
status=0
if [ -r /dev/tty ] && [ -w /dev/tty ] && exec 3<>/dev/tty 2>/dev/null; then
  # Do not let the bootstrap shell's `set -e` discard the child's exit
  # status before it can be reported.  This matters when a package hook,
  # capability probe, or service check stops the installer after APT has
  # already completed.
  set +e
  bash "$tmp_dir/Ss2022/install.sh" <&3
  status=$?
  set -e
  exec 3>&-
else
  set +e
  bash "$tmp_dir/Ss2022/install.sh"
  status=$?
  set -e
fi
if [ "$status" -ne 0 ]; then
  printf '[ERROR] 安装脚本退出（退出码 %s）。\n' "$status" >&2
fi
exit "$status"
