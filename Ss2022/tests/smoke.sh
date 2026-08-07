#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for file in "$ROOT/install.sh" "$ROOT/ss-manager.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$file"
done
printf 'shell syntax smoke test passed\n'
