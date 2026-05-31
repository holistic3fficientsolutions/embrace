@echo off
REM Environment setup for embrace-crystal on Windows.
REM
REM Thin shim: delegates to crymble-ui's own setup.bat — the GUI lib owns
REM the SFML / CSFML vendored libs and is the single source of truth for
REM build env wiring.
REM
REM Usage: call setup.bat (from any directory)

if exist "%~dp0lib\crymble-ui\setup.bat" (
    call "%~dp0lib\crymble-ui\setup.bat"
) else (
    echo ERROR: crymble-ui not found in lib\ — run 'shards install' first 1>&2
    exit /b 1
)
