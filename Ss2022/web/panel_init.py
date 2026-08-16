#!/usr/bin/env python3
"""Initialize the optional REM Web Panel state.

The password is accepted only through stdin so it cannot appear in process
arguments.  Existing state is never replaced unless ``--force`` is explicit.
"""

from __future__ import annotations

import argparse
import getpass
import os
import sys

from panel_common import (
    PANEL_CONFIG,
    PANEL_PUBLIC_CONFIG,
    PanelError,
    build_panel_configs,
    write_panel_configs,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Initialize REM Web Panel state")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-stdin", action="store_true", help="read password from stdin")
    parser.add_argument("--instance-name")
    parser.add_argument("--enable", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--print-token", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.password_stdin:
        print("[ERROR] 必须使用 --password-stdin，拒绝在命令参数中接收密码。", file=sys.stderr)
        return 2
    if (os.path.exists(PANEL_CONFIG) or os.path.lexists(PANEL_CONFIG)) and not args.force:
        print("[ERROR] Panel 状态已存在；使用 --force 才能明确替换。", file=sys.stderr)
        return 1
    try:
        password = sys.stdin.readline().rstrip("\r\n")
        if not password:
            print("[ERROR] 密码不能为空。", file=sys.stderr)
            return 2
        private, public = build_panel_configs(
            args.username,
            password,
            enabled=args.enable,
            instance_name=args.instance_name,
        )
        write_panel_configs(private, public)
    except PanelError as exc:
        print(f"[ERROR] {exc.message}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"[ERROR] Panel 状态写入失败：{exc}", file=sys.stderr)
        return 1
    if args.print_token:
        print(private["panel_path_token"])
    else:
        print("[OK] Web Panel 状态已初始化；默认是否监听由 --enable 决定。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
