#!/usr/bin/env bash
set -e
echo
echo "[HeartSync] Creating venv..."
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
echo
echo "[HeartSync] Starting collector..."
python heartsync_ble_metrics.py
