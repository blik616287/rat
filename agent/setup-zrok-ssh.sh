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
if zrok overview 2>&1 | grep -q "$SHARE_NAME"; then
    echo "  Share '${SHARE_NAME}' already exists"
else
    if ! zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output 2>&1; then
        echo "  Share name '${SHARE_NAME}' conflict (orphaned from old environment), releasing and re-creating..."
        zrok release "$SHARE_NAME" 2>/dev/null || true
        zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output
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

# Test 1: Is zrok enabled?
if ! zrok status 2>&1 | grep -q "Account Token.*<<SET>>"; then
    log "REPAIR: zrok not enabled"
    sudo systemctl stop zrok-ssh.service 2>/dev/null || true
    zrok enable "$ZROK_TOKEN"
    log "zrok enabled"
    NEEDS_RESTART=true
fi

# Test 2: Can we reach the zrok API? (catches stale Ziti identity)
if ! zrok overview >/dev/null 2>&1; then
    log "REPAIR: zrok identity stale, re-enabling..."
    sudo systemctl stop zrok-ssh.service 2>/dev/null || true
    zrok disable 2>/dev/null || true
    zrok enable "$ZROK_TOKEN"
    log "zrok re-enabled"
    NEEDS_RESTART=true
fi

# Test 3: Does our share still exist?
if ! zrok overview 2>&1 | grep -q "$SHARE_NAME"; then
    log "REPAIR: share '${SHARE_NAME}' missing, re-creating..."
    sudo systemctl stop zrok-ssh.service 2>/dev/null || true
    if ! zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output 2>&1; then
        log "share name conflict, releasing orphaned share and retrying..."
        zrok release "$SHARE_NAME" 2>/dev/null || true
        zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output
    fi
    log "share re-created"
    NEEDS_RESTART=true
fi

# Test 4: Is the service healthy or does it need a (re)start?
if [ "$NEEDS_RESTART" = true ]; then
    log "REPAIR: restarting zrok-ssh after identity/share repair..."
    sudo systemctl start zrok-ssh.service
    sleep 3
    if systemctl is-active --quiet zrok-ssh.service; then
        log "zrok-ssh service started"
    else
        log "ERROR: zrok-ssh service failed to start"
        exit 1
    fi
elif systemctl is-active --quiet zrok-ssh.service; then
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
