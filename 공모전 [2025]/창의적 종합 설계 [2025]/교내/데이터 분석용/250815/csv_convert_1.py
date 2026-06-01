import serial
import csv
import time
import math
from datetime import datetime

# ===== 설정 =====
COM_PORT = 'COM5'
BAUD_RATE = 115200
OUTPUT_FILE = 'ppg_data_250815.csv'

def to_float(x):
    try:
        # 'nan', 'NaN' 등도 안전하게 처리
        v = float(x)
        return v
    except Exception:
        return float('nan')

# ===== 시리얼 열기 =====
ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
time.sleep(2)
ser.reset_input_buffer()

with open(OUTPUT_FILE, 'w', newline='') as csvfile:
    writer = csv.writer(csvfile)

    # ----- 헤더 (8컬럼 출력도 커버) -----
    # timestamp + s1_smoothed, s1_bpm, s2_smoothed, s2_bpm, delta, median_delta, iqr_delta, valid_ratio + status
    writer.writerow([
        'timestamp',
        'sensor1_smoothed','sensor1_bpm',
        'sensor2_smoothed','sensor2_bpm',
        'delta','median_delta','iqr_delta','valid_ratio',
        'status'
    ])

    print("데이터 수집 시작... 종료하려면 Ctrl+C")

    try:
        while True:
            try:
                line = ser.readline().decode('utf-8', errors='ignore').strip()
            except UnicodeDecodeError:
                continue

            if not line:
                continue

            parts = [p.strip() for p in line.split(',')]

            # 아두이노 출력 형태:
            # 1) 구버전: [s1_smoothed, bpm1, s2_smoothed, bpm2, delta] (len==5)
            # 2) 신버전: [s1_smoothed, bpm1, s2_smoothed, bpm2, delta, median, iqr, valid_ratio] (len==8)
            if len(parts) < 5:
                # 포맷 불일치 → 스킵
                continue

            # 필수 필드 파싱
            s1_sm, bpm1, s2_sm, bpm2, delta = (
                to_float(parts[0]),
                to_float(parts[1]),
                to_float(parts[2]),
                to_float(parts[3]),
                to_float(parts[4]),
            )

            # 통계(있으면 사용, 없으면 NaN으로 채움)
            if len(parts) >= 8:
                med = to_float(parts[5])
                iqr = to_float(parts[6])
                vratio = to_float(parts[7])
            else:
                med = float('nan')
                iqr = float('nan')
                vratio = float('nan')

            # ----- 상태 라벨링 -----
            # 권장 기준: Δ가 유효하고(both not NaN), BPM이 생리 범위(30~180)면 OK, 아니면 SKIP
            ok_bpm = (30.0 <= bpm1 <= 180.0) and (30.0 <= bpm2 <= 180.0)
            ok_delta = not math.isnan(delta)
            status = "OK" if (ok_bpm and ok_delta) else "SKIP"

            # ----- 타임스탬프 + 쓰기 -----
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            row = [
                timestamp,
                s1_sm, bpm1,
                s2_sm, bpm2,
                delta, med, iqr, vratio,
                status
            ]
            writer.writerow(row)
            print(row)

    except KeyboardInterrupt:
        print("데이터 수집 종료")
    finally:
        ser.close()
