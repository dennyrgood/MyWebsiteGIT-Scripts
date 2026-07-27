# Runbook — msmtp credential rotation + root-mail aliasing (fleet)

**Applies to:** any box that sends fleet mail via msmtp (currently WorkBenchUnix, ChatWorkhorseUnix).
**Per-box assets:** each box has its OWN `etc-aliases` + `install.msmtp.aliases.sh` in its machine dir
(`WorkBenchUnix/`, `ChatWorkhorseUnix/`); each installer points at its own dir's `etc-aliases`.
This runbook is copied into both machine dirs — keep the copies in sync if you edit it.
**Created:** 2026-07-23. **Updated:** 2026-07-24 (Step 2 now verifies the edit actually saved — see Postmortem).

## Why this exists

Two problems were found on WorkBenchUnix on 2026-07-23:

1. **Leaked SMTP credential.** `/etc/msmtprc` stored the iCloud app-specific password in plaintext and was world-readable (mode 644); the value leaked into a Claude Code transcript (which is sent to Anthropic's API and stored in a local session file — treat as exposed). The **same** app-specific password was reused on ChatWorkhorseUnix, so both boxes were affected. Mechanism, confirmed 2026-07-24: a `sed -E 's/^(password).*/\1 <redacted>/' /etc/msmtprc` that *printed the whole file* while redacting only lines starting at column zero. WBU's config is indented, so `    password …` never matched the anchor and was emitted verbatim. The 644 mode is why no `sudo` was needed to read it at all.
2. **Bouncing root-mail.** `/usr/sbin/sendmail` is a symlink to msmtp, but with no `aliases` directive and no `/etc/aliases`, any system mail to bare `root` (sudo auth alerts, cron job errors, smartd/mdadm events) was rejected by iCloud with `504 need fully-qualified address`. So those signals were silently lost.

This runbook rotates to **per-box** app-specific passwords (so a future leak only forces rotating one box), locks `/etc/msmtprc` to `600`, and aliases `root` → a real address so system mail delivers.

## Golden rules

- **Type the new password only into an editor opened under `sudo`** — never into a shell command, `echo`, `sed`, or anything that lands in shell history or a transcript.
- **Create + verify new passwords on every box BEFORE revoking the old one**, so mail never breaks mid-rotation.
- **A successful send does NOT prove the rotation happened.** The old password keeps working until Step 4 revokes it, so `EX_OK` is equally consistent with "new password works" and "you never saved the edit." Prove the write landed with mtime + hash (Step 2), not with the send test.
- **Never redact a secret by rewriting the line — exclude the line instead.** Anchored substitutions fail *open*: `sed -E 's/^(password).*/\1 <redacted>/'` does not match an indented `    password …` line, so it prints the credential verbatim while looking like it worked. Use `grep -vi password` (matches anywhere on the line) or hash the value.

---

## Prerequisite — publish the per-box assets

Step 5 has each box run the installer from its own machine dir, so those files must be committed and pushed **first** (the scripts repo is shared/cloned on every box). They carry no secret (`etc-aliases` is just an address map):
```
cd /home/dhm/repos/scripts
git status --short                 # expect: WorkBenchUnix/ + ChatWorkhorseUnix/ msmtp files
./sync-this "msmtp: per-box credential rotation + root-mail aliasing (fleet)"
```

## Step 0 — Confirm blast radius

On **each** box, fingerprint the password rather than printing it, and note the current state:
```
sudo ls -la /etc/msmtprc /etc/aliases /etc/msmtprc.bak.* 2>&1
sudo grep -nE '^[[:space:]]*(defaults|aliases)' /etc/msmtprc
sudo awk 'tolower($1)=="password"{print $2}' /etc/msmtprc | sha256sum
```
**Write down each box's hash and the `/etc/msmtprc` size + mtime** — Step 2 compares against them.
Boxes whose hashes **match each other** share one password, so a leak on any of them
compromises all of them; every matching box must be rotated. (Per-box passwords are
recommended regardless.)

Do **not** run `sudo grep -i password /etc/msmtprc` — it prints the credential into the
terminal, shell scrollback, and any agent transcript, which is the exact leak this
runbook exists to clean up. The hash is safe to paste anywhere.

## Step 1 — Generate new app-specific passwords (GUI)

1. Browser → **https://account.apple.com** → sign in as the sending Apple ID → approve 2FA.
2. **Sign-In and Security → App-Specific Passwords**.
3. Generate **one per box**, labeled by host, e.g. `msmtp-workbenchunix`, `msmtp-chatworkhorseunix`.
4. Apple shows each value once (`abcd-efgh-ijkl-mnop`). Keep the tab open for Step 2; do **not** paste into a terminal.
5. **Do not revoke anything yet.**

## Step 2 — Update each box (CLI, edit-in-place)

Run on **every** box, using that box's own new password. Run these one line at a time —
pasting a wrapped multi-line block splits the `sendmail` recipient onto its own line and
you get `sendmail: no recipients found` followed by `command not found`.
```
sudo cp -a /etc/msmtprc /etc/msmtprc.bak.$(date +%F)   # backup
sudo chmod 600 /etc/msmtprc.bak.$(date +%F)            # cp -a preserves 644 — the backup holds the password too
sudo vi /etc/msmtprc                                    # replace the password value only — type it, then :wq
sudo chmod 600 /etc/msmtprc                             # lock down (contains the password)
```

**2a. Prove the edit actually saved** (do this before the send test):
```
sudo ls -la /etc/msmtprc                                # mtime must be NOW; unchanged mtime = you didn't write
sudo awk 'tolower($1)=="password"{print $2}' /etc/msmtprc | sha256sum
```
- mtime still showing the pre-edit timestamp → the editor exited without writing. Redo the edit.
  (`chmod` bumps ctime, not mtime, so a `chmod` in between does not mask this.)
- hash unchanged from Step 0 → same password still in place. Redo the edit.
- hash equal to another box's → you reused one password across boxes. Redo with a distinct one.

Note the file size alone proves nothing: Apple app-specific passwords are fixed-length
(`abcd-efgh-ijkl-mnop`), so a real swap leaves the byte count identical.

**2b. Prove the new password authenticates:**
```
echo "new-pw test $(date)" | sudo /usr/sbin/sendmail -i dennyrgood@yahoo.com
tail -1 /var/log/msmtp.log                              # expect exitcode=EX_OK
```
`smtpstatus=535 authentication failed` → typo; re-edit. Restore point: `sudo cp -a /etc/msmtprc.bak.<date> /etc/msmtprc`.
Remember this test passes on the **old** password too until Step 4 — 2a is what proves rotation, not this.

## Step 3 — Verify every box sends OK

Confirm `EX_OK` + inbox arrival on **all** boxes before continuing.

## Step 4 — Revoke the OLD shared password (GUI)

Only now: at account.apple.com, remove the pre-rotation entry. This kills the leaked value on every box at once.
Also delete any app-specific passwords you generated but never used.

Then drop the plaintext backups — on **every** box, once revocation has landed (they are the
rollback path until then, so not before):
```
sudo rm /etc/msmtprc.bak.<date>
```
They are `600`, but each still holds the old password in cleartext.

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
| Send test `EX_OK` but mtime/hash unchanged | Editor exited without writing — you are still on the OLD password | Redo Step 2, `:wq` in vi, re-check 2a. **Do not proceed to Step 4** — revoking would break mail on every unrotated box at once |
| Both boxes' hashes identical after rotation | Same new password reused across boxes | Redo Step 2 on one box with a distinct password |
| `sendmail: no recipients found` + `<addr>: command not found` | A wrapped multi-line paste split the recipient onto its own line | Re-run the `sendmail` line by itself |
| Installer step 4 shows no `aliases` line | `defaults` line isn't exactly bare `defaults`, so the installer's `sed` no-op'd | Add `aliases /etc/aliases` to the defaults block by hand |
| Mail to `root` still `recipients=root ... 504` | Aliases not applied | `sudo grep aliases /etc/msmtprc`; `sudo cat /etc/aliases`; re-run Step 5 |
| `msmtp: ... must have no more than user read/write permissions` | Config not `600` | `sudo chmod 600 /etc/msmtprc` |
| No mail, no log line at all | `sendmail` symlink / msmtp missing | `ls -la /usr/sbin/sendmail` (→ `../bin/msmtp`) |

All msmtp sends are logged to `/var/log/msmtp.log` (`exitcode=EX_OK` = delivered to the SMTP server).

---

## Postmortem — 2026-07-24 execution

Root-mail aliasing (Steps 5–6) went clean on both boxes first try. The rotation did not,
and the near-miss is why Step 2a exists:

- The editor was opened on both boxes and closed **without saving**. Both send tests still
  returned `EX_OK`, because the old password was still valid — revocation hadn't happened yet.
  Every signal the runbook asked for looked green while nothing had actually rotated.
- It was caught by comparing `ls -la` output across the session: size *and* mtime were
  unchanged on both boxes, and the only byte delta all day (392→417 on WBU, 344→369 on CWHU)
  was exactly the +25-byte `    aliases /etc/aliases` line the installer added.
- Had Step 4 run at that point, the revocation would have killed mail on **both** boxes
  simultaneously — the precise failure the "verify before revoking" rule is meant to prevent,
  defeated by a verification step that couldn't actually detect the failure.

Final state: WBU and CWHU on distinct per-box passwords (verified by comparing Step 2a hashes
against each other and against the old shared value — hashes deliberately not recorded here,
this repo is public), `/etc/msmtprc` `600` on both, root-mail aliasing live, old shared
password revoked, backups removed.

Also worth knowing: `cwh` is the **Windows** box (`chatworkhorse`); the Ubuntu VM is `cwhu`
(`chatworkhorseunix`). Only the `…unix` boxes are in scope for this runbook.
