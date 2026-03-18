#!/bin/bash
# Zrok health check and auto-repair script
# Designed to run as a systemd timer or cron job.
# If the zrok identity is stale or the share is missing, it re-enables and re-creates.
#
# Usage: ./zrok-health-check.sh <zrok-enable-token> <share-name>

set -euo pipefail

ZROK_TOKEN="${1:-}"
SHARE_NAME="${2:-}"

if [ -z "$ZROK_TOKEN" ] || [ -z "$SHARE_NAME" ]; then
    echo "Usage: $0 <zrok-enable-token> <share-name>"
    exit 1
fi

log() { echo "[$(date -Iseconds)] $*"; }

# Test 1: Is zrok enabled?
if ! zrok status 2>&1 | grep -q "Account Token.*<<SET>>"; then
    log "REPAIR: zrok not enabled, enabling..."
    zrok enable "$ZROK_TOKEN"
    log "zrok enabled"
fi

# Test 2: Can we reach the zrok API? (catches stale Ziti identity)
if ! zrok overview >/dev/null 2>&1; then
    log "REPAIR: zrok identity stale, re-enabling..."
    zrok disable 2>/dev/null || true
    zrok enable "$ZROK_TOKEN"
    log "zrok re-enabled"
fi

# Test 3: Does our share still exist?
if ! zrok overview 2>&1 | grep -q "$SHARE_NAME"; then
    log "REPAIR: share '${SHARE_NAME}' missing, re-creating..."
    zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output
    log "share re-created"
fi

# Test 4: Is the systemd service actually healthy?
# The process can be alive but stuck in auth-failure loops.
if systemctl is-active --quiet zrok-ssh.service; then
    RECENT_ERRORS=$(journalctl -u zrok-ssh.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "INVALID_AUTH\|UNAUTHORIZED\|not found" || true)
    if [ "$RECENT_ERRORS" -gt 3 ]; then
        log "REPAIR: zrok-ssh service unhealthy (${RECENT_ERRORS} auth errors in last 5 min), restarting..."
        sudo systemctl restart zrok-ssh.service
        sleep 3
        if systemctl is-active --quiet zrok-ssh.service; then
            log "zrok-ssh service restarted"
        else
            log "ERROR: zrok-ssh service failed to restart"
            exit 1
        fi
    else
        log "OK: zrok-ssh service healthy"
    fi
else
    log "REPAIR: zrok-ssh service not running, starting..."
    sudo systemctl start zrok-ssh.service
    sleep 3
    if systemctl is-active --quiet zrok-ssh.service; then
        log "zrok-ssh service started"
    else
        log "ERROR: zrok-ssh service failed to start"
        exit 1
    fi
fi

log "OK: all checks passed"
