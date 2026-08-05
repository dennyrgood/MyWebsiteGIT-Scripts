#!/bin/zsh
# launchmgr.sh - manage com.dennis LaunchAgents (macOS)
# usage: launchmgr.sh <command> [label]   (run with -h for command list)
# label may be a substring (e.g. tmdb); interactive picker if omitted or ambiguous.
# A bare label with no command defaults to status for that agent.
# 2026-08-05 13:30 UTC (approx) - created
# 2026-08-05 14:15 UTC (approx) - added usage()/-h; dedupe logs when stdout/stderr share a file
# 2026-08-05 14:40 UTC (approx) - label now matches by substring; picker on multiple matches
# 2026-08-05 15:00 UTC (approx) - bare label defaults to status for that agent; status accepts a label filter

AGENT_DIR=$HOME/Library/LaunchAgents
DOMAIN="gui/$(id -u)"

die() { echo "$@" >&2; exit 1; }

usage() {
  cat <<EOF
usage: ${0:t} <command> [label]
       ${0:t} <label>              (shorthand for: status <label>)
  status   - PID + last exit code for com.dennis agents (label optional)
  kick     - kickstart -k (restart now)
  logs     - tail the agent's StandardOutPath/StandardErrorPath files
  info     - launchctl print (full runtime state, next run, run count)
  show     - cat the plist
  load     - bootstrap the plist into the gui domain
  unload   - bootout (clean remove without reboot)
  enable   - re-enable a disabled agent
  disable  - stop it firing without uninstalling (survives reboot)
  lint     - plutil -lint the plist
  run      - run the agent's ProgramArguments in the foreground
label may be a substring (e.g. tmdb); interactive picker if omitted or ambiguous.
EOF
}

pick() {
  local agents=($AGENT_DIR/com.dennis.*.plist(N))
  (( ${#agents} )) || die "no com.dennis agents in $AGENT_DIR"
  select sel in ${agents:t:r}; do
    [[ -n $sel ]] && { LABEL=$sel; return; }
    die "no selection"
  done
}

cmd=$1
case $cmd in
  ""|-h|--help|help) usage; exit ;;
esac

# magic: if $1 isn't a known command, treat it as a label and default to status
case $cmd in
  status|kick|logs|info|show|load|unload|enable|disable|lint|run) LABEL=$2 ;;
  *) LABEL=$cmd; cmd=status ;;
esac

if [[ $cmd == status ]]; then
  launchctl list | awk -v pat="com\\.dennis\\..*$LABEL" 'NR==1 || $3 ~ pat'
  exit
fi

if [[ -n $LABEL ]]; then
  matches=($AGENT_DIR/com.dennis.*$LABEL*.plist(N))
  case ${#matches} in
    0) die "no agent matching '$LABEL' in $AGENT_DIR" ;;
    1) LABEL=${matches[1]:t:r} ;;
    *) echo "multiple matches for '$LABEL':" >&2
       select sel in ${matches:t:r}; do
         [[ -n $sel ]] && { LABEL=$sel; break; }
         die "no selection"
       done ;;
  esac
else
  pick
fi
PLIST=$AGENT_DIR/$LABEL.plist

case $cmd in
  kick)    launchctl kickstart -k "$DOMAIN/$LABEL" ;;
  info)    launchctl print "$DOMAIN/$LABEL" ;;
  show)    cat "$PLIST" ;;
  load)    launchctl bootstrap "$DOMAIN" "$PLIST" ;;
  unload)  launchctl bootout "$DOMAIN/$LABEL" ;;
  enable)  launchctl enable "$DOMAIN/$LABEL" ;;
  disable) launchctl disable "$DOMAIN/$LABEL" ;;
  lint)    plutil -lint "$PLIST" ;;
  logs)
    found=0
    seen=""
    for key in StandardOutPath StandardErrorPath; do
      p=$(plutil -extract $key raw "$PLIST" 2>/dev/null) || continue
      found=1
      [[ $seen == *":$p:"* ]] && continue
      seen="$seen:$p:"
      echo "====== $key: $p ======"
      tail -20 "$p" 2>/dev/null || echo "(log file not created yet)"
      echo
    done
    (( found )) || echo "no StandardOutPath/StandardErrorPath defined in $PLIST"
    ;;
  run)
    n=$(plutil -extract ProgramArguments raw "$PLIST" 2>/dev/null) || die "no ProgramArguments in $PLIST"
    args=()
    for ((i=0; i<n; i++)); do
      args+=("$(plutil -extract ProgramArguments.$i raw "$PLIST")")
    done
    echo "running: ${(q)args[@]}" >&2
    "${args[@]}"
    ;;
  *) die "unknown command: $cmd" ;;
esac
