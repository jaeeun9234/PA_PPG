@echo off
setlocal
REM Optional envs:
REM set AMP_RATIO_BAND=0.25
REM set AUTO_BASELINE_SEC=8
REM set GAIN_L=1.0
REM set GAIN_R=1.0

if not exist "heartsync_logs" mkdir "heartsync_logs"

echo Running HeartSync BLE Collector (AmpRatio norm)...
python "%~dp0heartsync_ble_collector_amp_ratio_norm.py"
echo.
echo Finished. Logs are in ".\heartsync_logs"
pause
