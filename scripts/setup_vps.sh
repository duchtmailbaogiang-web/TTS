#!/bin/bash
# VieNeu-TTS VPS Setup Script (Linux)
# =====================================
# One-click setup for a Linux VPS with Docker + GPU support.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pnnbao97/VieNeu-TTS/main/scripts/setup_vps.sh | bash
#   --- or ---
#   ./setup_vps.sh [--model MODEL] [--port PORT]

set -e

MODEL="${MODEL:-pnnbao-ump/VieNeu-TTS}"
PORT="${PORT:-23333}"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo ""
echo "====================================="
echo "  🦜 VieNeu-TTS VPS Setup (Linux)    "
echo "====================================="
echo ""
echo "  Model: $MODEL"
echo "  Port:  $PORT"
echo ""

# --- Step 1: Check Docker ---
echo "🦜 Checking Docker..."
if command -v docker &> /dev/null; then
    echo "   ✅ Docker found: $(docker --version)"
else
    echo "   📦 Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "   ✅ Docker installed"
fi

# --- Step 2: Check NVIDIA Container Toolkit ---
echo "🦜 Checking NVIDIA GPU support..."
if command -v nvidia-smi &> /dev/null; then
    echo "   ✅ NVIDIA GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
        echo "   📦 Installing NVIDIA Container Toolkit..."
        distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq nvidia-container-toolkit
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        echo "   ✅ NVIDIA Container Toolkit installed"
    else
        echo "   ✅ NVIDIA Container Toolkit already configured"
    fi
else
    echo "   ⚠️  No NVIDIA GPU detected. Server will run without GPU acceleration."
fi

# --- Step 3: Pull Docker Image ---
echo "🦜 Pulling VieNeu-TTS Docker image..."
docker pull pnnbao/vieneu-tts:serve
echo "   ✅ Docker image ready"

# --- Step 4: Open Firewall ---
echo "🦜 Configuring firewall..."
if command -v ufw &> /dev/null; then
    sudo ufw allow "$PORT/tcp" 2>/dev/null || true
    echo "   ✅ Port $PORT opened (ufw)"
elif command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port="$PORT/tcp" 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    echo "   ✅ Port $PORT opened (firewalld)"
else
    echo "   ⚠️  No firewall manager found. Ensure port $PORT is open."
fi

# --- Step 5: Create systemd service ---
echo "🦜 Creating systemd service..."
SERVICE_FILE="/etc/systemd/system/vieneu-tts.service"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=VieNeu-TTS Server
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker stop vieneu-tts-server
ExecStartPre=-/usr/bin/docker rm vieneu-tts-server
ExecStart=/usr/bin/docker run --gpus all --name vieneu-tts-server -p ${PORT}:23333 pnnbao/vieneu-tts:serve --model ${MODEL}
ExecStop=/usr/bin/docker stop vieneu-tts-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable vieneu-tts.service
echo "   ✅ Service created and enabled (auto-start on boot)"

# --- Done ---
echo ""
echo "====================================="
echo "  ✅ Setup Complete!                  "
echo "====================================="
echo ""
echo "  To start the server:"
echo "    sudo systemctl start vieneu-tts"
echo ""
echo "  To check status:"
echo "    sudo systemctl status vieneu-tts"
echo ""
echo "  To view logs:"
echo "    sudo journalctl -u vieneu-tts -f"
echo ""
echo "  Server will be available at:"
echo "    http://0.0.0.0:$PORT"
echo ""
echo "  Add this server in VieNeu Manager with:"
echo "    Host: <your-vps-ip>"
echo "    Port: $PORT"
echo ""

# --- Optional: Start now ---
read -p "Start the server now? (y/n): " START
if [[ "$START" == "y" || "$START" == "Y" ]]; then
    echo "🦜 Starting VieNeu-TTS Server..."
    sudo systemctl start vieneu-tts
    echo "   ✅ Server started! Checking status..."
    sleep 3
    sudo systemctl status vieneu-tts --no-pager
fi
