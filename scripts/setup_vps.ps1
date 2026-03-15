# VieNeu-TTS VPS Setup Script (Windows)
# ======================================
# One-click setup for a Windows VPS with GPU support.
# Run this on the VPS to install and start VieNeu-TTS server.
#
# Usage:
#   irm https://raw.githubusercontent.com/duchtmailbaogiang-web/TTS/main/scripts/setup_vps.ps1 | iex
#   --- or ---
#   .\setup_vps.ps1 [-Model "pnnbao-ump/VieNeu-TTS"] [-Port 23333] [-InstallDir "C:\VieNeu-TTS"]

param(
    [string]$Model = "duchtmailbaogiang-web/TTS",
    [int]$Port = 23333,
    [string]$InstallDir = "C:\VieNeu-TTS"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n🦜 $msg" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "   ✅ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "   ⚠️  $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "   ❌ $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  VieNeu-TTS VPS Setup (Windows)     " -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Model: $Model"
Write-Host "  Port:  $Port"
Write-Host "  Dir:   $InstallDir"
Write-Host ""

# --- Step 1: Check NVIDIA GPU ---
Write-Step "Checking NVIDIA GPU..."
try {
    $gpuInfo = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
    if ($LASTEXITCODE -ne 0) { throw "nvidia-smi failed" }
    Write-OK "GPU found: $gpuInfo"
} catch {
    Write-Warn "NVIDIA GPU not detected. Server will run on CPU (slower)."
    Write-Warn "For GPU support, install NVIDIA drivers: https://www.nvidia.com/download/index.aspx"
}

# --- Step 2: Install uv ---
Write-Step "Installing uv (Python package manager)..."
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Write-OK "uv already installed: $(uv --version)"
} else {
    Write-Host "   Installing uv..."
    powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-OK "uv installed: $(uv --version)"
    } else {
        Write-Err "uv installation failed. Please install manually: https://docs.astral.sh/uv/"
        exit 1
    }
}

# --- Step 3: Clone or Update Repo ---
Write-Step "Setting up VieNeu-TTS..."
if (Test-Path "$InstallDir\.git") {
    Write-Host "   Updating existing installation..."
    Push-Location $InstallDir
    git pull --ff-only 2>&1 | Out-Null
    Pop-Location
    Write-OK "Updated to latest version"
} else {
    Write-Host "   Cloning repository..."
    git clone https://github.com/duchtmailbaogiang-web/TTS.git $InstallDir 2>&1 | Out-Null
    Write-OK "Cloned to $InstallDir"
}

# --- Step 4: Install Dependencies ---
Write-Step "Installing dependencies (this may take a few minutes)..."
Push-Location $InstallDir
uv sync --group gpu 2>&1
Write-OK "Dependencies installed"

# --- Step 5: Open Firewall ---
Write-Step "Configuring firewall for port $Port..."
try {
    $rule = Get-NetFirewallRule -DisplayName "VieNeu-TTS Server" -ErrorAction SilentlyContinue
    if ($rule) {
        Write-OK "Firewall rule already exists"
    } else {
        New-NetFirewallRule -DisplayName "VieNeu-TTS Server" `
            -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port `
            -Profile Any | Out-Null
        Write-OK "Firewall rule added for port $Port"
    }
} catch {
    Write-Warn "Could not configure firewall (requires admin). Manually open port $Port if needed."
}

# --- Step 6: Create Startup Script ---
Write-Step "Creating startup script..."
$startScript = @"
@echo off
cd /d "$InstallDir"
echo Starting VieNeu-TTS Server on port $Port...
echo Model: $Model
echo.
uv run python src/vieneu/serve.py --model "$Model" --port $Port
pause
"@
$startScript | Out-File -FilePath "$InstallDir\start_server.bat" -Encoding ASCII
Write-OK "Created start_server.bat"

# --- Step 7: Create Windows Task (optional auto-start) ---
Write-Step "Creating scheduled task for auto-start..."
try {
    $taskName = "VieNeu-TTS-Server"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-OK "Task '$taskName' already exists"
    } else {
        $action = New-ScheduledTaskAction `
            -Execute "cmd.exe" `
            -Argument "/c cd /d `"$InstallDir`" && uv run python src/vieneu/serve.py --model `"$Model`" --port $Port" `
            -WorkingDirectory $InstallDir
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest | Out-Null
        Write-OK "Auto-start task created (runs at system startup)"
    }
} catch {
    Write-Warn "Could not create scheduled task (requires admin). Use start_server.bat to start manually."
}

# --- Done ---
Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host "  ✅ Setup Complete!                  " -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
Write-Host ""
Write-Host "  To start the server:"
Write-Host "    cd $InstallDir"
Write-Host "    .\start_server.bat"
Write-Host ""
Write-Host "  Server will be available at:"
Write-Host "    http://0.0.0.0:$Port"
Write-Host ""
Write-Host "  Add this server in VieNeu Manager with:"
Write-Host "    Host: <your-vps-ip>"
Write-Host "    Port: $Port"
Write-Host ""

Pop-Location

# --- Optional: Start now ---
$start = Read-Host "Start the server now? (y/n)"
if ($start -eq 'y' -or $start -eq 'Y') {
    Write-Step "Starting VieNeu-TTS Server..."
    Push-Location $InstallDir
    uv run python src/vieneu/serve.py --model $Model --port $Port
    Pop-Location
}
