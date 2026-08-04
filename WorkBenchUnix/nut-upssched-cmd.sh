#!/bin/bash
# upssched CMDSCRIPT for WorkBenchUnix — installed to /etc/nut/upssched-cmd
# Created: 2026-08-04 UTC
#
# Invoked by upssched with the timer/command name as $1. See nut-upssched.conf for
# why the trigger is elapsed time rather than a battery percentage.
#
# Everything here goes to syslog rather than a private log file: upsmon and
# upssched already log there, so a power event reads as one continuous story in
# `journalctl -t upssched-cmd -t nut-monitor`.

CASE_NAME="${1:-}"

log() { logger -t upssched-cmd "$*"; }

case "$CASE_NAME" in
    onbatt-shutdown)
        log "10 minutes on battery — initiating shutdown (running as $(id -un))"
        # `upsmon -c fsd` rather than calling clean.ubuntu.shutdown directly.
        #
        # This is the ending documented in `man 8 upssched`, and it matters for two
        # reasons. First, privilege: upssched is invoked from upsmon's unprivileged
        # half (user `nut`), which cannot power the machine off by itself — fsd
        # hands the job to upsmon's root parent, which owns SHUTDOWNCMD. Second,
        # ordering: fsd is the signal other NUT clients wait for, so any secondary
        # added later stops in the correct sequence instead of racing us.
        #
        # SHUTDOWNCMD in upsmon.conf is clean.ubuntu.shutdown, so the Immich
        # Compose stack still comes down gracefully before systemd takes over.
        if /usr/sbin/upsmon -c fsd; then
            log "upsmon -c fsd accepted — shutdown handed to upsmon's root parent."
        else
            log "ERROR: 'upsmon -c fsd' failed (exit $?). Machine NOT shutting down."
            log "ERROR: likely a privilege problem signalling upsmon. Check /run/nut/upsmon.pid ownership."
        fi
        ;;

    onbatt-notice)
        # Proves ONBATT reached upssched and the 10-minute timer is now running.
        # Without this, a working timer and a NOTIFYCMD that never fired produce
        # identical (empty) logs.
        log "ONBATT — 10-minute shutdown timer STARTED (running as $(id -un))"
        ;;

    online-notice)
        log "ONLINE — shutdown timer CANCELLED, mains are back."
        ;;

    commok-selftest)
        # Proves NOTIFYCMD -> upssched -> this script works, without a power cut.
        # Reports the effective user, which is the thing that decides whether the
        # real onbatt-shutdown path above can actually succeed.
        log "SELFTEST: upssched path is working. Running as user '$(id -un)'."
        if [ -r /run/nut/upsmon.pid ]; then
            log "SELFTEST: /run/nut/upsmon.pid is readable — 'upsmon -c fsd' should work."
        else
            log "SELFTEST: WARNING - /run/nut/upsmon.pid not readable as $(id -un)."
        fi
        ;;

    *)
        log "Unrecognised command '$CASE_NAME' — ignored."
        ;;
esac

exit 0
