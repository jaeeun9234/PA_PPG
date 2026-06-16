import serial
import csv
import time
from datetime import datetime
import keyboard

# 설정
COM_PORT = 'COM5'
BAUD_RATE = 115200
OUTPUT_FILE = 'ppg_data_250812_0129pm.csv'

# 시리얼 포트 열기
ser = serial.Serial(COM_PORT, BAUD_RATE, timeout =1)
time.sleep(2)

# CSV 파일 열기
with open(OUTPUT_FILE, 'w', newline = '') as csvfile:
    writer = csv.writer(csvfile)

    # 헤더 작성
    writer.writerow(['timestamp', 'sensor1_smoothed', 'sensor1_bpm', 'sensor2_smoothed', 'sensor2_bpm', 'delta', 'status'])

    print("데이터 수집 시작... 종료하려면 Ctrl+C, 's' 키 누르면 start, 'e' 키 누르면 end")

    try:
        while True:
            # 1) 시리얼 데이터 읽기
            if ser.in_waiting:
                line = ser.readline().decode('utf-8').strip()
                parts = line.split(',')

                if len(parts) == 5:
                    bpm1 = float(parts[1])
                    bpm2 = float(parts[3])
                    status = "OK" if bpm1 > 0 and bpm2 > 0 else "SKIP"

                    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                    row = [timestamp] + parts + [status]
                    writer.writerow(row)
                    print(row)

            # 2) 키보드 's' 누름 감지
            if keyboard.is_pressed('s'):
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                msg = [timestamp, 'start', '', '', '', '', 'INFO']
                writer.writerow(msg)
                print(">>> start ----------")
                time.sleep(0.5)  # 중복 입력 방지용 짧은 딜레이
            
            # 2) 키보드 'e' 누름 감지
            if keyboard.is_pressed('e'):
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                msg = [timestamp, 'end', '', '', '', '', 'INFO']
                writer.writerow(msg)
                print(">>> end ----------")
                time.sleep(0.5)  # 중복 입력 방지용 짧은 딜레이

    except KeyboardInterrupt:
        print("데이터 수집 종료")

    finally:
        ser.close()