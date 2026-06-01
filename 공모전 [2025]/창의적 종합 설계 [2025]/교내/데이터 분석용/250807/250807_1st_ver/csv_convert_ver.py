import serial
import csv
import time
from datetime import datetime

# 설정
COM_PORT = 'COM5'
BAUD_RATE = 115200
OUTPUT_FILE = 'ppg_data_250807.csv'

# 시리얼 포트 열기
ser = serial.Serial(COM_PORT, BAUD_RATE, timeout =1)
time.sleep(2)

# CSV 파일 열기
with open(OUTPUT_FILE, 'w', newline = '') as csvfile:
    writer = csv.writer(csvfile)

    # 헤더 작성
    writer.writerow(['timestamp', 'sensor1_smoothed', 'sensor1_bpm', 'sensor2_smoothed', 'sensor2_bpm', 'status'])

    print("데이터 수집 시작... 종료하려면 Ctrl+C")

    try:
        while True:
            line = ser.readline().decode('utf-8').strip()
            parts = line.strip().split(',')
            
            if len(parts)==4:
                bpm1 = float(parts[1])
                bpm2 = float(parts[3])
                status = "OK" if bpm1 > 0 and bpm2 > 0 else "SKIP"

                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                row = [timestamp] + parts + [status]
                writer.writerow(row)
                print(row)
    except KeyboardInterrupt:
        print("데이터 수집 종료")
    finally:
        ser.close()
