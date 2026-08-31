#!/usr/bin/env python3
"""fleet_digest.py -- daily fleet nightly-summary digest.

Reads dennis.mathes@icloud.com's own INBOX (populated by every box's
*-nightly-summary script CC'ing itself -- see Send-FleetMail.ps1's -Cc param and
the equivalent msmtp Cc: header in the bash scripts) for recent nightly-summary
subjects, matches them against the known list of 13 boxes, and emails one report
of OK / NOT-OK / MISSING to dennyrgood@yahoo.com instead of 13 separate emails.

Built + proven working end-to-end 2026-08-31/09-01 (see chat history / commit log):
IMAP login via the existing msmtp Keychain credential, iCloud IMAP quirks (combined
SEARCH criteria strings return None instead of results; a zero-match SEARCH also
returns [None] rather than [b'']; no Sent folder exists for SMTP-submitted mail,
which is WHY this reads INBOX via a self-CC instead), and the timezone/midnight
rolling-window fix below.

Subject format used by every nightly-summary script (Windows ASCII "--",
Mac/Ubuntu real em-dash both handled):
  <emoji> <DisplayName> nightly YYYY-MM-DD <-- or em-dash> <reason>

Credential: reuses msmtp's existing passwordeval (macOS Keychain) -- never printed,
no new secret storage. Requires ~/.msmtprc with an "icloud" account block using
passwordeval (not a literal password line).

Usage:
  python3 fleet_digest.py            # print only
  python3 fleet_digest.py --send     # print AND email the report
  python3 fleet_digest.py --date 2026-08-31 [--send]   # specific day
"""
import argparse
import datetime
import email
import email.header
import imaplib
import re
import shlex
import subprocess
from pathlib import Path

# Sourced directly from each box's own nightly-summary script's $HOST /
# display-name variable -- not guessed. See scripts repo, 2026-08-31.
EXPECTED_HOSTS = [
    "AmsterdamDesktop", "ChatWorkhorse", "ImageBeast", "TravelBeast",
    "RemoteWS", "Surface3GC", "SurfaceGoLaptopGC",
    "WorkBenchUnix", "ChatWorkhorseUnix", "FleetNAS",
    "MacBook Air", "MacBook Air 2", "Mac Mini",
]

CHECK = "✅"
WARN = "⚠️"
# Handles both the ASCII "--" (Windows scripts, CLAUDE.md ASCII-only rule) and
# the real em-dash "—" (Mac/Ubuntu bash scripts) as the separator.
SUBJECT_RE = re.compile(
    r"^(?P<emoji>✅|⚠️)\s+(?P<host>.+?)\s+nightly\s+"
    r"(?P<date>\d{4}-\d{2}-\d{2})\s+(?:--|—)\s+(?P<reason>.+)$"
)


def get_credential():
    text = (Path.home() / ".msmtprc").read_text()
    block = re.search(r"account\s+icloud\b(.*?)(?=\naccount\s|\Z)", text, re.S).group(1)
    user = re.search(r"^\s*user\s+(\S+)", block, re.M).group(1)
    passwordeval = re.search(r'^\s*passwordeval\s+"(.+)"', block, re.M).group(1)
    password = subprocess.run(
        shlex.split(passwordeval), capture_output=True, text=True, check=True
    ).stdout.strip()
    return user, password


def decode_subject(raw):
    parts = email.header.decode_header(raw)
    out = ""
    for text, enc in parts:
        if isinstance(text, bytes):
            out += text.decode(enc or "utf-8", errors="replace")
        else:
            out += text
    return out


def fetch_todays_subjects(user, password, target_date):
    """Returns subjects from a ~30h rolling window ending at target_date's end of
    day, NOT an exact calendar-date match. The fleet spans UTC-4 (RemoteWS) to
    UTC+2 (mb) -- confirmed 2026-09-01 that near midnight, boxes in different
    timezones embed different calendar dates in their subject ("nightly 2026-08-31"
    vs "nightly 2026-09-01") for sends that are, in real terms, within minutes of
    each other. An exact-date IMAP SINCE/BEFORE window missed the earlier-dated ones
    entirely. Searching wider and de-duping to the latest subject per host (done in
    build_report) sidesteps timezone drift instead of trying to reconcile it. Those
    timezones are real physical locations (confirmed with the user), not
    misconfiguration, so this works around it rather than normalizing every box's
    clock or subject-date stamp to one timezone."""
    conn = imaplib.IMAP4_SSL("imap.mail.me.com", 993)
    conn.login(user, password)
    conn.select("INBOX")
    # SINCE is date-only (no time) per IMAP spec. Start 1 day before target_date to
    # cover the earliest-timezone box's midnight-crossing send; BEFORE is target_date
    # + 1 (exclusive upper bound) so we don't pull in tomorrow's early sends yet.
    since = (target_date - datetime.timedelta(days=1)).strftime("%d-%b-%Y")
    before = (target_date + datetime.timedelta(days=1)).strftime("%d-%b-%Y")
    # iCloud's IMAP server mishandles a single combined-criteria string (returns
    # None instead of proper results) -- pass each criterion as a separate arg.
    # Also confirmed: a zero-match SEARCH here returns data=[None], not the more
    # usual [b''] -- guard for that instead of crashing on .split().
    status, data = conn.search(None, "SINCE", since, "BEFORE", before, "SUBJECT", '"nightly"')
    subjects = []  # list of (subject, imap_internal_seq_num) -- seq num as a cheap
                   # recency tiebreaker within the window (higher = more recent)
    ids = data[0].split() if data and data[0] else []
    for num in ids:
        status, msg_data = conn.fetch(num, "(BODY[HEADER.FIELDS (SUBJECT)])")
        # msg_data is a list like [(b'<n> (BODY...', b'SUBJECT: ...\r\n\r\n'), b')'] --
        # find the tuple element (the trailing b')' isn't one) rather than assume
        # index [0].
        part = next((p for p in msg_data if isinstance(p, tuple)), None)
        if not part:
            continue
        raw = part[1].decode(errors="replace")
        subj_line = raw.split("\n", 1)[0]
        if subj_line.lower().startswith("subject:"):
            subj_line = subj_line[len("subject:"):].strip()
        subjects.append((decode_subject(subj_line), int(num)))
    conn.logout()
    return subjects


def build_report(subjects, target_date):
    # subjects: list of (subject_text, seq_num) from the rolling window -- de-dupe
    # to the highest seq_num (most recent) per host, since a host can legitimately
    # have 2 subjects in-window near midnight (yesterday's + today's, or a re-trigger).
    found = {}  # host -> (ok, reason, seq_num)
    unmatched = []
    for s, seq in subjects:
        m = SUBJECT_RE.match(s.strip())
        if not m:
            unmatched.append(s)
            continue
        host = m.group("host")
        ok = m.group("emoji") == CHECK
        if host not in found or seq > found[host][2]:
            found[host] = (ok, m.group("reason"), seq)

    ok_hosts = [h for h, (ok, _, _) in found.items() if ok]
    notok_hosts = [(h, r) for h, (ok, r, _) in found.items() if not ok]
    missing_hosts = [h for h in EXPECTED_HOSTS if h not in found]

    lines = []
    lines.append(f"Fleet nightly digest for {target_date.isoformat()}")
    lines.append(f"{len(ok_hosts)} OK, {len(notok_hosts)} NOT-OK, {len(missing_hosts)} MISSING (of {len(EXPECTED_HOSTS)} expected)")
    lines.append("")
    lines.append(f"OK ({len(ok_hosts)}):")
    for h in sorted(ok_hosts):
        lines.append(f"  {CHECK} {h}")
    lines.append("")
    lines.append(f"NOT-OK ({len(notok_hosts)}):")
    for h, r in sorted(notok_hosts):
        lines.append(f"  {WARN} {h} -- {r}")
    lines.append("")
    lines.append(f"MISSING ({len(missing_hosts)}) -- no nightly-summary email seen at all:")
    for h in sorted(missing_hosts):
        lines.append(f"  ? {h}")
    if unmatched:
        lines.append("")
        lines.append(f"Unmatched subjects seen (didn't parse as a nightly-summary -- informational):")
        for s in unmatched:
            lines.append(f"  {s}")

    counts = {"ok": len(ok_hosts), "notok": len(notok_hosts), "missing": len(missing_hosts)}
    return "\n".join(lines), counts


def send_report(user, password, to_addr, subject, body):
    import smtplib
    from email.mime.text import MIMEText

    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = to_addr

    with smtplib.SMTP("smtp.mail.me.com", 587) as s:
        s.starttls()
        s.login(user, password)
        s.sendmail(user, [to_addr], msg.as_bytes())


FLEET_DIGEST_TO = "dennyrgood@yahoo.com"

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", help="YYYY-MM-DD, defaults to today", default=None)
    ap.add_argument("--send", action="store_true", help="actually email the report (default: print only)")
    args = ap.parse_args()
    target_date = datetime.date.fromisoformat(args.date) if args.date else datetime.date.today()

    user, password = get_credential()
    subjects = fetch_todays_subjects(user, password, target_date)
    print(f"({len(subjects)} matching-subject email(s) found in INBOX for {target_date})\n")
    report, counts = build_report(subjects, target_date)
    print(report)

    if args.send:
        # Subject deliberately does NOT contain "nightly" -- the user filters the
        # individual per-box "nightly" emails into a folder manually, and this digest
        # must not get swept into that same filter.
        subject = (
            f"Fleet Digest {target_date.isoformat()} -- "
            f"{counts['ok']} OK / {counts['notok']} NOT-OK / {counts['missing']} MISSING"
        )
        send_report(user, password, FLEET_DIGEST_TO, subject, report)
        print(f"\nSent to {FLEET_DIGEST_TO}: {subject}")
