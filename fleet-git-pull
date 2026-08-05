#!/usr/bin/env bash
# Fleet-wide git pull: for each fleet host, fast-forward-pulls `scripts` and
# `fleet-configs` (or whatever --repos names) when they're behind their
# upstream. Skips any repo with uncommitted changes (dirty) rather than risk
# a conflict, and skips any repo that isn't a clean fast-forward.
#
# Usage: ./fleet-git-pull.sh [--dry-run] [--repos repo1,repo2] [host ...]
#   --dry-run          report what would be pulled, don't actually pull
#   --repos r1,r2      comma-separated repo names to consider (default: scripts,fleet-configs)
#   host ...           restrict to specific tailscale names (default: whole fleet)

set -uo pipefail

FLEET_HOSTS=(
  "imagebeast:win"
  "chatworkhorse:win"
  "travelbeast:win"
  "amsterdamdesktop:win"
  "denniss-macbook-air:mac"
  "denniss-2nd-macbook-air:mac"
  "surface3-gc:win"
  "mathes-mac-mini:mac"
  "remotews:win"
  "workbenchunix:ubuntu"
  "chatworkhorseunix:ubuntu"
)

host_os() {
  local h="$1" pair name os
  for pair in "${FLEET_HOSTS[@]}"; do
    name="${pair%%:*}"
    os="${pair##*:}"
    if [ "$name" = "$h" ]; then
      echo "$os"
      return 0
    fi
  done
  return 1
}

DRY_RUN=0
REPOS="scripts,fleet-configs"
HOSTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --repos) shift; REPOS="$1" ;;
    *) HOSTS+=("$1") ;;
  esac
  shift
done

if [ "${#HOSTS[@]}" -eq 0 ]; then
  for pair in "${FLEET_HOSTS[@]}"; do HOSTS+=("${pair%%:*}"); done
fi
IFS=$'\n' HOSTS=($(sort <<<"${HOSTS[*]}")); unset IFS

SELF_NAME=""
if command -v tailscale >/dev/null 2>&1; then
  SELF_NAME=$(tailscale status --self --json 2>/dev/null | grep -m1 '"DNSName"' | sed -E 's/.*"DNSName": *"([^."]+).*/\1/')
fi
[ -z "$SELF_NAME" ] && SELF_NAME=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')

remote_bash_script() {
  local repos_csv="$1" dry="$2"
  cat <<EOF
IFS=',' read -ra REPO_NAMES <<< "$repos_csv"
for root in "\$HOME/repos" "/c/repos" "/d/repos"; do
  [ -d "\$root" ] && REPO_ROOT="\$root" && break
done
[ -z "\${REPO_ROOT:-}" ] && exit 0
for name in "\${REPO_NAMES[@]}"; do
  repo="\$REPO_ROOT/\$name"
  [ -d "\$repo/.git" ] || continue
  cd "\$repo" || continue
  git fetch --quiet 2>/dev/null
  branch=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  dirty=\$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  behind=\$(git rev-list --count HEAD..@{u} 2>/dev/null)
  if [ "\$behind" = "0" ] || [ -z "\$behind" ]; then
    echo "\$name|\$branch|skip|up-to-date"
    continue
  fi
  if [ "\$dirty" != "0" ]; then
    echo "\$name|\$branch|skip|dirty(\$dirty)-manual-review-needed"
    continue
  fi
  if [ "$dry" = "1" ]; then
    echo "\$name|\$branch|would-pull|\$behind-commits-behind"
    continue
  fi
  if git merge-base --is-ancestor HEAD "@{u}" 2>/dev/null && git pull --ff-only --quiet 2>/dev/null; then
    echo "\$name|\$branch|pulled|\$behind-commits"
  else
    echo "\$name|\$branch|failed|not-a-fast-forward-or-pull-error"
  fi
done
EOF
}

remote_ps_script() {
  local repos_csv="$1" dry="$2"
  cat <<EOF
\$ProgressPreference = 'SilentlyContinue'
\$repoNames = "$repos_csv" -split ","
\$roots = @("C:\repos","D:\repos")
\$repoRoot = \$roots | Where-Object { Test-Path \$_ } | Select-Object -First 1
if (-not \$repoRoot) { exit 0 }
foreach (\$name in \$repoNames) {
  \$repo = Join-Path \$repoRoot \$name
  if (-not (Test-Path (Join-Path \$repo ".git"))) { continue }
  Push-Location \$repo
  git fetch --quiet 2>\$null
  \$branch = git rev-parse --abbrev-ref HEAD 2>\$null
  \$dirty = (git status --porcelain 2>\$null | Measure-Object -Line).Lines
  \$behind = (git rev-list --count 'HEAD..@{u}' 2>\$null)
  if ([string]::IsNullOrEmpty(\$behind) -or \$behind -eq "0") {
    Write-Output "\$name|\$branch|skip|up-to-date"
  } elseif (\$dirty -ne 0) {
    Write-Output "\$name|\$branch|skip|dirty(\$dirty)-manual-review-needed"
  } elseif ("$dry" -eq "1") {
    Write-Output "\$name|\$branch|would-pull|\$behind-commits-behind"
  } else {
    git merge-base --is-ancestor HEAD '@{u}' 2>\$null
    if (\$LASTEXITCODE -eq 0) {
      git pull --ff-only --quiet 2>\$null
      if (\$LASTEXITCODE -eq 0) {
        Write-Output "\$name|\$branch|pulled|\$behind-commits"
      } else {
        Write-Output "\$name|\$branch|failed|pull-error"
      }
    } else {
      Write-Output "\$name|\$branch|failed|not-a-fast-forward"
    }
  }
  Pop-Location
}
EOF
}

printf "%-24s %-16s %-10s %-10s %s\n" "HOST" "REPO" "BRANCH" "RESULT" "DETAIL"
printf "%-24s %-16s %-10s %-10s %s\n" "----" "----" "------" "------" "------"

for host in "${HOSTS[@]}"; do
  if ! os=$(host_os "$host"); then
    echo "!! unknown host: $host (skipping)" >&2
    continue
  fi

  if [ "$host" = "$SELF_NAME" ]; then
    script=$(remote_bash_script "$REPOS" "$DRY_RUN")
    output=$(bash -c "$script" 2>/dev/null)
  elif [ "$os" = "win" ]; then
    script=$(remote_ps_script "$REPOS" "$DRY_RUN")
    encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
    if ! output=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "powershell -NoProfile -EncodedCommand $encoded" 2>/dev/null); then
      printf "%-24s %s\n" "$host" "UNREACHABLE or SSH error"
      continue
    fi
  else
    script=$(remote_bash_script "$REPOS" "$DRY_RUN")
    if ! output=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "bash -s" <<< "$script" 2>/dev/null); then
      printf "%-24s %s\n" "$host" "UNREACHABLE or SSH error"
      continue
    fi
  fi

  if [ -z "$output" ]; then
    printf "%-24s %s\n" "$host" "(no target repos found)"
    continue
  fi

  while IFS='|' read -r repo branch result detail; do
    repo="${repo%$'\r'}"; branch="${branch%$'\r'}"; result="${result%$'\r'}"; detail="${detail%$'\r'}"
    [ -z "$repo" ] && continue
    printf "%-24s %-16s %-10s %-10s %s\n" "$host" "$repo" "$branch" "$result" "$detail"
  done <<< "$output"
done
