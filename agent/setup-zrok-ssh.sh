#!/bin/bash
# Zrok setup script for SSH-only jump host (no VNC)
# Assumes SSH and the ubuntu user are already configured on the box.
#
# Usage: ./setup-zrok-ssh.sh <zrok-enable-token> [share-name]
#
# Example: ./setup-zrok-ssh.sh YOUR_TOKEN_HERE jumphostssh

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
echo "[1/3] Installing zrok..."
if command -v zrok &> /dev/null; then
    echo "  zrok already installed: $(zrok version | head -1)"
else
    curl -sSL https://get.openziti.io/install.bash | sudo bash -s -- zrok
    echo "  zrok installed: $(zrok version | head -1)"
fi

# Step 2: Enable zrok and create reserved share
echo "[2/3] Enabling zrok environment..."
if zrok status 2>&1 | grep -q "Account Token.*<<SET>>"; then
    echo "  zrok already enabled"
else
    zrok enable "$ZROK_TOKEN"
    echo "  zrok enabled"
fi

echo "  Creating reserved share..."
if zrok ls 2>&1 | grep -q "$SHARE_NAME"; then
    echo "  Share '${SHARE_NAME}' already exists"
else
    zrok reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output
    echo "  Reserved share created: ${SHARE_NAME}"
fi

# Step 3: Create and start zrok systemd service
echo "[3/3] Creating and starting zrok service..."

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
echo ""
echo "To connect from another machine using rat:"
echo "  rat add jumphost -t ${SHARE_NAME} -u ubuntu -k ~/.ssh/your_key"
echo "  rat ssh jumphost"
echo ""
echo "To check status:"
echo "  sudo systemctl status zrok-ssh"
echo ""
