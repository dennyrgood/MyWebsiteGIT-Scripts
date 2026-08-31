I have an iCloud Mail account (SMTP AUTH, app-specific password, smtp.mail.me.com:587,
STARTTLS) that I use to send outbound alert emails from a fleet of ~11 machines via
PowerShell's Send-MailMessage (Windows) and msmtp (Mac/Linux). The SAME Apple ID +
SAME app-specific password works reliably from: 3 Macs, 2 Ubuntu boxes, and 5 of 7
Windows 11 boxes. On exactly 2 of the 7 Windows boxes, every send attempt is rejected
by Apple's SMTP server post-EHLO/STARTTLS with:

  5.7.1 <PTR-of-client-ip>: Client host rejected: Access denied

This is 100% deterministic and reproducible (10/10 failures in a scripted burst test)
on those two specific Windows boxes, while an identical burst test from a working
Windows box (same account, same script, same network in one case) succeeds 10/10.

What I've already ruled out:
- Typo'd credentials: verified the exact decrypted username matches on the failing box.
- Account-wide rate limiting: fired 10 rapid sends from a WORKING box with zero failures.
- Destination/DNS: smtp.mail.me.com resolves via an Akamai CNAME chain
  (smtp.mail.me.com -> smtp.mail.me.com.akadns.net -> a regional
  outbound.<code>.icloud.com), and this DOES differ between machines (e.g. one box
  consistently connects to outbound.pv.icloud.com, a working box to outbound.ci.icloud.com
  or outbound.mr.icloud.com at different times) -- but I don't think this is the actual
  cause; it may be a red herring / just correlation, not causation. I need something more
  concrete than "different Apple front-end node" as an explanation, since that alone
  doesn't obviously explain why the SAME node label would behave differently for one
  account vs another, or why re-pointing Send-MailMessage's -SmtpServer directly at the
  "known good" hostname (outbound.ci.icloud.com) from the failing box still resulted in
  NO email actually arriving, even though Send-MailMessage reported success (exit 0, no
  exception) -- i.e. either silent server-side accept-and-discard, or the hostname
  override didn't actually change the physical route (anycast IP routing regardless of
  the DNS name requested).
- IPv6 involvement: smtp.mail.me.com has no AAAA record, so this isn't an IPv4/IPv6 path
  divergence.
- Source IP: both failing boxes are on normal residential ISP connections (different
  ISPs, different physical locations, different routers) -- ruled out ISP/router-level
  blocking because at EACH location, a second machine on the exact same LAN/router (same
  public IP, confirmed via ipify.org) sends successfully while the first one always fails.
- OS build, PowerShell version, TLS SecurityProtocol setting, Windows Defender state: all
  identical (diffed directly) between one failing box and one working box on the same LAN.
- Port 465 (implicit TLS): not even reachable (connection failure) from a failing box,
  separate issue, likely ISP-blocked, probably unrelated to the 587 rejection.

What I have NOT yet checked / am looking for real expertise on:
- What ELSE about a specific Windows machine (registry, .NET networking stack config,
  Winsock LSP layering, a stale/duplicate network profile, TCP/IP fingerprint /
  TCP options Windows sends, Nagle/autotuning settings, a leftover VPN/security-suite
  network filter driver even after uninstall, WFP filters, etc.) could make Apple's
  mail submission servers apply a DIFFERENT anti-abuse verdict to that machine's
  connections specifically, given identical account, identical LAN/WAN IP as a sibling
  machine that works fine, and identical high-level OS/software versions?
- Whether "Client host rejected: Access denied" from Apple's iCloud SMTP is EVER actually
  about something other than the connecting IP's PTR/reputation -- e.g. tied to a TLS
  client fingerprint (JA3/JA4-style), a stale/cached negative reputation tied to something
  machine-specific that got cached against that machine's IP+account combo from a much
  earlier failed attempt, or an Apple-side per-device/per-app-password anomaly flag.
- Whether pinning -SmtpServer to a specific outbound.<code>.icloud.com hostname actually
  guarantees a different anycast destination, or whether Apple's routing is IP-anycast
  and the hostname is cosmetic -- and if there's a way to actually force/verify a
  different backend node is used.
- Real-world reports of this exact "Client host rejected: Access denied" message from
  Apple's smtp.mail.me.com specifically (not Gmail/Outlook), what typically resolves it,
  and whether it's known to be silently-drop (accept then discard) rather than a hard
  bounce in some cases.

Please help me find the actual root cause and a real fix -- not another guess to test
blindly. I'm specifically skeptical that "different Apple front-end node" is sufficient
explanation on its own; there must be something about these two specific Windows boxes
causing THEM to be treated differently by whatever Apple backend they land on.
