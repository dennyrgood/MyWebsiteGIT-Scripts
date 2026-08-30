#!/bin/bash
# Save as ~/mini-dash.sh and run: watch -n 2 -c ~/mini-dash.sh
clear
echo -e "\033[1;36m🏥 System Status\033[0m"
echo -e "\033[1;33m📌 Host:\033[0m $(hostname) | \033[1;33mUp:\033[0m $(uptime -p | sed 's/up //')"
echo -e "\033[1;33m⚡ CPU Usage:\033[0m $(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8"%"}')"
echo -e "\033[1;33m🧠 Memory:\033[0m $(free -h | awk '/Mem:/ {print $3 "/" $2 " ("$3/$2*100"%)"}')"
echo -e "\033[1;33m💾 Storage (/):\033[0m $(df -h / | awk 'NR==2 {print $3 "/" $2 " ("$5")"}')"
echo ""
echo -e "\033[1;36m🔥 Top Processes\033[0m"
ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 5
