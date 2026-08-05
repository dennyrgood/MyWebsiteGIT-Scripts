#!/bin/sh
# lastlogs.sh - tail -10 the newest timestamped log per prefix in the current dir
# Groups files matching PREFIX_YYYYMMDD_HHMMSS[Z].ext; one tail per prefix.
# 2026-08-05 12:00 UTC (approx) - created

prefixes=$(ls 2>/dev/null \
  | grep -E '_[0-9]{8}_[0-9]{6}Z?\.[A-Za-z0-9]+$' \
  | sed -E 's/_[0-9]{8}_[0-9]{6}Z?\.[A-Za-z0-9]+$//' \
  | sort -u)

count=$(printf '%s\n' "$prefixes" | grep -c .)

for p in $prefixes; do
  newest=$(ls "${p}"_[0-9]* 2>/dev/null | sort | tail -1)
  [ -n "$newest" ] || continue
  if [ "$count" -gt 1 ]; then
    echo "====== $newest ======"
  fi
  tail -10 "$newest"
  if [ "$count" -gt 1 ]; then
    echo
  fi
done
