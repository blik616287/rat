#!/bin/bash
# Zrok health check and auto-repair script (macOS)
# The launchd counterpart of zrok-health-check.sh. setup-zrok-ssh-macos.sh
# installs it as a LaunchDaemon that runs every 5 minutes.
#
# Usage: ./zrok-health-check-macos.sh <zrok-enable-token> <share-name>
#        ./zrok-health-check-macos.sh --env-file <path>
#
# The env file (written by setup-zrok-ssh-macos.sh) holds ZROK_ENABLE_TOKEN and
# ZROK_SHARE_NAME, which keeps the token out of the world-readable plist. When
# run as root, zrok commands run as the env file's owner so they use that user's
# ~/.zrok environment rather than root's.

set -euo pipefail

LABEL="io.rat.zrok-ssh"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
ZROK_BIN="${ZROK_BIN:-/usr/local/bin/zrok}"

if [ "${1:-}" = "--env-file" ]; then
    ENV_FILE="${2:-}"
    if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
        echo "ERROR: env file not found: ${ENV_FILE}"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    ZROK_TOKEN="${ZROK_ENABLE_TOKEN:-}"
    SHARE_NAME="${ZROK_SHARE_NAME:-}"
    ZROK_USER="$(stat -f %Su "$ENV_FILE")"
else
    ZROK_TOKEN="${1:-}"
    SHARE_NAME="${2:-}"
    ZROK_USER="$(id -un)"
fi

if [ -z "$ZROK_TOKEN" ] || [ -z "$SHARE_NAME" ]; then
    echo "Usage: $0 <zrok-enable-token> <share-name>"
    echo "       $0 --env-file <path>"
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    ZROK_HOME="$(dscl . -read "/Users/${ZROK_USER}" NFSHomeDirectory | awk '{print $2}')"
else
    SUDO="sudo"
    ZROK_HOME="$HOME"
fi
LOG_FILE="${ZROK_HOME}/Library/Logs/rat/zrok-ssh.log"
OFFSET_FILE="${ZROK_HOME}/Library/Logs/rat/.zrok-ssh.log.offset"
NEEDS_RESTART=false

log() { echo "[$(date -Iseconds)] $*"; }

# Run zrok as the share's owner under a pseudo-TTY: launchd jobs have no
# controlling terminal, and zrok fails with "open /dev/tty" without one.
# BSD script(1) echoes a stray "^D" when stdin is not a tty, so strip it.
zrok_pty() {
    if [ -z "$SUDO" ] && [ "$ZROK_USER" != "root" ]; then
        sudo -u "$ZROK_USER" -H script -q /dev/null "$ZROK_BIN" "$@" < /dev/null
    else
        script -q /dev/null "$ZROK_BIN" "$@" < /dev/null
    fi 2>&1 | tr -d '\r\b' | sed 's/^\^D//'
}

svc_loaded() { $SUDO launchctl print "system/${LABEL}" > /dev/null 2>&1; }
# Capture before grepping: under pipefail, grep -q exiting early can SIGPIPE the
# writer and make a match look like a failure.
svc_running() {
    local state
    state=$($SUDO launchctl print "system/${LABEL}" 2>/dev/null || true)
    echo "$state" | grep -q "state = running"
}
# The service is KeepAlive, so killing it just respawns it; unload it instead.
svc_stop() { $SUDO launchctl bootout "system/${LABEL}" 2>/dev/null || true; }
svc_start() {
    if svc_loaded; then
        $SUDO launchctl kickstart -k "system/${LABEL}"
    else
        $SUDO launchctl bootstrap system "$PLIST"
    fi
    sleep 3
    svc_running
}

# Count auth errors logged by the share since the previous run. The log has no
# wall-clock timestamps, so track how far we read last time instead of using
# journalctl's "--since 5 minutes ago".
recent_auth_errors() {
    [ -f "$LOG_FILE" ] || { echo 0; return; }
    local size offset
    size=$(stat -f %z "$LOG_FILE")
    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    [ "$offset" -le "$size" ] || offset=0
    tail -c +"$((offset + 1))" "$LOG_FILE" | grep -c "INVALID_AUTH\|UNAUTHORIZED" || true
    # launchd appends to the log, so it is safe to truncate it in place.
    if [ "$size" -gt 5242880 ]; then
        : > "$LOG_FILE"
        size=0
    fi
    # Keep the offset file owned by the share's user so a manual, non-root run
    # can still update it after the root LaunchDaemon has created it.
    echo "$size" > "$OFFSET_FILE" 2>/dev/null || true
    [ -n "$SUDO" ] || chown "$ZROK_USER" "$OFFSET_FILE" 2>/dev/null || true
}

# Test 1: Is zrok enabled?
STATUS_OUTPUT=$(zrok_pty status || true)
if ! echo "$STATUS_OUTPUT" | grep -q "Account Token.*<<SET>>"; then
    log "REPAIR: zrok not enabled"
    svc_stop
    zrok_pty enable "$ZROK_TOKEN"
    log "zrok enabled"
    NEEDS_RESTART=true
fi

# Test 2: Fetch the API overview once, and decide whether we can trust it.
#
# This call fails constantly for transient reasons that have nothing to do with
# our share: DNS blips ("no such host"), and 502/503/504 from the zrok
# controller. Treating any unusable output as "the share is gone" turns a
# 30-second network blip into a permanently deleted share. So: fail closed. If
# we cannot positively confirm what the API thinks, we change nothing.
set +e
OVERVIEW_OUTPUT=$(zrok_pty overview)
OVERVIEW_RC=$?
set -e

if [ "$NEEDS_RESTART" = false ]; then
    if echo "$OVERVIEW_OUTPUT" | grep -qi "INVALID_AUTH\|UNAUTHORIZED\|unable to load\|cannot get current identity"; then
        # A real authentication failure: the identity is stale, re-enrol.
        log "REPAIR: zrok identity stale, re-enabling..."
        svc_stop
        zrok_pty disable || true
        zrok_pty enable "$ZROK_TOKEN"
        log "zrok re-enabled"
        NEEDS_RESTART=true
    elif [ "$OVERVIEW_RC" -ne 0 ] || ! echo "$OVERVIEW_OUTPUT" | grep -q '"environments"'; then
        # Transient failure. We do NOT know the state of our share, so we must
        # not touch the tunnel or the account. A running tunnel keeps running.
        log "SKIP: zrok API did not return a usable overview this cycle (rc=${OVERVIEW_RC})"
        log "SKIP: ${OVERVIEW_OUTPUT}"
        log "SKIP: leaving tunnel and account state untouched; will retry next cycle"
        exit 0
    fi
fi

# Test 3: The overview is trustworthy. Is our reserved share actually absent?
if [ "$NEEDS_RESTART" = false ]; then
    if ! echo "$OVERVIEW_OUTPUT" | grep -q "\"shareToken\":\"${SHARE_NAME}\""; then
        log "REPAIR: share '${SHARE_NAME}' absent from a valid API response, recreating..."

        # Reserve FIRST, and never "release and retry": a failing reserve usually
        # means the controller is unhealthy, not a name conflict, and releasing
        # on that assumption destroys a share that is still live.
        if zrok_pty reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output; then
            log "share re-created"
            NEEDS_RESTART=true
        else
            log "ERROR: could not reserve '${SHARE_NAME}'"
            log "ERROR: NOT releasing the share -- if it still exists server-side a"
            log "ERROR: release would delete it for good. Leaving everything as-is."
            exit 1
        fi
    fi
fi

# Test 4: Is the service healthy or does it need a (re)start?
if [ "$NEEDS_RESTART" = true ]; then
    log "REPAIR: (re)starting ${LABEL}..."
    if svc_start; then
        log "${LABEL} started"
    else
        log "ERROR: ${LABEL} failed to start"
        exit 1
    fi
elif svc_running; then
    RECENT_ERRORS=$(recent_auth_errors)
    if [ "$RECENT_ERRORS" -gt 3 ]; then
        log "REPAIR: ${LABEL} unhealthy (${RECENT_ERRORS} auth errors since last check), restarting..."
        if svc_start; then
            log "${LABEL} restarted"
        else
            log "ERROR: ${LABEL} failed to restart"
            exit 1
        fi
    else
        log "OK: ${LABEL} healthy"
    fi
else
    log "REPAIR: ${LABEL} not running, starting..."
    if svc_start; then
        log "${LABEL} started"
    else
        log "ERROR: ${LABEL} failed to start"
        exit 1
    fi
fi

log "OK: all checks passed"
