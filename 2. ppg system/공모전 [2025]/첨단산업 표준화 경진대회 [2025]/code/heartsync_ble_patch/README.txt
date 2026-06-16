
# HeartSync BLE Patch (AUSPR + PWTT + HSI)

## Files
- `heartsync_ble_metrics.py` : BLE 데이터 수신 → 필터링 → Beat 검출 → AUSPR/ΔTD/ΔRT/HSI 계산 및 CSV 저장
- `requirements.txt`        : Python 의존성 (bleak, numpy)
- `run_heartsync.bat`       : (Windows) 자동 설치 + 실행
- `run_heartsync.sh`        : (macOS/Linux) 자동 설치 + 실행

## How to run (Windows)
1) 이 폴더에서 `run_heartsync.bat` 더블클릭 또는 터미널에서 실행
2) 장치가 "HeartSync" 이름으로 광고/노티 중인지 확인
3) 실행 중 마커 입력:
   - b: baseline
   - s: pressure_start
   - e: pressure_end
   - p: peak_pressure (최고압력)
   - u: peak_release  (최고 압력 해제)
   - n: none

## How to run (macOS/Linux)
```bash
chmod +x run_heartsync.sh
./run_heartsync.sh
```

## Outputs
- `heartsync_logs/raw_stream.csv`
  - wall_time, elapsed_s, marker, rawL, rawR, filtL, filtR
- `heartsync_logs/beats_metrics.csv`
  - wall_time, elapsed_s, marker, beat_id, RT_L/R_ms, DeltaRT_ms, AUSP_L/R, AUSPR, DeltaTD_ms, HSI, risk(OK/WARN/HIGH)

## Notes
- 스크립트의 HSI 임계(1.0/2.0)와 파라미터(MIN_PEAK_PROM, PAIR_TOL_SEC, DC_WIN_SEC 등)는 사용 환경에 따라 조정하세요.
- ESP32 스케치는 질문에서 제공한 UUID/이름을 그대로 사용합니다.
