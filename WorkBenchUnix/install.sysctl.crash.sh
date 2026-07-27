#!/bin/sh
# Install the kernel crash-capture sysctl and load it.
# Run as normal user (it calls sudo itself):  sh install.sysctl.crash.sh
# 2026-07-23: created. The leading "!" in the first draft was Claude-prompt
#             notation, not shell syntax — inside sh it negated the install and
#             short-circuited the reload, so sysctl --system never ran. Fixed.
set -e

SRC=/home/dhm/repos/scripts/WorkBenchUnix/99-wbu-crash-capture.conf
DST=/etc/sysctl.d/99-wbu-crash-capture.conf

echo "Installing $DST ..."
sudo install -m 0644 "$SRC" "$DST"

echo "Reloading sysctl ..."
sudo sysctl --system 2>&1 | grep -i rcu_stall || true

echo "Verifying running values (expect panic_on_rcu_stall = 1, panic = 30):"
sysctl kernel.panic_on_rcu_stall kernel.panic
