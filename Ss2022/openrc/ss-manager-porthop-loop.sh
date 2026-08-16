#!/bin/sh
# Foreground Hysteria2 port-hopping reconcile loop supervised by OpenRC.

interval=60
# OpenRC starts this supervised loop asynchronously.  Give an install or
# first-run manager process time to release its transaction lock before the
# first reconcile; subsequent passes retain the normal one-minute cadence.
sleep 5
while :; do
  /opt/ss-manager/ss-manager.sh --port-hop-restore >/dev/null 2>&1 || true
  sleep "$interval"
done
