@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ALLARGS=%*"
set "RELAUNCH=%*"
set "SCRIPT=%~f0"
set "SCRIPTDIR=%~dp0"
title Windows Network Stack Reset

rem =====================================================================
rem  net-reset-reboot.bat  -  full TCP/IP + Winsock + DNS reset for Windows
rem
rem  Usage:
rem    net-reset-reboot.bat [/firewall] [/y] [/force] [/dryrun]
rem                         [/restart] [/shutdown] [/none]
rem    net-reset-reboot.bat /verify
rem
rem  Run it with no arguments - double-clicking counts - and it shows a
rem  three option menu: run the reset, dry run, or verify. Pressing Enter
rem  picks the reset.
rem
rem    /firewall  also reset Windows Firewall to defaults (deletes custom rules)
rem    /y         skip the "are you sure" prompt
rem    /force     run even from a remote/RDP session (you WILL be disconnected)
rem    /restart   restart when finished (recommended)
rem    /shutdown  shut down when finished
rem    /none      leave the machine running (a reboot is still required)
rem    /dryrun    print every command without running anything
rem    /verify    run ONLY the connectivity checks and append them to the
rem               last reset log - use this after the reboot to see whether
rem               anything actually improved. Changes nothing, needs no
rem               admin rights.
rem
rem  Statically configured DNS servers are saved before the reset and put
rem  back afterwards, so custom resolvers survive the process.
rem
rem  Files written to netreset-logs\ next to this script:
rem    netreset_<stamp>.log          the readable step-by-step record
rem    netsh-config_<stamp>.txt      full netsh config, restore with
rem                                    netsh -f "netsh-config_<stamp>.txt"
rem    winsock-catalog_<stamp>.txt   Winsock providers as they were before
rem                                    the reset removed the third-party ones
rem    ipreset_<stamp>.log           netsh's own reset logs
rem    dns-static_<stamp>.txt        your hand-set DNS servers, saved so they
rem                                    survive the reset. Deleted once they
rem                                    are put back, and KEPT only if the
rem                                    restore failed, so you can recover
rem                                    them by hand.
rem =====================================================================

set "DO_FIREWALL=0"
set "ASSUME_YES=0"
set "ENDACTION=ask"
set "DRYRUN=0"
set "FORCE=0"
set "VERIFY=0"
set "NOMENU=0"
set "STEPNUM=0"
set "FAILS=0"

rem ---------- parse arguments ------------------------------------------
:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="/firewall" set "DO_FIREWALL=1"
if /i "%~1"=="/y"        set "ASSUME_YES=1"
if /i "%~1"=="/force"    set "FORCE=1"
if /i "%~1"=="/verify"   set "VERIFY=1"
if /i "%~1"=="/restart"  set "ENDACTION=restart"
if /i "%~1"=="/shutdown" set "ENDACTION=shutdown"
if /i "%~1"=="/none"     set "ENDACTION=none"
if /i "%~1"=="/dryrun"   set "DRYRUN=1"
if /i "%~1"=="/nomenu"   set "NOMENU=1"
if /i "%~1"=="/?"        goto :usage
if /i "%~1"=="-h"        goto :usage
shift /1
goto :parse
:parsed

rem ---------- menu, shown when double-clicked with no arguments ---------
rem  Double-clicking passes no arguments, so offer the three things you
rem  would actually want. Anything given on the command line skips this.
rem  /nomenu is internal: it is what the elevated copy gets relaunched
rem  with, so the menu is not shown a second time after the UAC prompt.
if not "%ALLARGS%"=="" goto :nomenu
if "%NOMENU%"=="1" goto :nomenu

:menu
cls
echo ===============================================================
echo   NETWORK STACK RESET  -  reboot required
echo ===============================================================
echo.
echo   What do you want to do?
echo.
echo     [1]  RUN THE RESET        (default - just press Enter)
echo          Resets the whole network stack. Needs admin rights,
echo          and the machine has to reboot afterwards.
echo.
echo     [2]  DRY RUN              (safe - changes nothing)
echo          Print every command it would run, then stop.
echo.
echo     [3]  VERIFY               (safe - changes nothing)
echo          Re-run the connectivity checks after a reboot and add
echo          the results to the last reset log.
echo.
set "SEL=1"
set /p "SEL=  Choose 1, 2 or 3, or press Enter for 1: "
if "!SEL!"=="1" ( set "RELAUNCH=/nomenu" & goto :nomenu )
if "!SEL!"=="2" ( set "DRYRUN=1" & goto :nomenu )
if "!SEL!"=="3" ( set "VERIFY=1" & goto :nomenu )
echo.
echo   That was not one of the options. Try again.
echo.
pause
goto :menu

:nomenu

rem ---------- re-launch as administrator if needed ----------------------
rem  The path and the arguments get embedded in a single-quoted PowerShell
rem  string below, so a single quote in either one would end that string
rem  early - a folder like C:\Users\Bob's PC breaks the launch outright,
rem  and an argument could inject PowerShell of its own. PowerShell escapes
rem  a quote inside a single-quoted string by doubling it, so do that.
rem  The "if defined" guard is not decorative: on an undefined variable cmd
rem  does not perform the substitution at all and leaks the literal text,
rem  and the substitution has to be !delayed! so it happens after the guard.
set "PSSCRIPT=%SCRIPT:'=''%"
set "PSARGS="
if defined RELAUNCH set "PSARGS=!RELAUNCH:'=''!"

rem  /verify only reads, and /dryrun only prints, so neither needs elevating
if "%DRYRUN%"=="0" if "%VERIFY%"=="0" (
    net session >nul 2>&1
    if errorlevel 1 (
        echo Administrator rights are required - re-launching elevated...
        if not defined PSARGS (
            powershell -NoProfile -Command "try { Start-Process -FilePath '!PSSCRIPT!' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
        ) else (
            powershell -NoProfile -Command "try { Start-Process -FilePath '!PSSCRIPT!' -ArgumentList '!PSARGS!' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
        )
        if errorlevel 1 (
            echo.
            echo Elevation was declined - nothing has been changed.
            echo.
            pause
        )
        exit /b
    )
)

rem elevation drops us in C:\Windows\System32, so go back to the script
cd /d "%SCRIPTDIR%"

rem ---------- set up logging -------------------------------------------
set "LOGDIR=%SCRIPTDIR%netreset-logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" 2>nul
>"%LOGDIR%\write.test" echo ok 2>nul
if not exist "%LOGDIR%\write.test" (
    set "LOGDIR=%TEMP%\netreset-logs"
    if not exist "!LOGDIR!" mkdir "!LOGDIR!" 2>nul
)
del "%LOGDIR%\write.test" 2>nul

set "STAMP=%RANDOM%"
for /f "delims=" %%A in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmmss"') do set "STAMP=%%A"
set "LOG=%LOGDIR%\netreset_%STAMP%.log"
set "BACKUP=%LOGDIR%\netsh-config_%STAMP%.txt"
set "DNSBAK=%LOGDIR%\dns-static_%STAMP%.txt"
set "WSBAK=%LOGDIR%\winsock-catalog_%STAMP%.txt"

if "%VERIFY%"=="1" goto :verify_mode

>"%LOG%" echo Windows network reset - started %DATE% %TIME%
>>"%LOG%" echo Computer: %COMPUTERNAME%   User: %USERNAME%   Session: %SESSIONNAME%
>>"%LOG%" echo Options: firewall=%DO_FIREWALL% endaction=%ENDACTION% dryrun=%DRYRUN% force=%FORCE%
>>"%LOG%" echo.

rem ---------- refuse to cut the branch we are sitting on -----------------
set "REMOTE=0"
if defined SESSIONNAME if /i not "%SESSIONNAME%"=="Console" set "REMOTE=1"
if defined CLIENTNAME set "REMOTE=1"
if "%REMOTE%"=="1" if "%FORCE%"=="0" goto :remote_abort

rem Only clear when double-clicked. %ALLARGS% is populated when the debloat script
rem calls this with /y /none - clearing there wipes the scrollback of everything the
rem script has done up to this point, which is exactly what you want to read afterwards.
if "%ALLARGS%"=="" cls
echo ===============================================================
echo   WINDOWS NETWORK STACK RESET
echo ===============================================================
echo.
echo   This releases your IP, flushes the DNS/NetBIOS/ARP caches and
echo   resets the TCP/IP, IPv6, Winsock and WinHTTP proxy stacks.
if "%DO_FIREWALL%"=="1" echo   It will ALSO reset Windows Firewall, deleting custom rules.
echo.
echo   You will have no network connectivity until the machine
echo   reboots. Save your work first.
echo.
echo   Log:    %LOG%
echo   Backup: %BACKUP%
if "%DRYRUN%"=="1" echo   *** DRY RUN - nothing will actually be changed ***
echo.

rem  set /p rather than choice, so a mistyped key does not beep at the
rem  console - choice.exe always beeps on a key outside its list and no
rem  flag turns that off. Only Y continues, same as before.
rem  The attempt counter matters: set /p returns an empty string instantly
rem  when stdin is not a console, which would otherwise spin this loop
rem  forever if the script were ever driven non-interactively without /y.
if "%ASSUME_YES%"=="1" goto :confirmed
if "%DRYRUN%"=="1" goto :confirmed
set "TRIES=0"
:confirm
set "YN="
set /p "YN=  Continue? [Y/N] "
if /i "!YN!"=="Y" goto :confirmed
if /i "!YN!"=="YES" goto :confirmed
if /i "!YN!"=="N" goto :aborted
if /i "!YN!"=="NO" goto :aborted
set /a TRIES+=1
if !TRIES! GEQ 10 (
    echo.
    echo   No usable answer after 10 attempts - cancelling.
    goto :aborted
)
echo   Type Y to continue, or N to cancel.
goto :confirm
:confirmed

echo.
echo ---------------------------------------------------------------
echo  PRE-FLIGHT
echo ---------------------------------------------------------------

rem ---------- back up current config before touching anything -----------
echo.
echo Saving netsh configuration backup...
if "%DRYRUN%"=="0" (
    netsh dump > "%BACKUP%" 2>&1
    if exist "%BACKUP%" (echo      [ ok ] %BACKUP%) else (echo      [FAIL] could not write backup)
) else (
    echo      netsh dump  ^>  "%BACKUP%"
)

rem ---------- record the Winsock providers before we wipe them ----------
rem  netsh winsock reset removes third-party layered service providers -
rem  VPN clients, VMware, proxies, some AV. netsh dump does not cover
rem  them, so if networking misbehaves afterwards this file is the only
rem  record of what used to be registered. It is ~540 lines, hence its
rem  own file rather than burying the main log.
echo.
echo Saving the Winsock provider catalog...
if "%DRYRUN%"=="0" (
    call :capture_winsock
    echo      [ ok ] !WSCOUNT! providers - winsock-catalog_%STAMP%.txt
    >>"%LOG%" echo Winsock catalog saved to %WSBAK% - entries: !WSCOUNT!
) else (
    echo      netsh winsock show catalog  ^>  "%WSBAK%"
)

rem ---------- remember statically configured DNS servers ----------------
rem  read straight from the registry: locale independent, and it only
rem  returns servers that were set by hand, not ones handed out by DHCP
echo.
echo Looking for statically configured DNS servers...
set "HAS_STATIC_DNS=0"
call :capture_dns
for %%F in ("%DNSBAK%") do if %%~zF GTR 0 set "HAS_STATIC_DNS=1"
if "%HAS_STATIC_DNS%"=="1" (
    >>"%LOG%" echo Static DNS servers found before reset:
    for /f "usebackq tokens=1,* delims=|" %%A in ("%DNSBAK%") do (
        echo      %%A  ^>  %%B
        >>"%LOG%" echo     %%A = %%B
    )
    echo.
    echo      Saved - these get re-applied after the reset.
) else (
    echo      None found - every adapter takes its DNS from DHCP.
    >>"%LOG%" echo No statically configured DNS servers found.
    del "%DNSBAK%" 2>nul
)
>>"%LOG%" echo.

rem ---------- baseline connectivity, for comparison afterwards ----------
echo.
echo Recording a connectivity baseline...
>>"%LOG%" echo --- BASELINE (before reset) ---
set "GW="
call :find_gateway
if defined GW (
    set "CMD=ping -n 2 !GW!"
    call :check "Default gateway !GW!"
) else (
    echo      No default gateway found
    echo        [none]
    >>"%LOG%" echo CHECK: no default gateway found
)
set "CMD=ping -n 2 8.8.8.8"
call :check "Internet reachability (8.8.8.8)"
set "CMD=nslookup www.microsoft.com"
call :check "DNS resolution"

rem ---------- the actual work -------------------------------------------
echo.
echo ---------------------------------------------------------------
echo  RESET
echo ---------------------------------------------------------------

set "CMD=ipconfig /all"
call :step "Record current adapter configuration in the log"

set "CMD=ipconfig /release"
call :step "Release IPv4 DHCP leases"

set "CMD=ipconfig /release6"
call :step "Release IPv6 DHCP leases"

set "CMD=ipconfig /flushdns"
call :step "Flush the DNS resolver cache"

set "CMD=nbtstat -R"
call :step "Purge the NetBIOS name cache"

set "CMD=nbtstat -RR"
call :step "Release and refresh NetBIOS names"

set "CMD=arp -d *"
call :step "Clear the ARP cache"

set "CMD=netsh int ip reset "%LOGDIR%\ipreset_%STAMP%.log""
call :step "Reset the TCP/IPv4 stack"

set "CMD=netsh int ipv6 reset "%LOGDIR%\ipv6reset_%STAMP%.log""
call :step "Reset the TCP/IPv6 stack"

set "CMD=netsh winsock reset"
call :step "Reset the Winsock catalog"

set "CMD=netsh winhttp reset proxy"
call :step "Clear the system-wide WinHTTP proxy"

if "%DO_FIREWALL%"=="1" (
    set "CMD=netsh advfirewall reset"
    call :step "Reset Windows Firewall to default rules"
)

rem  the ip reset above reverts every adapter to DHCP-supplied DNS, so put
rem  the saved servers back before we renew the lease
if "%HAS_STATIC_DNS%"=="1" call :restore_dns

set "CMD=ipconfig /renew"
call :step "Request a fresh IPv4 lease"

set "CMD=ipconfig /registerdns"
call :step "Re-register this machine in DNS"

rem ---------- summary ---------------------------------------------------
echo.
echo ===============================================================
if "%FAILS%"=="0" (
    echo   All %STEPNUM% steps completed without errors.
) else (
    echo   %STEPNUM% steps run, %FAILS% reported an error - check the log.
    echo   Some errors are normal here, e.g. renewing a lease before the
    echo   reboot has re-armed the Winsock catalog.
)
echo   Log: %LOG%
echo ===============================================================
>>"%LOG%" echo.
>>"%LOG%" echo Finished %DATE% %TIME% - %STEPNUM% steps, %FAILS% failures.

echo.
echo   A REBOOT IS REQUIRED for the Winsock and TCP/IP resets to apply.
if "%HAS_STATIC_DNS%"=="1" echo   Your DNS servers were re-applied - confirm they stuck afterwards.
echo.
echo   Once it is back up, run:  net-reset-reboot.bat /verify
echo   That re-runs the checks above and appends them to the same log,
echo   so you can see whether any of this actually helped.
echo.

if "%DRYRUN%"=="1" (
    echo Dry run complete - no changes were made.
    goto :done
)

rem  Same reasoning as the Continue prompt: no console beep, and a bounded
rem  loop. If no answer can be read at all, the safe fallback is to leave
rem  the machine running rather than reboot it out from under someone.
if /i not "%ENDACTION%"=="ask" goto :act
set "TRIES=0"
:endask
set "EA="
set /p "EA=  Restart now [R], shut down [S], or do nothing [N]? "
if /i "!EA!"=="R" set "ENDACTION=restart"
if /i "!EA!"=="S" set "ENDACTION=shutdown"
if /i "!EA!"=="N" set "ENDACTION=none"
if /i not "!ENDACTION!"=="ask" goto :act
set /a TRIES+=1
if !TRIES! GEQ 10 (
    echo.
    echo   No usable answer after 10 attempts - leaving the machine running.
    set "ENDACTION=none"
    goto :act
)
echo   Type R, S or N.
goto :endask

:act
echo.
if /i "%ENDACTION%"=="restart" (
    echo Restarting in 15 seconds.  Run  shutdown /a  to cancel.
    shutdown /r /t 15 /c "Network stack reset complete - restarting in 15 seconds..."
)
if /i "%ENDACTION%"=="shutdown" (
    echo Shutting down in 15 seconds.  Run  shutdown /a  to cancel.
    shutdown /s /t 15 /c "Network stack reset complete - shutting down in 15 seconds..."
)
if /i "%ENDACTION%"=="none" (
    echo Reboot when you are ready - the network stays broken until you do.
)

:done
echo.
if "%ASSUME_YES%"=="0" pause
endlocal
exit /b 0

rem =====================================================================
rem  /verify - the other half of the baseline taken before the reset
rem =====================================================================
:verify_mode
set "PREVLOG="
for /f "delims=" %%A in ('dir /b /a-d /o-d "%LOGDIR%\netreset_*.log" 2^>nul') do if not defined PREVLOG set "PREVLOG=%LOGDIR%\%%A"
if defined PREVLOG (set "LOG=%PREVLOG%") else (set "LOG=%LOGDIR%\verify_%STAMP%.log")

cls
echo ===============================================================
echo   POST-RESET VERIFICATION
echo ===============================================================
echo.
if defined PREVLOG (
    echo   Appending to the log from the last reset:
) else (
    echo   No previous reset log found, starting a new one:
)
echo   %LOG%
echo.
>>"%LOG%" echo.
>>"%LOG%" echo --- VERIFY (after reset) - %DATE% %TIME% ---

echo Re-running the connectivity checks...
echo.
set "GW="
call :find_gateway
if defined GW (
    set "CMD=ping -n 2 !GW!"
    call :check "Default gateway !GW!"
) else (
    echo      No default gateway found
    echo        [none]
    >>"%LOG%" echo CHECK: no default gateway found
)
set "CMD=ping -n 2 8.8.8.8"
call :check "Internet reachability (8.8.8.8)"
set "CMD=nslookup www.microsoft.com"
call :check "DNS resolution"

echo.
echo Statically configured DNS servers right now:
call :show_dns

echo.
echo ===============================================================
echo   Compare these against the BASELINE section higher up in:
echo   %LOG%
echo ===============================================================
echo.
pause
endlocal
exit /b 0

rem =====================================================================
rem  helpers
rem
rem  The PowerShell one-liners below live in their own subroutines on
rem  purpose. Inside a parenthesised IF block cmd would treat the pipes
rem  and brackets in them as its own syntax and the line would not parse.
rem =====================================================================

rem  :capture_dns - list adapters with hand-set DNS as  name|servers
:capture_dns
powershell -NoProfile -Command "Get-NetAdapter | ForEach-Object { $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $_.InterfaceGuid; $ns = (Get-ItemProperty -Path $p -Name NameServer -ErrorAction SilentlyContinue).NameServer; if ($ns) { $_.Name + '|' + $ns } }" > "%DNSBAK%" 2>nul
exit /b 0

rem  :show_dns - print the static DNS servers as they stand right now
:show_dns
call :capture_dns
set "FOUND=0"
for %%F in ("%DNSBAK%") do if %%~zF GTR 0 set "FOUND=1"
if "%FOUND%"=="1" (
    for /f "usebackq tokens=1,* delims=|" %%A in ("%DNSBAK%") do (
        echo      %%A  ^>  %%B
        >>"%LOG%" echo     DNS now: %%A = %%B
    )
) else (
    echo      None - every adapter is on DHCP-supplied DNS.
    >>"%LOG%" echo     DNS now: none set statically
)
del "%DNSBAK%" 2>nul
exit /b 0

rem  :capture_winsock - save the provider catalog and count the entries
:capture_winsock
set "WSCOUNT=?"
netsh winsock show catalog > "%WSBAK%" 2>&1
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Select-String -LiteralPath '%WSBAK%' -Pattern 'Entry Type' -SimpleMatch).Count"') do set "WSCOUNT=%%A"
exit /b 0

rem  :find_gateway - lowest-metric IPv4 default gateway, into GW
:find_gateway
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop"') do set "GW=%%A"
exit /b 0

rem  :restore_dns - write the saved DNS servers back onto their adapters
:restore_dns
set /a STEPNUM+=1
set "N=0!STEPNUM!"
echo.
echo [!N:~-2!] Restore statically configured DNS servers
echo      Set-DnsClientServerAddress from dns-static_%STAMP%.txt
>>"%LOG%" echo === [!N:~-2!] Restore statically configured DNS servers
>>"%LOG%" echo     source: %DNSBAK%
if "%DRYRUN%"=="1" (
    echo      [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    del "%DNSBAK%" 2>nul
    exit /b 0
)
rem  One adapter at a time, not one pipeline. A single bad adapter - say one
rem  that is Not Present on this machine but still carries static DNS in the
rem  registry - used to abort the whole restore via -ErrorAction Stop, so
rem  every adapter after it was silently skipped and the step reported one
rem  vague failure. Now each is tried on its own, the log names the ones that
rem  fail, and a non-zero exit keeps dns-static so you can recover by hand.
powershell -NoProfile -Command "$bad = @(); foreach ($line in Get-Content -LiteralPath '%DNSBAK%') { $a,$s = $line -split '\|',2; try { Set-DnsClientServerAddress -InterfaceAlias $a -ServerAddresses ($s -split ',') -ErrorAction Stop; '    ok: ' + $a + ' -> ' + $s } catch { $bad += $a; '    FAILED: ' + $a + ' - ' + $_.Exception.Message.Split([char]10)[0] } }; if ($bad.Count) { '    could not restore: ' + ($bad -join ', '); exit 1 }" >>"%LOG%" 2>&1
if errorlevel 1 (
    set /a FAILS+=1
    echo      [FAIL] could not restore - servers are listed in the log
    >>"%LOG%" echo     result: FAILED
) else (
    echo      [ ok ]
    >>"%LOG%" echo     result: ok
    rem  the servers are back on the adapters now, so the scratch copy is
    rem  redundant. On FAILURE it is kept on purpose - it is how you get
    rem  the values back by hand.
    del "%DNSBAK%" 2>nul
)
>>"%LOG%" echo.
exit /b 0

rem  :step - runs a command that changes something. Counts towards FAILS.
:step
set /a STEPNUM+=1
set "N=0!STEPNUM!"
echo.
echo [!N:~-2!] %~1
echo      %CMD%
>>"%LOG%" echo === [!N:~-2!] %~1
>>"%LOG%" echo     command: %CMD%
if "%DRYRUN%"=="1" (
    echo      [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    exit /b 0
)
%CMD% >>"%LOG%" 2>&1
if errorlevel 1 (
    set /a FAILS+=1
    echo      [FAIL] exit code !errorlevel!
    >>"%LOG%" echo     result: FAILED
) else (
    echo      [ ok ]
    >>"%LOG%" echo     result: ok
)
>>"%LOG%" echo.
exit /b 0

rem  :check - read-only probe. A failure here is information, not an error,
rem  so it deliberately does not count towards FAILS: no connectivity is
rem  usually the whole reason someone is running this script.
:check
echo      %~1
>>"%LOG%" echo CHECK: %~1
>>"%LOG%" echo     command: %CMD%
if "%DRYRUN%"=="1" (
    echo        [dry ] skipped
    >>"%LOG%" echo     result: skipped - dry run
    exit /b 0
)
%CMD% >>"%LOG%" 2>&1
if errorlevel 1 (
    echo        [down] no response
    >>"%LOG%" echo     result: unreachable
) else (
    echo        [ up ]
    >>"%LOG%" echo     result: reachable
)
>>"%LOG%" echo.
exit /b 0

:remote_abort
echo.
echo ===============================================================
echo   REMOTE SESSION DETECTED
echo ===============================================================
echo.
echo   Session: %SESSIONNAME%   Client: %CLIENTNAME%
echo.
echo   This script releases the IP address and resets the network
echo   stack. Run over Remote Desktop it drops your connection at
echo   the second step, and you will not be able to reconnect to
echo   finish the job or reboot the machine.
echo.
echo   Run it from the console instead. If you genuinely have
echo   another way back in, re-run with  /force
echo.
>>"%LOG%" echo ABORTED: remote session detected and /force was not given.
pause
endlocal
exit /b 2

:aborted
echo.
echo Cancelled - nothing was changed.
>>"%LOG%" echo ABORTED: user declined at the confirmation prompt.
echo.
pause
endlocal
exit /b 1

:usage
echo net-reset-reboot.bat [/firewall] [/y] [/force] [/dryrun]
echo                      [/restart] [/shutdown] [/none]
echo net-reset-reboot.bat /verify
echo.
echo   /firewall  also reset Windows Firewall - deletes custom rules
echo   /y         skip the confirmation prompt
echo   /force     run even from a remote session - you will be disconnected
echo   /restart   restart when finished - recommended
echo   /shutdown  shut down when finished
echo   /none      leave the machine running
echo   /dryrun    print the commands without running them
echo   /verify    after the reboot: re-run the connectivity checks only
echo              and append them to the last reset log. Changes nothing.
echo.
echo   With no arguments at all it shows a menu: reset, dry run, verify.
endlocal
exit /b 0