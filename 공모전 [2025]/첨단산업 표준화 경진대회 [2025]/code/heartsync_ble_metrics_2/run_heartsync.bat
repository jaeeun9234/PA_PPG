@echo off
setlocal
echo.
echo [HeartSync] Setting up virtual environment...
python -m venv .venv
call .venv\Scripts\activate
python -m pip install --upgrade pip
pip install -r requirements.txt
echo.
echo [HeartSync] Starting collector...
python heartsync_ble_metrics_2.py
