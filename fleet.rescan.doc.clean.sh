#!/bin/bash

# paths only, old vs new

awk '{print $NF}' ~/fleet_git_baseline.txt     | sort > /tmp/old_paths.txt

awk '{print $NF}' ~/fleet_git_baseline_NEW.txt | sort > /tmp/new_paths.txt

echo "=== NEW (added) ==="     ; comm -13 /tmp/old_paths.txt /tmp/new_paths.txt

echo "=== DELETED (removed) ===" ; comm -23 /tmp/old_paths.txt /tmp/new_paths.txt

echo "=== CHANGED (same path, different sha) ==="

join -j2 <(sort -k2 ~/fleet_git_baseline.txt) <(sort -k2 ~/fleet_git_baseline_NEW.txt) 2>/dev/null | true

# simplest changed check: files present in both path-lists but whose full lines differ

comm -12 /tmp/old_paths.txt /tmp/new_paths.txt > /tmp/common_paths.txt

grep -Ff /tmp/common_paths.txt ~/fleet_git_baseline_NEW.txt | sort > /tmp/new_common.txt

grep -Ff /tmp/common_paths.txt ~/fleet_git_baseline.txt     | sort > /tmp/old_common.txt

diff /tmp/old_common.txt /tmp/new_common.txt   # any output here = changed files

