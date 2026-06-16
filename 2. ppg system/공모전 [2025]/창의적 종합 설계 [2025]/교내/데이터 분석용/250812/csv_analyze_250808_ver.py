import pandas as pd
import matplotlib.pyplot as plt

# CSV 파일 경로
file_path = 'ppg_data_250812_0129pm.csv'

# CSV 불러오기
df = pd.read_csv(file_path)

# "status"가 OK인 행만 필터링
df_ok = df[df['status'] == 'OK'].copy()

# timestamp를 datetime 형식으로 변환
df_ok['timestamp'] = pd.to_datetime(df_ok['timestamp'])

# delta 컬럼 숫자형으로 변환
if 'delta' in df_ok.columns:
    df_ok['delta'] = pd.to_numeric(df_ok['delta'], errors='coerce')

# ========== Figure 1: Smoothed + Delta ==========
fig1, axes1 = plt.subplots(2, 1, figsize=(14, 10), sharex=True)

# Smoothed Plot
axes1[0].plot(df_ok['timestamp'], df_ok['sensor1_smoothed'], label='Sensor 1 Smoothed')
axes1[0].plot(df_ok['timestamp'], df_ok['sensor2_smoothed'], label='Sensor 2 Smoothed')
axes1[0].set_title('Smoothed PPG Signal (Sensor 1 vs Sensor 2)')
axes1[0].set_ylabel('Smoothed Value')
axes1[0].legend()
axes1[0].grid(True)

# Delta Plot (only if column exists)
if 'delta' in df_ok.columns:
    pos_delta = df_ok[df_ok['delta'] >= 0]
    neg_delta = df_ok[df_ok['delta'] < 0]

    axes1[1].plot(pos_delta['timestamp'], pos_delta['delta'], 'g.', label='Sensor 1 delayed (Δ > 0)')
    axes1[1].plot(neg_delta['timestamp'], neg_delta['delta'], 'r.', label='Sensor 2 delayed (Δ < 0)')
    axes1[1].axhline(0, color='gray', linestyle='--')
    axes1[1].set_title('Peak Time Difference (delta) — Sensor Lead Indicator')
    axes1[1].set_ylabel('Delta (ms)')
    axes1[1].set_xlabel('Time')
    axes1[1].legend()
    axes1[1].grid(True)
else:
    print("⚠️ 'delta' column not found in the CSV.")

plt.tight_layout()
plt.show()

# ========== Figure 2: BPM ==========
plt.figure(figsize=(14, 5))
plt.plot(df_ok['timestamp'], df_ok['sensor1_bpm'], label='Sensor 1 BPM')
plt.plot(df_ok['timestamp'], df_ok['sensor2_bpm'], label='Sensor 2 BPM')
plt.title('BPM over Time (Sensor 1 vs Sensor 2)')
plt.xlabel('Time')
plt.ylabel('BPM')
plt.legend()
plt.grid(True)
plt.tight_layout()
plt.show()
