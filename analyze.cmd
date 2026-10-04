@echo off
rem Analyse the newest FAF game with DualGap telemetry: report + map.
rem Double-click it, or run: analyze.cmd [path-to-game_123.log]
cd /d "%~dp0"
python tools\parse_match.py %*
python tools\draw_match.py --open %*
echo.
pause
