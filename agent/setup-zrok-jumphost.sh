#!/bin/bash
# Zrok setup script for jump host
# Run this on the jump host to set up zrok SSH sharing with VNC
#
# Usage: ./setup-zrok-jumphost.sh <zrok-enable-token> [share-name]
#
# Example: ./setup-zrok-jumphost.sh YOUR_TOKEN_HERE jumphostssh

set -e

ZROK_TOKEN="${1:-}"
SHARE_NAME="${2:-jumphostssh}"
USER_PASSWORD="${3:-ubuntu123}"
VNC_PASSWORD="${4:-ubuntu123}"

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

echo "=== Zrok Jump Host Setup ==="
echo "Share name: ${SHARE_NAME}"
echo ""

# Step 1: Install dependencies
echo "[1/10] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq openssh-server tigervnc-standalone-server tigervnc-common dbus-x11 > /dev/null
echo "  Dependencies installed"

# Step 2: Configure SSH with password authentication
echo "[2/10] Configuring SSH..."
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config

# Ensure SSH listens on all interfaces
if ! grep -q "^ListenAddress 0.0.0.0" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi

echo "  SSH configured with password authentication"

# Step 3: Set ubuntu user password
echo "[3/10] Setting ubuntu user password..."
echo "ubuntu:${USER_PASSWORD}" | sudo chpasswd
echo "  Password set for ubuntu user"

# Step 4: Configure VNC
echo "[4/10] Configuring VNC server..."
mkdir -p ~/.vnc

# Set VNC password
echo "${VNC_PASSWORD}" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create xstartup
cat > ~/.vnc/xstartup << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startxfce4 &
EOF
chmod +x ~/.vnc/xstartup

# Create config
cat > ~/.vnc/config << 'EOF'
geometry=1920x1080
depth=24
EOF

echo "  VNC configured"

# Step 5: Install zrok
echo "[5/10] Installing zrok..."
if command -v zrok &> /dev/null; then
    echo "  zrok already installed: $(zrok version | head -1)"
else
    curl -sSL https://get.openziti.io/install.bash | sudo bash -s -- zrok
    echo "  zrok installed: $(zrok version | head -1)"
fi

# Step 6: Enable zrok and create reserved share
echo "[6/10] Enabling zrok environment..."
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

# Step 7: Save enable token for health check auto-repair
echo "[7/10] Saving credentials for auto-repair..."
CRED_DIR="${HOME}/.config/rat"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
cat > "${CRED_DIR}/zrok-env" << EOF
ZROK_ENABLE_TOKEN=${ZROK_TOKEN}
ZROK_SHARE_NAME=${SHARE_NAME}
EOF
chmod 600 "${CRED_DIR}/zrok-env"
echo "  Credentials saved to ${CRED_DIR}/zrok-env"

# Step 8: Create systemd services
echo "[8/10] Creating systemd services..."

# SSH service (should already exist, just ensure it's configured)
sudo systemctl enable ssh
echo "  SSH service enabled"

# VNC service
sudo tee /etc/systemd/system/vncserver@.service > /dev/null << EOF
[Unit]
Description=TigerVNC server on display %i
After=syslog.target network.target

[Service]
Type=simple
User=$(whoami)
PAMName=login
PIDFile=/home/$(whoami)/.vnc/%H:%i.pid
ExecStartPre=/bin/sh -c '/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || :'
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1920x1080 -localhost no -fg :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable vncserver@1.service
echo "  VNC service created and enabled"

# Zrok service
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
echo "  Zrok service created and enabled"

# Step 9: Install health check timer (runs every 5 minutes)
echo "[9/10] Installing health check timer..."

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

# Step 10: Start all services
echo "[10/10] Starting services..."

sudo systemctl restart ssh
if sudo systemctl is-active --quiet ssh; then
    echo "  SSH service running"
else
    echo "  WARNING: SSH service failed to start"
fi

sudo systemctl start vncserver@1.service
sleep 2
if sudo systemctl is-active --quiet vncserver@1.service; then
    echo "  VNC service running on display :1"
else
    echo "  WARNING: VNC service failed to start"
    sudo journalctl -u vncserver@1.service -n 5 --no-pager
fi

sudo systemctl start zrok-ssh.service
sleep 3
if sudo systemctl is-active --quiet zrok-ssh.service; then
    echo "  Zrok service running"
else
    echo "  WARNING: Zrok service failed to start"
    sudo journalctl -u zrok-ssh.service -n 5 --no-pager
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Zrok share token: ${SHARE_NAME}"
echo "SSH user: ubuntu"
echo "SSH password: ${USER_PASSWORD}"
echo "VNC password: ${VNC_PASSWORD}"
echo "VNC display: :1 (port 5901)"
echo ""
echo "To connect from another machine using rat:"
echo "  rat add jumphost -t ${SHARE_NAME} -u ubuntu -k ~/.ssh/your_key"
echo "  rat ssh jumphost"
echo "  rat vnc jumphost"
echo ""
echo "To check status:"
echo "  sudo systemctl status ssh"
echo "  sudo systemctl status vncserver@1"
echo "  sudo systemctl status zrok-ssh"
echo "  sudo systemctl status zrok-health.timer"
echo ""
