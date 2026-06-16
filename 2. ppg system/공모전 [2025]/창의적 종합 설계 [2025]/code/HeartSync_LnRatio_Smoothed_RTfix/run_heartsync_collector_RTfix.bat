@echo off
cd /d "%~dp0"
echo Launching HeartSync BLE Collector (FOI + ln-ratio + smoothing + RT fix)...
python heartsync_ble_metrics_v2_RTfix.py
echo.
pause
