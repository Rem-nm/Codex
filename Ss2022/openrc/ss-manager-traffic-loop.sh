#!/bin/sh
# Foreground maintenance loop supervised by OpenRC.

interval=60
while :; do
  if /opt/ss-manager/ss-manager.sh --maintenance; then
    sleep "$interval"
  else
    # A transient lock or network-control failure must not permanently stop
    # quota settlement. Retry sooner; supervise-daemon handles hard exits.
    sleep 5
  fi
done
