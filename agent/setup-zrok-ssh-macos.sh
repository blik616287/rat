#!/bin/bash
# Zrok setup script for an SSH-only jump host on macOS (no VNC)
# The launchd counterpart of setup-zrok-ssh.sh. Run it from a checkout of this
# repo: it installs the sibling zrok-health-check-macos.sh.
#
# Usage: ./setup-zrok-ssh-macos.sh <zrok-enable-token> [share-name]
#
# Example: ./setup-zrok-ssh-macos.sh YOUR_TOKEN_HERE jumphostssh

set -e

ZROK_TOKEN="${1:-}"
SHARE_NAME="${2:-jumphostssh}"

# zrok v2 removed `zrok reserve` and `zrok share reserved` (and renamed the
# binary to zrok2), so pin the v1 line that the rest of RAT is built on.
ZROK_VERSION="1.1.13"
ZROK_BIN="/usr/local/bin/zrok"
HEALTH_BIN="/usr/local/bin/zrok-health-check-macos.sh"
SHARE_LABEL="io.rat.zrok-ssh"
HEALTH_LABEL="io.rat.zrok-health"
SHARE_PLIST="/Library/LaunchDaemons/${SHARE_LABEL}.plist"
HEALTH_PLIST="/Library/LaunchDaemons/${HEALTH_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
LOG_DIR="${HOME}/Library/Logs/rat"

if [ -z "$ZROK_TOKEN" ]; then
    echo "Usage: $0 <zrok-enable-token> [share-name]"
    echo ""
    echo "  zrok-enable-token: Get this from https://api-v1.zrok.io after registering"
    echo "  share-name: Unique name for the share (default: jumphostssh)"
    exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this script is for macOS; use setup-zrok-ssh.sh on Linux"
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run as the user that will own the share, not root (sudo is used where needed)"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/zrok-health-check-macos.sh" ]; then
    echo "ERROR: ${SCRIPT_DIR}/zrok-health-check-macos.sh not found; run from the repo's agent/ directory"
    exit 1
fi

echo "=== Zrok SSH Setup (macOS) ==="
echo "Share name: ${SHARE_NAME}"
echo ""

# Step 1: Install zrok v1
echo "[1/6] Installing zrok..."
if [ -x "$ZROK_BIN" ] && "$ZROK_BIN" version 2>&1 | grep -q "v1\."; then
    echo "  zrok already installed: $("$ZROK_BIN" version 2>&1 | grep -m1 "v1\.")"
else
    case "$(uname -m)" in
        arm64) ZROK_ARCH="arm64" ;;
        x86_64) ZROK_ARCH="amd64" ;;
        *) echo "  ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
    esac
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    URL="https://github.com/openziti/zrok/releases/download/v${ZROK_VERSION}/zrok_${ZROK_VERSION}_darwin_${ZROK_ARCH}.tar.gz"
    echo "  Downloading ${URL}"
    curl -fsSL "$URL" -o "${TMP_DIR}/zrok.tar.gz"
    tar -xzf "${TMP_DIR}/zrok.tar.gz" -C "$TMP_DIR"
    sudo mkdir -p /usr/local/bin
    sudo install -m 755 "${TMP_DIR}/zrok" "$ZROK_BIN"
    echo "  zrok installed: $("$ZROK_BIN" version 2>&1 | grep -m1 "v1\.")"
fi
if command -v zrok > /dev/null && [ "$(command -v zrok)" != "$ZROK_BIN" ]; then
    echo "  WARNING: 'zrok' on your PATH is $(command -v zrok), not ${ZROK_BIN}"
fi

# Step 2: Make sure Remote Login (sshd) is on
echo "[2/6] Checking Remote Login (SSH)..."
if nc -z -G 2 localhost 22 > /dev/null 2>&1; then
    echo "  SSH is listening on port 22"
else
    echo "  Enabling Remote Login..."
    sudo systemsetup -setremotelogin on > /dev/null 2>&1 || true
    sleep 2
    if nc -z -G 2 localhost 22 > /dev/null 2>&1; then
        echo "  SSH is listening on port 22"
    else
        echo "  ERROR: SSH is not listening on port 22. Turn on"
        echo "  ERROR: System Settings > General > Sharing > Remote Login and re-run."
        echo "  ERROR: (systemsetup needs Full Disk Access for your terminal to do it.)"
        exit 1
    fi
fi

# Step 3: Enable zrok and create reserved share
echo "[3/6] Enabling zrok environment..."
if "$ZROK_BIN" status 2>&1 | grep -q "Account Token.*<<SET>>"; then
    echo "  zrok already enabled"
else
    "$ZROK_BIN" enable "$ZROK_TOKEN"
    echo "  zrok enabled"
fi

echo "  Creating reserved share..."
set +e
OVERVIEW=$("$ZROK_BIN" overview 2>&1)
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
    if ! "$ZROK_BIN" reserve private localhost:22 --backend-mode tcpTunnel --unique-name "$SHARE_NAME" --json-output 2>&1; then
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

# Step 4: Save enable token for health check auto-repair
echo "[4/6] Saving credentials for auto-repair..."
CRED_DIR="${HOME}/.config/rat"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
cat > "${CRED_DIR}/zrok-env" << EOF
ZROK_ENABLE_TOKEN=${ZROK_TOKEN}
ZROK_SHARE_NAME=${SHARE_NAME}
EOF
chmod 600 "${CRED_DIR}/zrok-env"
echo "  Credentials saved to ${CRED_DIR}/zrok-env"

mkdir -p "$LOG_DIR"
touch "${LOG_DIR}/zrok-ssh.log" "${LOG_DIR}/zrok-health.log"

# (Re)load a LaunchDaemon so that edits to its plist take effect.
load_daemon() {
    sudo launchctl bootout "system/$1" 2> /dev/null || true
    sudo launchctl bootstrap system "$2"
}

# Step 5: Create and start the zrok share LaunchDaemon
echo "[5/6] Creating zrok share service..."
# A LaunchDaemon (not a LaunchAgent) so the share is up at boot without a login.
sudo tee "$SHARE_PLIST" > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SHARE_LABEL}</string>
    <key>UserName</key>
    <string>${USER_NAME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>${ZROK_BIN}</string>
        <string>share</string>
        <string>reserved</string>
        <string>--headless</string>
        <string>${SHARE_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/zrok-ssh.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/zrok-ssh.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$SHARE_PLIST"
sudo chmod 644 "$SHARE_PLIST"
load_daemon "$SHARE_LABEL" "$SHARE_PLIST"
echo "  Zrok share service created and enabled"

sleep 3
if sudo launchctl print "system/${SHARE_LABEL}" 2> /dev/null | grep -q "state = running"; then
    echo "  Zrok share service running"
else
    echo "  WARNING: Zrok share service failed to start"
    tail -n 5 "${LOG_DIR}/zrok-ssh.log"
fi

# Step 6: Install health check LaunchDaemon (runs every 5 minutes)
echo "[6/6] Installing health check..."
sudo install -m 755 "${SCRIPT_DIR}/zrok-health-check-macos.sh" "$HEALTH_BIN"

# Runs as root so it can manage the share daemon without a sudo password; it
# drops to the env file's owner for every zrok call.
sudo tee "$HEALTH_PLIST" > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${HEALTH_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HEALTH_BIN}</string>
        <string>--env-file</string>
        <string>${CRED_DIR}/zrok-env</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/zrok-health.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/zrok-health.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$HEALTH_PLIST"
sudo chmod 644 "$HEALTH_PLIST"
load_daemon "$HEALTH_LABEL" "$HEALTH_PLIST"
echo "  Health check installed (every 5 minutes)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Zrok share token: ${SHARE_NAME}"
echo ""
echo "To connect from another machine using rat:"
echo "  rat add mac -t ${SHARE_NAME} -u ${USER_NAME} -k ~/.ssh/your_key"
echo "  rat ssh mac"
echo ""
echo "To check status:"
echo "  sudo launchctl print system/${SHARE_LABEL} | grep state"
echo "  tail -n 20 ${LOG_DIR}/zrok-ssh.log"
echo "  tail -n 20 ${LOG_DIR}/zrok-health.log"
echo "  sudo launchctl kickstart system/${HEALTH_LABEL}   # run the health check now"
echo ""
