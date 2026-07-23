# Runbook — msmtp credential rotation + root-mail aliasing (fleet)

**Applies to:** any box that sends fleet mail via msmtp (currently WorkBenchUnix, ChatWorkhorseUnix).
**Per-box assets:** each box has its OWN `etc-aliases` + `install.msmtp.aliases.sh` in its machine dir
(`WorkBenchUnix/`, `ChatWorkhorseUnix/`); each installer points at its own dir's `etc-aliases`.
This runbook is copied into both machine dirs — keep the copies in sync if you edit it.
**Created:** 2026-07-23.

## Why this exists

Two problems were found on WorkBenchUnix on 2026-07-23:

1. **Leaked SMTP credential.** `/etc/msmtprc` stored the iCloud app-specific password in plaintext and was world-readable (mode 644); the value leaked into a Claude Code transcript (which is sent to Anthropic's API and stored in a local session file — treat as exposed). The **same** app-specific password was reused on ChatWorkhorseUnix, so both boxes were affected.
2. **Bouncing root-mail.** `/usr/sbin/sendmail` is a symlink to msmtp, but with no `aliases` directive and no `/etc/aliases`, any system mail to bare `root` (sudo auth alerts, cron job errors, smartd/mdadm events) was rejected by iCloud with `504 need fully-qualified address`. So those signals were silently lost.

This runbook rotates to **per-box** app-specific passwords (so a future leak only forces rotating one box), locks `/etc/msmtprc` to `600`, and aliases `root` → a real address so system mail delivers.

## Golden rules

- **Type the new password only into an editor opened under `sudo`** — never into a shell command, `echo`, `sed`, or anything that lands in shell history or a transcript.
- **Create + verify new passwords on every box BEFORE revoking the old one**, so mail never breaks mid-rotation.

---

## Prerequisite — publish the per-box assets

Step 5 has each box run the installer from its own machine dir, so those files must be committed and pushed **first** (the scripts repo is shared/cloned on every box). They carry no secret (`etc-aliases` is just an address map):
```
cd /home/dhm/repos/scripts
git status --short                 # expect: WorkBenchUnix/ + ChatWorkhorseUnix/ msmtp files
./sync-this "msmtp: per-box credential rotation + root-mail aliasing (fleet)"
```

## Step 0 — Confirm blast radius

On **each** box, check whether it uses the leaked password:
```
sudo grep -i password /etc/msmtprc
```
If the value matches the leaked one, that box must be rotated. (Per-box passwords are recommended regardless.)

## Step 1 — Generate new app-specific passwords (GUI)

1. Browser → **https://account.apple.com** → sign in as the sending Apple ID → approve 2FA.
2. **Sign-In and Security → App-Specific Passwords**.
3. Generate **one per box**, labeled by host, e.g. `msmtp-workbenchunix`, `msmtp-chatworkhorseunix`.
4. Apple shows each value once (`abcd-efgh-ijkl-mnop`). Keep the tab open for Step 2; do **not** paste into a terminal.
5. **Do not revoke anything yet.**

## Step 2 — Update each box (CLI, edit-in-place)

Run on **every** box, using that box's own new password:
```
sudo cp -a /etc/msmtprc /etc/msmtprc.bak.$(date +%F)   # backup
sudo nano /etc/msmtprc                                  # replace the password value only — type it
sudo chmod 600 /etc/msmtprc                             # lock down (contains the password)
sudo ls -la /etc/msmtprc                                # expect -rw------- root root

# prove the new password authenticates:
echo "new-pw test $(date)" | sudo /usr/sbin/sendmail -i dennyrgood@yahoo.com
tail -1 /var/log/msmtp.log                              # expect exitcode=EX_OK
```
`smtpstatus=535 authentication failed` → typo; re-edit. Restore point: `sudo cp -a /etc/msmtprc.bak.<date> /etc/msmtprc`.

## Step 3 — Verify every box sends OK

Confirm `EX_OK` + inbox arrival on **all** boxes before continuing.

## Step 4 — Revoke the OLD shared password (GUI)

Only now: at account.apple.com, remove the pre-rotation entry. This kills the leaked value on every box at once.

## Step 5 — Enable root-mail aliasing on each box (CLI)

Each box runs the installer from **its own machine dir** (pull first so it has the committed copy):
```
cd /home/dhm/repos/scripts && git pull --rebase

# on WorkBenchUnix:
sh /home/dhm/repos/scripts/WorkBenchUnix/install.msmtp.aliases.sh

# on ChatWorkhorseUnix:
sh /home/dhm/repos/scripts/ChatWorkhorseUnix/install.msmtp.aliases.sh
```
The installer: installs `/etc/aliases` (`root`/`default` → `dennyrgood@yahoo.com`), adds `aliases /etc/aliases` to the `/etc/msmtprc` defaults block (idempotent), re-asserts `chmod 600`, and sends a test to `root`.

## Step 6 — Verify aliasing on each box (CLI + GUI)

```
sudo grep -n aliases /etc/msmtprc      # -> aliases /etc/aliases
sudo cat /etc/aliases                  # -> root:/default: dennyrgood@yahoo.com
echo "root alias test $(date)" | sudo /usr/sbin/sendmail -i root
tail -1 /var/log/msmtp.log             # -> recipients=dennyrgood@yahoo.com ... EX_OK  (was: recipients=root ... 504)
```
GUI: confirm the `[<host>] msmtp root-alias test` message arrives (check Spam too).

## Step 7 — Final check

The per-box assets were already committed in the Prerequisite; nothing else here touches the repo (`/etc/msmtprc` and `/etc/aliases` live outside it and are never committed). Confirm the tree is clean:
```
cd /home/dhm/repos/scripts && git status --short
```

## Step 8 — (Optional) scrub local transcript copies

Rotation already neutralizes the leak; this is tidiness only. On the box where the leak occurred:
```
grep -rl '<leaked-value>' /home/dhm/.claude/projects/-home-dhm/ 2>/dev/null
clear && printf '\033[3J'      # clear scrollback in this terminal
```
Do **not** hand-edit the active Claude Code session `.jsonl` while a session is running (can corrupt it); do it after exit, or just rely on the revocation.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `smtpstatus=535 authentication failed` | Wrong password in `/etc/msmtprc` | Re-edit; or `sudo cp -a /etc/msmtprc.bak.<date> /etc/msmtprc` |
| Mail to `root` still `recipients=root ... 504` | Aliases not applied | `sudo grep aliases /etc/msmtprc`; `sudo cat /etc/aliases`; re-run Step 5 |
| `msmtp: ... must have no more than user read/write permissions` | Config not `600` | `sudo chmod 600 /etc/msmtprc` |
| No mail, no log line at all | `sendmail` symlink / msmtp missing | `ls -la /usr/sbin/sendmail` (→ `../bin/msmtp`) |

All msmtp sends are logged to `/var/log/msmtp.log` (`exitcode=EX_OK` = delivered to the SMTP server).
