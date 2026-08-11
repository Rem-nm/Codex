#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

assert_true() { "$@" || { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }; }
assert_false() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }

assert_true validate_method 2022-blake3-aes-128-gcm
assert_true validate_method 2022-blake3-aes-256-gcm
assert_false validate_method aes-256-gcm
assert_true validate_port 1
assert_true validate_port 65535
assert_false validate_port 0
assert_false validate_port 65536
assert_false validate_port 18446744073709551617
assert_false validate_port 08
assert_true validate_reset_day 1
assert_true validate_reset_day 28
assert_false validate_reset_day 29
assert_false validate_reset_day 18446744073709551617
assert_false validate_reset_day 08
assert_true validate_name Tokyo
assert_false validate_name $'bad\nname'
assert_true validate_address 192.0.2.1
assert_true validate_address 2001:db8::1
assert_false validate_address 'fe80::1%eth0'
assert_true validate_address example.com
assert_false validate_address 'https://example.com'
assert_true validate_base64_key 'AAAAAAAAAAAAAAAAAAAAAA==' 16
assert_false validate_base64_key 'weak' 16
printf 'validation tests passed\n'
