#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for command_name in jq openssl base64 python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || { printf '%s is required\n' "$command_name" >&2; exit 77; }
done

source "$ROOT/lib/common.sh"
source "$ROOT/lib/certs.sh"
source "$ROOT/lib/system.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/lib/singbox.sh"
source "$ROOT/lib/traffic.sh"
source "$ROOT/lib/bandwidth.sh"
source "$ROOT/lib/port_hopping.sh"
source "$ROOT/lib/nodes.sh"
source "$ROOT/lib/links.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
CONFIG_DIR="$TEST_TMP/config"
DATA_DIR="$TEST_TMP/data"
RUNTIME_DIR="$TEST_TMP/run"
BACKUP_DIR="$CONFIG_DIR/backups"
CERTS_DIR="$CONFIG_DIR/certs"
MANAGER_STATE="$CONFIG_DIR/manager.json"
NODES_FILE="$DATA_DIR/nodes.json"
TRAFFIC_FILE="$DATA_DIR/traffic.json"
HISTORY_FILE="$DATA_DIR/traffic-history.json"
INTERFACES_FILE="$DATA_DIR/interfaces.json"
COUNTERS_FILE="$DATA_DIR/tc-counters.json"
TRANSACTION_LOCK="$RUNTIME_DIR/manager.lock"
STATE_TRANSACTION_DIR="$CONFIG_DIR/state-transaction"
INSTALL_TRANSACTION_DIR="$CONFIG_DIR/install-transaction"
SING_BOX_CONFIG="$TEST_TMP/sing-box.json"
PORTHOP_PLAN="$DATA_DIR/port-hopping-plan.json"
mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
printf '%s\n' '{"schema_version":1,"listen_mode":"ipv4","listen_address":"0.0.0.0","tfo_config_supported":false,"tfo_kernel_enabled":false}' >"$MANAGER_STATE"
printf '%s\n' '{"schema_version":5,"nodes":[]}' >"$NODES_FILE"

fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

node_id=0123456789abcdef0123456789abcdef

# `ss` local endpoints are column 4; exercise both wildcard IPv4 and bracketed
# IPv6 output so the real listener snapshot cannot silently parse the peer `*`.
ss() {
  printf '%s\n' \
    'UNCONN 0 0 0.0.0.0:31586 0.0.0.0:*' \
    'UNCONN 0 0 [::]:31588 [::]:*'
}
listener_ports=$(port_hopping_system_udp_ports) || fail 'UDP listener snapshot failed'
[[ "$listener_ports" == $'31586\n31588' ]] || fail "UDP listener parser returned: $listener_ports"

record="$TEST_TMP/hy2.json"
node_new_hysteria2_record 'Hop HY2' 35000 192.0.2.50 ipv4 "$node_id" \
  'HopPassword_123' 'hy2-test.invalid' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"$record" \
  || fail 'could not build Hysteria2 record'
jq --slurpfile record "$record" --arg id "$node_id" \
  '.nodes += [$record[0]] | .nodes[0].port_hopping_enabled=true | .nodes[0].hop_port_start=30000 | .nodes[0].hop_port_end=40000' \
  "$NODES_FILE" >"$NODES_FILE.next" && mv -- "$NODES_FILE.next" "$NODES_FILE"

# Keep this model test independent from the host firewall and route table; the
# real VPS tests exercise nftables/iptables probing and rule ownership.
port_hopping_system_udp_ports() { printf '35000\n'; }
traffic_interfaces() { printf 'eth0\n'; }
port_hopping_detect_backend() { printf 'nftables\n'; }
hysteria2_validate_certificate_files() { return 0; }

desired="$TEST_TMP/desired.json"
port_hopping_build_desired "$NODES_FILE" "$desired" || fail 'desired port-hopping plan failed'
jq -e '
  .schema_version == 1 and .backend == "nftables" and (.rules | length) == 2
  and all(.rules[]; .family == "ip" and .interface == "eth0" and .actual_port == 35000)
  and ([.rules[].start, .rules[].end] | sort) == [30000,34999,35001,40000]
  and all(.rules[]; .actual_port < .start or .actual_port > .end)
' "$desired" >/dev/null || fail 'port-hopping plan did not split around actual port'

# An actual listener outside the configured range must not widen the NAT
# range toward that listener.
port_hopping_system_udp_ports() { printf '45000\n'; }
jq '.nodes[0].port=45000' "$NODES_FILE" >"$NODES_FILE.next" && mv -- "$NODES_FILE.next" "$NODES_FILE"
outside_desired="$TEST_TMP/outside-desired.json"
port_hopping_build_desired "$NODES_FILE" "$outside_desired" || fail 'outside-range desired plan failed'
jq -e '.rules | length == 1 and .[0].start == 30000 and .[0].end == 40000 and .[0].actual_port == 45000' \
  "$outside_desired" >/dev/null || fail 'outside-range plan was widened or split incorrectly'
jq '.nodes[0].port=35000' "$NODES_FILE" >"$NODES_FILE.next" && mv -- "$NODES_FILE.next" "$NODES_FILE"

actions="$TEST_TMP/actions.json"
bandwidth_build_actions "$NODES_FILE" "$actions" || fail 'range tc actions failed'
jq -e '
  length == 2
  and all(.[]; .protocols == ["udp"] and (.matches | length) == 1
    and .matches[0].start == 30000 and .matches[0].end == 40000)
' "$actions" >/dev/null || fail 'tc plan did not retain the complete UDP hopping range'

node=$(jq -c '.nodes[0]' "$NODES_FILE")
uri=$(node_hysteria2_uri "$node") || fail 'Hysteria2 hopping URI generation failed'
[[ "$uri" == *':30000-40000/?'* ]] || fail 'Hysteria2 URI did not publish the standard port range'
[[ "$uri" != *'hopInterval='* ]] || fail 'Hysteria2 URI invented a non-standard hopInterval parameter'

port_hopping_system_udp_ports() { printf '35000\n36000\n'; }
if port_hopping_build_desired "$NODES_FILE" "$TEST_TMP/conflict.json" >/dev/null 2>&1; then
  fail 'a system UDP listener inside the hopping range was accepted'
fi

printf 'Hysteria2 port-hopping model tests passed\n'
