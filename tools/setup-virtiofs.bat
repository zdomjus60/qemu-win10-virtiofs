@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Setup VirtIO FS (host ^<^> guest share)

echo ============================================================
echo  Setup VirtIO FS - Linux host ^<^> Windows guest share
echo ============================================================
echo.

:: ---------------------------------------------------------------
:: 1. privilegi amministratore (rilancia con UAC se serve)
::    "net session" puo' fallire anche da amministratore se il
::    servizio Server e' spento: come fallback usa "fsutil".
:: ---------------------------------------------------------------
net session >nul 2>&1
if not errorlevel 1 goto :admin_ok
fsutil dirty query %systemdrive% >nul 2>&1
if not errorlevel 1 goto :admin_ok
echo [i] Administrator access required, relaunching with UAC...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:admin_ok

:: ---------------------------------------------------------------
:: 2. WinFsp (obbligatorio per il client virtiofs di Windows)
:: ---------------------------------------------------------------
sc query WinFsp.Launcher >nul 2>&1
if not errorlevel 1 goto :winfsp_ok

:: 2a) installer gia' presente accanto a questo script: il Linux host lo
::     prepara in tools\ insieme a questi driver, quindi la rete non serve
set "WF_PKG="
for %%F in ("%~dp0winfsp*.msi") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if not defined WF_PKG for %%F in ("%~dp0winfsp*.exe") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if defined WF_PKG goto :winfsp_install

:: 2b) altrimenti scarica da GitHub (le release recenti usano l'.msi,
::     le vecchie l'.setup.exe: vanno bene entrambi)
echo [-] WinFsp not installed and no installer found next to this script: trying the network...
del /q "%TEMP%\winfsp*.msi" "%TEMP%\winfsp*.exe" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$r=Invoke-RestMethod 'https://api.github.com/repos/winfsp/winfsp/releases/latest';$a=$r.assets|Where-Object{($_.name -like '*.msi' -or $_.name -like '*.exe') -and $_.name -notlike 'winfsp-tests*'}|Sort-Object name|Select-Object -Last 1;if($null -eq $a){exit 1};Invoke-WebRequest -Uri $a.browser_download_url -OutFile (Join-Path $env:TEMP $a.name)"
set "WF_PKG="
for %%F in ("%TEMP%\winfsp*.msi") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if not defined WF_PKG for %%F in ("%TEMP%\winfsp*.exe") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if not defined WF_PKG goto :winfsp_ko

:winfsp_install
echo [i] Installing WinFsp: !WF_PKG!
if /i "!WF_PKG:~-4!"==".msi" (
    start /wait "" msiexec /i "!WF_PKG!" /qn /norestart
) else (
    start /wait "" "!WF_PKG!" /S
)
for /l %%i in (1,1,30) do (
    sc query WinFsp.Launcher >nul 2>&1
    if not errorlevel 1 goto :winfsp_ok
    timeout /t 2 /nobreak >nul
)

:winfsp_ko
echo [!] WinFsp was not installed.
echo     Download and install it manually, then run this script again:
echo         https://github.com/winfsp/winfsp/releases
echo     (on the Linux host, ./launch.sh prepares the installer in tools\ by itself)
echo.
goto :winfsp_done

:winfsp_ok
echo [+] WinFsp present.
:winfsp_done

:: ---------------------------------------------------------------
:: 3. trova i driver VirtIO FS:
::    1) accanto a questo script (tools\viofs\..., preparato dall'host:
::       nessuna ISO montata, nessuna rete)
::    2) in fallback, sulla ISO virtio-win montata come unita'
:: ---------------------------------------------------------------
set "DRV="
set "BUILD=0"
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /i CurrentBuild') do set "BUILD=%%b"
echo !BUILD!|findstr /r "^[0-9][0-9]*$" >nul || set "BUILD=0"
set "ORD1=w10"
set "ORD2=w11"
if !BUILD! geq 22000 (set "ORD1=w11"&set "ORD2=w10")

if not defined DRV if exist "%~dp0viofs\!ORD1!\amd64\viofs.inf" set "DRV=%~dp0viofs\!ORD1!\amd64"
if not defined DRV if exist "%~dp0viofs\!ORD2!\amd64\viofs.inf" set "DRV=%~dp0viofs\!ORD2!\amd64"

if not defined DRV (
    for %%R in (!ORD1! !ORD2!) do (
        for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
            if not defined DRV if exist "%%D:\viofs\%%R\amd64\viofs.inf" set "DRV=%%D:\viofs\%%R\amd64"
        )
    )
)

if not defined DRV goto :no_driver
echo [i] Driver found: !DRV!

:: ---------------------------------------------------------------
:: 4. installa il dispositivo (pnputil lo abbina anche ai device sconosciuti)
:: ---------------------------------------------------------------
pnputil /add-driver "!DRV!\viofs.inf" /install >nul
if errorlevel 1 (
    echo [!] pnputil did not install the driver ^(device still missing?^).
    echo     Do it manually: Device Manager - VirtIO FS Device -
    echo     Update driver - Search - Browse:  !DRV!
    echo.
) else (
    echo [+] Driver installed / associated with the VirtIO FS device.
)

:: ---------------------------------------------------------------
:: 5. copia virtiofs.exe (e' il "client" che serve al servizio)
:: ---------------------------------------------------------------
set "DEST=%SystemRoot%\VirtioFS"
if not exist "!DEST!" mkdir "!DEST!"
copy /y "!DRV!\virtiofs.exe" "!DEST!\" >nul
if not exist "!DEST!\virtiofs.exe" goto :no_client
echo [+] Client: !DEST!\virtiofs.exe

:: ---------------------------------------------------------------
:: 6. servizio VirtIO FS
:: ---------------------------------------------------------------
sc query VirtioFsSvc >nul 2>&1
if errorlevel 1 (
    sc create VirtioFsSvc binpath= "!DEST!\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" DisplayName= "Virtio FS Service" >nul
    if errorlevel 1 goto :no_service
    echo [+] VirtioFsSvc service created.
) else (
    sc config VirtioFsSvc binpath= "!DEST!\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
    echo [+] VirtioFsSvc service already present, configuration updated.
)

:: ---------------------------------------------------------------
:: 7. lettera di unita' (opzionale: setup-virtiofs.bat X:  oppure Z:)
:: ---------------------------------------------------------------
if "%~1"=="" goto :start_service
reg add "HKLM\SOFTWARE\VirtIO-FS" /v MountPoint /t REG_SZ /d "%~1" /f >nul
echo [i] Drive letter set to %~1

:start_service
sc stop VirtioFsSvc >nul 2>&1
sc start VirtioFsSvc >nul 2>&1

:: ---------------------------------------------------------------
:: 8. esito
:: ---------------------------------------------------------------
echo.
sc query VirtioFsSvc | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo [!] The service is not active yet. Check:
    echo     - Device Manager: "VirtIO FS Device" must have the driver
    echo     - WinFsp must be installed and the WinFsp.Launcher service active
    echo     - reboot the PC and try again
) else (
    echo [+] VirtioFsSvc service running.
    echo.
    echo     Open File Explorer: the Linux host share
    echo     appears as a drive ^(default Z:^).
    echo     Different letter:  %~nx0  Z:
)

echo.
pause
exit /b 0

:no_driver
echo [!] VirtIO FS drivers not found. Where I look:
echo         %~dp0viofs\!ORD1!\amd64     (next to this script)
echo         X:\viofs\!ORD1!\amd64       (virtio-win ISO mounted as a drive)
echo.
echo     On the Linux host './launch.sh' extracts them by itself into tools\viofs;
echo     or mount the ISO explicitly with:  ./launch.sh --drivers
echo     Then run this script again.
echo.
pause
exit /b 1

:no_client
echo [!] Unable to copy virtiofs.exe from: !DRV!
echo     Copy it manually into !DEST!\ and run again.
echo.
pause
exit /b 1

:no_service
echo [!] Error creating the VirtioFsSvc service.
echo     Try from an admin cmd:
echo         sc create VirtioFsSvc binpath= "!DEST!\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" DisplayName= "Virtio FS Service"
echo.
pause
exit /b 1
