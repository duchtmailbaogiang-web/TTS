@echo off
REM ===================================================
REM  VieNeu-TTS Server - Windows Auto-Start Setup
REM  Click phai > Run as Administrator
REM ===================================================

echo ==================================================
echo   VieNeu-TTS Server - Windows Service Setup
echo ==================================================
echo.

REM --- Check admin ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Can chay voi quyen Administrator!
    echo   Click phai file nay ^> Run as administrator
    pause
    exit /b 1
)

REM --- Get script directory ---
set "SCRIPT_DIR=%~dp0"
set "TASK_NAME=VieNeu-TTS-Server"

REM --- Find uv ---
where uv >nul 2>&1
if %errorlevel% neq 0 (
    if exist "%USERPROFILE%\.local\bin\uv.exe" (
        set "UV_PATH=%USERPROFILE%\.local\bin\uv.exe"
    ) else (
        echo [ERROR] uv khong tim thay!
        echo   Cai dat: powershell -c "irm https://astral.sh/uv/install.ps1 | iex"
        pause
        exit /b 1
    )
) else (
    for /f "tokens=*" %%i in ('where uv') do set "UV_PATH=%%i"
)
echo [+] uv: %UV_PATH%

REM --- Create startup batch ---
set "START_SCRIPT=%SCRIPT_DIR%start_tts_server.bat"
echo [+] Tao startup script: %START_SCRIPT%
(
echo @echo off
echo cd /d "%SCRIPT_DIR%"
echo "%UV_PATH%" run lmdeploy serve api_server pnnbao-ump/VieNeu-TTS --server-name 0.0.0.0 --server-port 23333 --tp 1 --cache-max-entry-count 0.3 --model-name pnnbao-ump/VieNeu-TTS --backend pytorch
) > "%START_SCRIPT%"

REM --- Remove old task if exists ---
schtasks /query /tn "%TASK_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [+] Xoa task cu...
    schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
)

REM --- Create XML for Task Scheduler (runs hidden, at logon) ---
set "XML_FILE=%SCRIPT_DIR%tts_task.xml"
echo [+] Tao Task Scheduler XML...
(
echo ^<?xml version="1.0" encoding="UTF-16"?^>
echo ^<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
echo   ^<Triggers^>
echo     ^<LogonTrigger^>
echo       ^<Enabled^>true^</Enabled^>
echo     ^</LogonTrigger^>
echo   ^</Triggers^>
echo   ^<Principals^>
echo     ^<Principal^>
echo       ^<LogonType^>InteractiveToken^</LogonType^>
echo       ^<RunLevel^>HighestAvailable^</RunLevel^>
echo     ^</Principal^>
echo   ^</Principals^>
echo   ^<Settings^>
echo     ^<MultipleInstancesPolicy^>IgnoreNew^</MultipleInstancesPolicy^>
echo     ^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>
echo     ^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>
echo     ^<AllowHardTerminate^>true^</AllowHardTerminate^>
echo     ^<StartWhenAvailable^>true^</StartWhenAvailable^>
echo     ^<RunOnlyIfNetworkAvailable^>false^</RunOnlyIfNetworkAvailable^>
echo     ^<AllowStartOnDemand^>true^</AllowStartOnDemand^>
echo     ^<Enabled^>true^</Enabled^>
echo     ^<Hidden^>false^</Hidden^>
echo     ^<RestartOnFailure^>
echo       ^<Interval^>PT1M^</Interval^>
echo       ^<Count^>3^</Count^>
echo     ^</RestartOnFailure^>
echo     ^<ExecutionTimeLimit^>PT0S^</ExecutionTimeLimit^>
echo   ^</Settings^>
echo   ^<Actions^>
echo     ^<Exec^>
echo       ^<Command^>powershell.exe^</Command^>
echo       ^<Arguments^>-WindowStyle Hidden -Command "Start-Process -FilePath '%START_SCRIPT%' -WindowStyle Hidden"^</Arguments^>
echo     ^</Exec^>
echo   ^</Actions^>
echo ^</Task^>
) > "%XML_FILE%"

REM --- Import task from XML ---
echo [+] Import Scheduled Task: %TASK_NAME%
schtasks /create /tn "%TASK_NAME%" /xml "%XML_FILE%" /f

if %errorlevel% equ 0 (
    echo [OK] Task da tao thanh cong!
) else (
    echo [WARN] Import XML that bai, thu tao bang lenh don gian...
    schtasks /create /tn "%TASK_NAME%" /tr "powershell.exe -WindowStyle Hidden -Command \"Start-Process -FilePath '%START_SCRIPT%' -WindowStyle Hidden\"" /sc onlogon /rl highest /f
)

REM --- Also add to Startup folder as backup ---
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "STARTUP_BAT=%STARTUP_DIR%\VieNeu-TTS-AutoStart.bat"
echo [+] Tao startup script (backup): %STARTUP_BAT%
(
echo @echo off
echo powershell.exe -WindowStyle Hidden -Command "Start-Process -FilePath '%START_SCRIPT%' -WindowStyle Hidden"
) > "%STARTUP_BAT%"

REM --- Clean up XML ---
del "%XML_FILE%" 2>nul

REM --- Start immediately (hidden) ---
echo.
echo [+] Khoi dong server ngay bay gio (an)...
powershell.exe -WindowStyle Hidden -Command "Start-Process -FilePath '%START_SCRIPT%' -WindowStyle Hidden"

echo.
echo ==================================================
echo   DONE! VieNeu-TTS server da duoc cai dat
echo ==================================================
echo.
echo   Server CHAY AN (khong hien console).
echo   Tu dong khoi dong khi dang nhap Windows.
echo   Tu dong restart neu bi crash (toi da 3 lan).
echo.
echo   Quan ly:
echo     Tat server:    taskkill /f /im python.exe
echo     Chay lai:      schtasks /run /tn "%TASK_NAME%"
echo     Xem status:    schtasks /query /tn "%TASK_NAME%"
echo     Xoa autostart: schtasks /delete /tn "%TASK_NAME%" /f
echo                     del "%STARTUP_BAT%"
echo ==================================================
echo.
pause
