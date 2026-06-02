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
REM NOTE: this is the exact build the Release workflow (.github/workflows/release.yml)
REM runs on a v* tag to produce the published Windows .exe.
REM ============================================================================
setlocal
cd /d "%~dp0.."

REM 1) Wire the vendored SFML 3 / CSFML 3 linker paths (LIB / INCLUDE) via the
REM    canonical env shim (delegates to crymble-ui's setup.bat).
call setup.bat || (echo env setup failed & exit /b 1)

REM 2) Compile the icon resource to an ABSOLUTE path. crystal invokes the MSVC
REM    linker from a temporary build directory, so a relative .res path would be
REM    resolved there (not the repo root) and fail with LNK1181.
set "RES=%CD%\resources\embrace.res"
rc.exe /nologo /fo "%RES%" resources\embrace.rc || (echo rc.exe failed & exit /b 1)

REM 3) Ensure the output directory exists — `crystal build -o bin\...` does NOT
REM    create it (a fresh checkout has no bin\), else LINK fails with LNK1104.
if not exist bin mkdir bin

REM 4) Build a STATIC, self-contained .exe (fat binary). --static makes Crystal link
REM    its C deps (iconv, pcre2, xml2, z, gc) statically too — without it they link
REM    dynamically and a clean Windows box errors with "iconv-2.dll not found".
REM    The vendored SFML/CSFML win32 libs are already static, so the result needs no
REM    runtime DLLs. (Also resolves the LNK4098 LIBCMT/CRT-mix warning.)
crystal build src\gui\embrace_main.cr -o bin\embrace.exe --release --no-debug --static ^
    --link-flags "%RES%" || (echo build failed & exit /b 1)

echo.
echo OK: bin\embrace.exe built (with embedded icon).
endlocal
