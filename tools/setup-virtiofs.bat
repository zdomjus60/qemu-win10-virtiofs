@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Setup VirtIO FS (condivisione host ^<^> guest)

echo ============================================================
echo  Setup VirtIO FS - condivisione Linux host ^<^> Windows guest
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
echo [i] Serve l'apertura come amministratore, riavvio con UAC...
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
echo [-] WinFsp non installato e non trovo l'installer qui accanto: provo la rete...
del /q "%TEMP%\winfsp*.msi" "%TEMP%\winfsp*.exe" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$r=Invoke-RestMethod 'https://api.github.com/repos/winfsp/winfsp/releases/latest';$a=$r.assets|Where-Object{($_.name -like '*.msi' -or $_.name -like '*.exe') -and $_.name -notlike 'winfsp-tests*'}|Sort-Object name|Select-Object -Last 1;if($null -eq $a){exit 1};Invoke-WebRequest -Uri $a.browser_download_url -OutFile (Join-Path $env:TEMP $a.name)"
set "WF_PKG="
for %%F in ("%TEMP%\winfsp*.msi") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if not defined WF_PKG for %%F in ("%TEMP%\winfsp*.exe") do if exist "%%~fF" if not defined WF_PKG set "WF_PKG=%%~fF"
if not defined WF_PKG goto :winfsp_ko

:winfsp_install
echo [i] Installo WinFsp: !WF_PKG!
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
echo [!] WinFsp non e' stato installato.
echo     Scaricalo e installalo a mano, poi rilancia questo script:
echo         https://github.com/winfsp/winfsp/releases
echo     (sul Linux host, ./launch.sh prepara da solo l'installer in tools\)
echo.
goto :winfsp_done

:winfsp_ok
echo [+] WinFsp presente.
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
echo [i] Driver trovato: !DRV!

:: ---------------------------------------------------------------
:: 4. installa il dispositivo (pnputil lo abbina anche ai device sconosciuti)
:: ---------------------------------------------------------------
pnputil /add-driver "!DRV!\viofs.inf" /install >nul
if errorlevel 1 (
    echo [!] pnputil non ha installato il driver ^(device ancora assente?^).
    echo     Fallo a mano: Gestione dispositivi - VirtIO FS Device -
    echo     Aggiorna driver - Cerca - Sfoglia:  !DRV!
    echo.
) else (
    echo [+] Driver installato / associato al dispositivo VirtIO FS.
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
    echo [+] Servizio VirtioFsSvc creato.
) else (
    sc config VirtioFsSvc binpath= "!DEST!\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
    echo [+] Servizio VirtioFsSvc gia' presente, configurazione aggiornata.
)

:: ---------------------------------------------------------------
:: 7. lettera di unita' (opzionale: setup-virtiofs.bat X:  oppure Z:)
:: ---------------------------------------------------------------
if "%~1"=="" goto :start_service
reg add "HKLM\SOFTWARE\VirtIO-FS" /v MountPoint /t REG_SZ /d "%~1" /f >nul
echo [i] Lettera unita' impostata a %~1

:start_service
sc stop VirtioFsSvc >nul 2>&1
sc start VirtioFsSvc >nul 2>&1

:: ---------------------------------------------------------------
:: 8. esito
:: ---------------------------------------------------------------
echo.
sc query VirtioFsSvc | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo [!] Il servizio non e' ancora attivo. Controlla:
    echo     - Gestione dispositivi: "VirtIO FS Device" deve avere il driver
    echo     - WinFsp deve essere installato e il servizio WinFsp.Launcher attivo
    echo     - riavvia il PC e riprova
) else (
    echo [+] Servizio VirtioFsSvc in esecuzione.
    echo.
    echo     Apri Esplora file: la condivisione del Linux host
    echo     appare come unita' ^(di default Z:^).
    echo     Lettera diversa:  %~nx0  Z:
)

echo.
pause
exit /b 0

:no_driver
echo [!] Non trovo i driver VirtIO FS. Dove cerco:
echo         %~dp0viofs\!ORD1!\amd64     (accanto a questo script)
echo         X:\viofs\!ORD1!\amd64       (ISO virtio-win montata come unita')
echo.
echo     Sul Linux host './launch.sh' li estrae da solo in tools\viofs;
echo     oppure monta esplicitamente la ISO con:  ./launch.sh --drivers
echo     Poi rilancia questo script.
echo.
pause
exit /b 1

:no_client
echo [!] Impossibile copiare virtiofs.exe da: !DRV!
echo     Copialo a mano in !DEST!\ e rilancia.
echo.
pause
exit /b 1

:no_service
echo [!] Errore nella creazione del servizio VirtioFsSvc.
echo     Prova da cmd amministratore:
echo         sc create VirtioFsSvc binpath= "!DEST!\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" DisplayName= "Virtio FS Service"
echo.
pause
exit /b 1
