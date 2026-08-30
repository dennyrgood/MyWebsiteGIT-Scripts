#!/usr/bin/env bash
# mini-dash.sh — terminal dashboard layout with ASCII fallbacks
# 2026-08-30

# Disable cursor
tput civis
trap 'tput cnorm; exit' INT TERM EXIT

draw_bar() {
  local pct=${1%.*}
  local width=22
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  
  local color="\033[32m" # Green
  if [ "$pct" -ge 85 ]; then color="\033[31m"; # Red
  elif [ "$pct" -ge 70 ]; then color="\033[33m"; fi # Yellow

  # Standard ASCII characters replace UTF-8 blocks
  local bar_f=$(printf '%*s' "$filled" '' | tr ' ' '#')
  local bar_e=$(printf '%*s' "$empty" '' | tr ' ' '-')
  echo -e "[${color}${bar_f}\033[90m${bar_e}\033[0m]"
}

while true; do
  clear
  HOST=$(hostname)
  UPTIME=$(uptime -p | sed 's/up //')
  
  # CPU
  CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'.' -f1)
  CPU_USE=$(( 100 - CPU_IDLE ))
  
  # RAM & Swap
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
  
  SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
  SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
  SWAP_PCT=0
  [ "$SWAP_TOTAL" -gt 0 ] && SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))

  # Disk
  DISK_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

  # Header
  echo -e "\033[1;36mSystem Status\033[0m"
  echo -e "\033[1;30m----- System -------------------------------------\033[0m"
  echo -e "\033[33mHost:\033[0m $HOST | \033[33mUptime:\033[0m $UPTIME"
  
  echo -e "\033[1;30m----- CPU ----------------------------------------\033[0m"
  printf "Usage: %3d%%  " "$CPU_USE"
  draw_bar "$CPU_USE"
  
  echo -e "\033[1;30m----- Memory -------------------------------------\033[0m"
  printf "RAM:   %2d%%  " "$MEM_PCT"
  draw_bar "$MEM_PCT"
  printf "Swap:  %2d%%  " "$SWAP_PCT"
  draw_bar "$SWAP_PCT"
  
  echo -e "\033[1;30m----- Disks --------------------------------------\033[0m"
  printf "root:  %2d%%  " "$DISK_PCT"
  draw_bar "$DISK_PCT"

  echo -e "\033[1;30m----- Top Processes ------------------------------\033[0m"
  echo -e "\033[1;33m  PID USER      %CPU  %MEM COMMAND\033[0m"
  ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 5 | tail -n 4 | awk '{printf " \033[36m%5s\033[0m %-8s %5s %5s %s\n", $1, $2, $3, $4, $5}'

  sleep 2
done
