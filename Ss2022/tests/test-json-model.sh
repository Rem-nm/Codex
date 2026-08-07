#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 77; }
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

jq -n '{schema_version:1,nodes:[{node_id:"0123456789abcdef0123456789abcdef",name:"Tokyo",method:"2022-blake3-aes-256-gcm",password:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",port:20001,address:"192.0.2.1",address_type:"ipv4",status:"enabled",status_reason:"",quota_bytes:0,reset_day:1,upload_limit_mbps:0,download_limit_mbps:0,created_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z",last_reset_at:"2026-01-01T00:00:00Z",next_reset_at:"2026-02-01T00:00:00Z"}]}' >"$TMP/nodes.json"
jq -e '.schema_version == 1 and .nodes[0].node_id == "0123456789abcdef0123456789abcdef" and .nodes[0].port == 20001' "$TMP/nodes.json" >/dev/null
printf 'JSON model tests passed\n'
