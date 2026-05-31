@echo off
REM ============================================================================
REM Windows release build for Embrace (AGPL) — single, self-contained script.
REM Produces bin\embrace.exe WITH the application icon embedded.
REM
REM Prerequisites:
REM   1. An MSVC "x64 Native Tools" command prompt (provides cl.exe, link.exe, rc.exe).
REM   2. shards install --skip-postinstall
REM      (crymble-ui ships the SFML 3 / CSFML 3 win32 static libs, so there is no
REM       separate SFML build step.)
REM
REM The two proprietary steps the old internal build had — symbol obfuscation and
REM checksum patching — are intentionally GONE and must NOT return (incompatible
REM with the AGPL release).
REM
REM NOTE: untested in CI — validate on the first local Windows build and adjust if needed.
REM ============================================================================
setlocal
cd /d "%~dp0.."

REM 1) Wire the vendored SFML 3 / CSFML 3 linker paths (LIB / INCLUDE) via the
REM    canonical env shim (delegates to crymble-ui's setup.bat).
call setup.bat || (echo env setup failed & exit /b 1)

REM 2) Compile the icon resource (rc.exe is part of the MSVC toolchain).
rc.exe /nologo /fo resources\embrace.res resources\embrace.rc || (echo rc.exe failed & exit /b 1)

REM 3) Build, linking the icon resource into the executable.
crystal build src\gui\embrace_main.cr -o bin\embrace.exe --release --no-debug ^
    --link-flags resources\embrace.res || (echo build failed & exit /b 1)

echo.
echo OK: bin\embrace.exe built (with embedded icon).
endlocal
