#!/bin/bash
# Zrok setup script for SSH-only jump host (no VNC)
# Assumes SSH and the ubuntu user are already configured on the box.
#
# Usage: curl -sSL <url> | bash -s -- <zrok-enable-token> [share-name]
#
# Example: curl -sSL <url> | bash -s -- YOUR_TOKEN_HERE jumphostssh

set -e

ZROK_TOKEN="${1:-}"
SHARE_NAME="${2:-jumphostssh}"

if [ -z "$ZROK_TOKEN" ]; then
    echo "Usage: $0 <zrok-enable-token> [share-name]"
    echo ""
    echo "  zrok-enable-token: Get this from https://api-v1.zrok.io after registering"
    echo "  share-name: Unique name for the share (default: jumphostssh)"
    echo ""
    echo "Steps:"
    echo "  1. Go to https://api-v1.zrok.io and register/login"
    echo "  2. Copy your enable token"
    echo "  3. Run: $0 <your-token>"
    exit 1
fi

echo "=== Zrok SSH Setup ==="
echo "Share name: ${SHARE_NAME}"
echo ""

# Step 1: Install zrok
echo "[1/5] Installing zrok..."
if command -v zrok &> /dev/null; then
    echo "  zrok already installed: $(zrok version | head -1)"
else
    curl -sSL https://get.openziti.io/install.bash | sudo bash -s -- zrok
    echo "  zrok installed: $(zrok version | head -1)"
fi

# Step 2: Enable zrok and create reserved share
echo "[2/5] Enabling zrok environment..."
if zrok status 2>&1 | grep -q "Account Token.*<<SET>>"; then
    echo "  zrok already enabled"
else
    zrok enable "$ZROK_TOKEN"
    echo "  zrok enabled"
fi

echo "  Creating reserved share..."
set +e
OVERVIEW=$(zrok overview 2>&1)
OVERVIEW_RC=$?
set -e
if [ "$OVERVIEW_RC" -ne 0 ] || ! echo "$OVERVIEW" | grep -q '"environments"'; then
    echo "  ERROR: could not read the zrok overview, so the state of '${SHARE_NAME}'"
    echo "  ERROR: is unknown. Refusing to guess. (rc=${OVERVIEW_RC})"
    echo "  ERROR: ${OVERVIEW}"
    exit 1
fi

if echo "$OVERVIEW" | grep -q "\"shareToken\":\"${SHARE_NAME}\""; then
    echo "  Share '${SHARE_NAME}' already exists"
else
    if ! zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output 2>&1; then
        echo "  ERROR: could not reserve '${SHARE_NAME}'."
        echo "  ERROR: A failed reserve usually means the zrok controller is unhealthy,"
        echo "  ERROR: not that the name is taken. Not releasing automatically: if the"
        echo "  ERROR: share does still exist server-side, a release destroys it."
        echo "  ERROR: If you are certain this name is an orphan from a rebuilt host:"
        echo "  ERROR:     zrok release ${SHARE_NAME} && re-run this script"
        exit 1
    fi
    echo "  Reserved share created: ${SHARE_NAME}"
fi

# Step 3: Save enable token for health check auto-repair
echo "[3/5] Saving credentials for auto-repair..."
CRED_DIR="${HOME}/.config/rat"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
cat > "${CRED_DIR}/zrok-env" << EOF
ZROK_ENABLE_TOKEN=${ZROK_TOKEN}
ZROK_SHARE_NAME=${SHARE_NAME}
EOF
chmod 600 "${CRED_DIR}/zrok-env"
echo "  Credentials saved to ${CRED_DIR}/zrok-env"

# Step 4: Create and start zrok systemd service
echo "[4/5] Creating zrok share service..."

sudo tee /etc/systemd/system/zrok-ssh.service > /dev/null << EOF
[Unit]
Description=Zrok SSH Share (${SHARE_NAME})
After=network.target

[Service]
Type=simple
User=$(whoami)
Environment=HOME=$HOME
ExecStart=/usr/bin/zrok share reserved --headless ${SHARE_NAME}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable zrok-ssh.service
echo "  Zrok share service created and enabled"

sudo systemctl start zrok-ssh.service
sleep 3
if sudo systemctl is-active --quiet zrok-ssh.service; then
    echo "  Zrok share service running"
else
    echo "  WARNING: Zrok share service failed to start"
    sudo journalctl -u zrok-ssh.service -n 5 --no-pager
fi

# Step 5: Install health check timer (runs every 5 minutes)
echo "[5/5] Installing health check timer..."

sudo tee /usr/local/bin/zrok-health-check.sh > /dev/null << 'HEALTHEOF'
#!/bin/bash
# Zrok health check and auto-repair script
set -euo pipefail

CRED_FILE="${HOME}/.config/rat/zrok-env"
if [ ! -f "$CRED_FILE" ]; then
    echo "ERROR: No credentials at ${CRED_FILE}"
    exit 1
fi
source "$CRED_FILE"

ZROK_TOKEN="$ZROK_ENABLE_TOKEN"
SHARE_NAME="$ZROK_SHARE_NAME"
NEEDS_RESTART=false

log() { echo "[$(date -Iseconds)] $*"; }

# Helper: run zrok commands with a pseudo-TTY so they don't fail with
# "open /dev/tty: no such device or address" under systemd.
zrok_pty() { script -qefc "zrok $*" /dev/null 2>&1 | tr -d '\r'; }

# Test 1: Is zrok enabled?
if ! zrok_pty status | grep -q "Account Token.*<<SET>>"; then
    log "REPAIR: zrok not enabled"
    sudo systemctl stop zrok-ssh.service 2>/dev/null || true
    zrok_pty enable "$ZROK_TOKEN"
    log "zrok enabled"
    NEEDS_RESTART=true
fi

# Test 2: Fetch the API overview once, and decide whether we can trust it.
#
# This call fails constantly for transient reasons that have nothing to do with
# our share: DNS blips ("no such host"), and 502/503/504 from the zrok
# controller. Historically this script treated ANY unusable output as "the share
# is gone" and went on to delete and recreate it -- which is how a 30-second
# network blip turned into a permanently deleted share. So: fail closed. If we
# cannot positively confirm what the API thinks, we change nothing.
set +e
OVERVIEW_OUTPUT=$(zrok_pty overview 2>&1)
OVERVIEW_RC=$?
set -e

if [ "$NEEDS_RESTART" = false ]; then
    if echo "$OVERVIEW_OUTPUT" | grep -qi "INVALID_AUTH\|UNAUTHORIZED\|unable to load\|cannot get current identity"; then
        # A real authentication failure: the identity is stale, re-enrol.
        log "REPAIR: zrok identity stale, re-enabling..."
        sudo systemctl stop zrok-ssh.service 2>/dev/null || true
        zrok_pty disable 2>/dev/null || true
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

        # Reserve FIRST, and only tear down the tunnel once we have a share to
        # point it at. Never "release and retry": a failing reserve does not
        # mean a name conflict -- it is usually the controller being unhealthy
        # -- and releasing on that assumption permanently destroys a share that
        # is still live and serving traffic.
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
    log "REPAIR: (re)starting zrok-ssh..."
    sudo systemctl restart zrok-ssh.service 2>/dev/null || sudo systemctl start zrok-ssh.service
    sleep 3
    if systemctl is-active --quiet zrok-ssh.service; then
        log "zrok-ssh service started"
    else
        log "ERROR: zrok-ssh service failed to start"
        exit 1
    fi
elif systemctl is-active --quiet zrok-ssh.service; then
    RECENT_ERRORS=$(journalctl -u zrok-ssh.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "INVALID_AUTH\|UNAUTHORIZED" || true)
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
HEALTHEOF

sudo chmod +x /usr/local/bin/zrok-health-check.sh

sudo tee /etc/systemd/system/zrok-health.service > /dev/null << EOF
[Unit]
Description=Zrok health check and auto-repair

[Service]
Type=oneshot
User=$(whoami)
Environment=HOME=$HOME
ExecStart=/usr/local/bin/zrok-health-check.sh
EOF

sudo tee /etc/systemd/system/zrok-health.timer > /dev/null << EOF
[Unit]
Description=Run zrok health check every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now zrok-health.timer
echo "  Health check timer installed (every 5 minutes)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Zrok share token: ${SHARE_NAME}"
echo ""
echo "To connect from another machine using rat:"
echo "  rat add jumphost -t ${SHARE_NAME} -u ubuntu -k ~/.ssh/your_key"
echo "  rat ssh jumphost"
echo ""
echo "To check status:"
echo "  sudo systemctl status zrok-ssh"
echo "  sudo systemctl status zrok-health.timer"
echo "  sudo journalctl -u zrok-health -n 20"
echo ""
