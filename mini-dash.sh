#!/usr/bin/env bash
# mini-dash.sh — Strict layout clone for Mole
# 2026-08-30

tput civis
clear
trap 'tput cnorm; exit' INT TERM EXIT

draw_bar() {
  local pct=${1%.*}
  [[ ! "$pct" =~ ^[0-9]+$ ]] && pct=0
  # Capped at 14 characters to prevent horizontal wrapping in narrow tmux split panes
  local width=14
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  
  local color="\033[32m" # Green
  if [ "$pct" -ge 85 ]; then color="\033[31m"; # Red
  elif [ "$pct" -ge 70 ]; then color="\033[33m"; fi # Yellow

  local bar_f=$(printf '%*s' "$filled" '' | tr ' ' '#')
  local bar_e=$(printf '%*s' "$empty" '' | tr ' ' '-')
  echo -e "[${color}${bar_f}\033[90m${bar_e}\033[0m]"
}

while true; do
  echo -ne "\033[H"
  
  HOST=$(hostname)
  UPTIME=$(uptime -p | sed 's/up //' | cut -d',' -f1,2)
  KERNEL=$(uname -r | cut -d'-' -f1)
  
  # CPU Usage & Core Count
  CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "4")
  CPU_USE=$(LC_ALL=C top -bn1 | awk '/Cpu\(s\)/ {for(i=1;i<=NF;i++) if($i ~ /id/) print 100 - $(i-1)}' | cut -d'.' -f1 | tr -d ',')
  [[ ! "$CPU_USE" =~ ^[0-9]+$ ]] && CPU_USE=0

  # Memory (GB)
  MEM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
  MEM_USED_MB=$(free -m | awk '/Mem:/ {print $3}')
  MEM_PCT=0
  [ "${MEM_TOTAL_MB:-0}" -gt 0 ] && MEM_PCT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))
  
  MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_TOTAL_MB/1024}")
  MEM_USED_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_USED_MB/1024}")

  # Swap
  SWAP_TOTAL_MB=$(free -m | awk '/Swap:/ {print $2}')
  SWAP_USED_MB=$(free -m | awk '/Swap:/ {print $3}')
  SWAP_PCT=0
  [ "${SWAP_TOTAL_MB:-0}" -gt 0 ] && SWAP_PCT=$(( SWAP_USED_MB * 100 / SWAP_TOTAL_MB ))

  # Disk
  DISK_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
  DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
  DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')

  # Network Interface Active Detection
  NET_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
  [ -z "$NET_IF" ] && NET_IF="eth0"

  # Dynamic Health Status Badge
  HEALTH_STR="\033[1;32m100%  Excellent\033[0m"
  if [ "$CPU_USE" -ge 85 ] || [ "$MEM_PCT" -ge 85 ] || [ "$DISK_PCT" -ge 90 ]; then
    HEALTH_STR="\033[1;31mElevated Resource Usage\033[0m"
  elif [ "$CPU_USE" -ge 70 ] || [ "$MEM_PCT" -ge 70 ] || [ "$DISK_PCT" -ge 75 ]; then
    HEALTH_STR="\033[1;33mModerate Load\033[0m"
  fi

  # --- MOLE DISPLAY OUTPUT ---
  echo -e "\033[1;35m🐹 Mini-Mole System Status 🐹\033[0m\033[K"
  printf "Health: %b\033[K\n" "$HEALTH_STR"
  echo -e "\033[1;30m----------------------------------------\033[0m\033[K"
  
  echo -e "\033[1;33m📌 System\033[0m\033[K"
  printf "Host: \033[1m%-10s\033[0m | OS: Linux %s\033[K\n" "$HOST" "$KERNEL"
  printf "Uptime: %s\033[K\n" "$UPTIME"
  
  echo -e "\033[1;33m⚡ CPU\033[0m\033[K"
  printf "Usage: %3d%% (%d cores) " "$CPU_USE" "$CPU_CORES"
  draw_bar "$CPU_USE"
  
  echo -e "\033[1;33m🧠 Memory\033[0m\033[K"
  printf "RAM:  %sG/%sG (%2d%%) " "$MEM_USED_GB" "$MEM_TOTAL_GB" "$MEM_PCT"
  draw_bar "$MEM_PCT"
  printf "Swap: %2d%% " "$SWAP_PCT"
  draw_bar "$SWAP_PCT"
  
  echo -e "\033[1;33m💾 Disks\033[0m\033[K"
  printf "/: %s/%s (%2d%%) " "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT"
  draw_bar "$DISK_PCT"

  echo -e "\033[1;33m🔥 Top Processes\033[0m\033[K"
  ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 5 | tail -n 4 | awk '{printf " [\033[36m%.5s\033[0m] %-9.9s \033[90m(C:%s%% M:%s%%)\033[0m\033[K\n", $1, $5, $3, $4}'

  echo -e "\033[1;33m🌐 Network\033[0m\033[K"
  printf "%-10s Active\033[K\n" "$NET_IF"

  sleep 4
done
