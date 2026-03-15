# VieNeu-TTS VPS Setup Script (Windows)
# ======================================
# One-click setup for a Windows VPS with GPU support.
# Run this on the VPS to install and start VieNeu-TTS server.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/duchtmailbaogiang-web/TTS/main/scripts/setup_vps.ps1 | iex"

# --- Config (edit these if needed) ---
$Model = "pnnbao-ump/VieNeu-TTS"        # HuggingFace model name (NOT GitHub repo)
$Port = 23333
$InstallDir = "C:\VieNeu-TTS"
$RepoZipUrl = "https://github.com/duchtmailbaogiang-web/TTS/archive/refs/heads/main.zip"

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
    $gpuInfo = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
    if ($LASTEXITCODE -ne 0) { throw "nvidia-smi failed" }
    Write-OK "GPU found: $gpuInfo"
} catch {
    Write-Warn "NVIDIA GPU not detected. Server will run on CPU (slower)."
    Write-Warn "For GPU support, install NVIDIA drivers: https://www.nvidia.com/download/index.aspx"
}

# --- Step 2: Install uv ---
Write-Step "Installing uv (Python package manager)..."
$uvFound = $false
try { if (Get-Command uv -ErrorAction SilentlyContinue) { $uvFound = $true } } catch {}

if ($uvFound) {
    Write-OK "uv already installed: $(uv --version)"
} else {
    Write-Host "   Installing uv..."
    try {
        powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        # Also add common uv install path
        $uvLocalBin = "$env:USERPROFILE\.local\bin"
        if (Test-Path $uvLocalBin) { $env:Path += ";$uvLocalBin" }

        try { $uvCheck = Get-Command uv -ErrorAction SilentlyContinue } catch {}
        if ($uvCheck) {
            Write-OK "uv installed: $(uv --version)"
        } else {
            Write-Err "uv installation failed. Please install manually: https://docs.astral.sh/uv/"
            exit 1
        }
    } catch {
        Write-Err "uv installation failed: $_"
        exit 1
    }
}

# --- Step 3: Download / Update Repo ---
Write-Step "Setting up VieNeu-TTS..."
$hasGit = $false
try { if (Get-Command git -ErrorAction SilentlyContinue) { $hasGit = $true } } catch {}

if ((Test-Path "$InstallDir\.git") -and $hasGit) {
    # Existing git repo - update it
    Write-Host "   Updating existing installation..."
    Push-Location $InstallDir
    try {
        & git pull --ff-only 2>&1 | Out-Null
        Write-OK "Updated to latest version"
    } catch {
        Write-Warn "Git pull failed, will re-download."
        Pop-Location
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Get-Location | Where-Object { $_.Path -eq $InstallDir }) { Pop-Location }
} 

if (-not (Test-Path "$InstallDir\pyproject.toml")) {
    # Fresh install - download as ZIP (no git required!)
    Write-Host "   Downloading from GitHub..."
    $zipFile = "$env:TEMP\VieNeu-TTS.zip"
    $extractDir = "$env:TEMP\VieNeu-TTS-extract"
    
    try {
        # Clean up any previous attempts
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        
        # Download
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zipFile -UseBasicParsing
        Write-OK "Downloaded"
        
        # Extract
        Write-Host "   Extracting..."
        Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
        
        # Move to install dir
        if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
        Move-Item "$extractDir\TTS-main" $InstallDir
        
        # Cleanup
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-OK "Extracted to $InstallDir"
    } catch {
        Write-Err "Failed to download repository: $_"
        exit 1
    }
} else {
    Write-OK "VieNeu-TTS already installed at $InstallDir"
}

# --- Step 4: Install Dependencies ---
Write-Step "Installing dependencies (this may take a few minutes)..."
Push-Location $InstallDir
try {
    & uv sync 2>&1
    Write-OK "Dependencies installed"
} catch {
    Write-Err "Failed to install dependencies: $_"
    Pop-Location
    exit 1
}

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
$uvPath = "$env:USERPROFILE\.local\bin"
$startScript = @"
@echo off
cd /d "$InstallDir"
set PATH=%USERPROFILE%\.local\bin;%PATH%
echo Starting VieNeu-TTS Server on port $Port...
echo Model: $Model
echo.
uv run vieneu-serve --model "$Model" --port $Port
pause
"@
$startScript | Out-File -FilePath "$InstallDir\start_server.bat" -Encoding ASCII
Write-OK "Created start_server.bat"

# --- Step 7: Create Windows Task (auto-start on boot) ---
Write-Step "Creating scheduled task for auto-start..."
try {
    $taskName = "VieNeu-TTS-Server"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-OK "Task '$taskName' already exists"
    } else {
        $action = New-ScheduledTaskAction `
            -Execute "cmd.exe" `
            -Argument "/c set PATH=%USERPROFILE%\.local\bin;%PATH% && cd /d `"$InstallDir`" && uv run vieneu-serve --model `"$Model`" --port $Port" `
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
    & uv run vieneu-serve --model $Model --port $Port
    Pop-Location
}
