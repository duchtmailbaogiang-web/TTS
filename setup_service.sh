#!/bin/bash
# ===================================================
#  VieNeu-TTS Server - Systemd Auto-Start Setup
#  Run: bash setup_service.sh
# ===================================================

set -e

SERVICE_NAME="vieneu-tts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(whoami)"

echo "=================================================="
echo "  VieNeu-TTS Server — Systemd Service Setup"
echo "=================================================="

# Detect the uv path
UV_PATH=$(which uv 2>/dev/null || echo "")
if [ -z "$UV_PATH" ]; then
    echo "[!] uv not found. Trying ~/.local/bin/uv..."
    UV_PATH="$HOME/.local/bin/uv"
    if [ ! -f "$UV_PATH" ]; then
        echo "[ERROR] uv is not installed!"
        echo "  Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
        exit 1
    fi
fi
echo "[+] uv found at: $UV_PATH"

# Create the systemd service file
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "[+] Creating service: $SERVICE_FILE"
sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=VieNeu-TTS Server (LMDeploy)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$SCRIPT_DIR
ExecStart=$UV_PATH run lmdeploy serve api_server pnnbao-ump/VieNeu-TTS --server-name 0.0.0.0 --server-port 23333 --tp 1 --cache-max-entry-count 0.3 --model-name pnnbao-ump/VieNeu-TTS --backend pytorch
Restart=always
RestartSec=10
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Reloading systemd..."
sudo systemctl daemon-reload

echo "[+] Enabling service (auto-start on boot)..."
sudo systemctl enable "$SERVICE_NAME"

echo "[+] Starting service..."
sudo systemctl start "$SERVICE_NAME"

echo ""
echo "=================================================="
echo "  ✅ DONE! VieNeu-TTS server is now a service"
echo "=================================================="
echo ""
echo "  Commands:"
echo "    Status:  sudo systemctl status $SERVICE_NAME"
echo "    Logs:    sudo journalctl -u $SERVICE_NAME -f"
echo "    Stop:    sudo systemctl stop $SERVICE_NAME"
echo "    Start:   sudo systemctl start $SERVICE_NAME"
echo "    Restart: sudo systemctl restart $SERVICE_NAME"
echo "    Disable: sudo systemctl disable $SERVICE_NAME"
echo ""
echo "  Server will auto-start on VPS reboot!"
echo "=================================================="
