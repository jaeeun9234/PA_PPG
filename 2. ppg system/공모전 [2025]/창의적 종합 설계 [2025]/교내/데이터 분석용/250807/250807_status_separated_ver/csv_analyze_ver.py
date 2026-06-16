# PPG 분석용 코드
import pandas as pd
import matplotlib.pyplot as plt

# CSV 파일 불러오기
df = pd.read_csv("ppg_data_250807_2nd_ver.csv")

# "OK" 상태만 필터링
df_ok = df[df["status"]=="OK"]

# 데이터 추출
smoothed1 = df_ok["sensor1_smoothed"].values
smoothed2 = df_ok["sensor2_smoothed"].values
bpm1 = df_ok["sensor1_bpm"].values
bpm2 = df_ok["sensor2_bpm"].values

# 2개 그래프 위아래 배치
fig, (ax1, ax2) = plt.subplots(2,1, figsize = (12,8), sharex = True)

# 그래프(1) : smoothed 파형
ax1.plot(smoothed1, label = "sensor1 Smoothed", color = 'blue')
ax1.plot(smoothed2, label = "sensor2 Smoothed", color = 'green')
ax1.set_title("PPG Smoothed Signal (OK only)")
ax1.set_ylabel("Amplitude")
ax1.legend()
ax1.grid(True)

# 그래프(2) : bpm
ax2.plot(bpm1, label = "sensor1 bpm", color = 'red')
ax2.plot(bpm2, label = 'sensor2 bpm', color = 'orange')
ax2.set_title("BPM Comparison (OK only)")
ax2.set_xlabel("Sample Index")
ax2.set_ylabel("BPM")
ax2.legend()
ax2.grid(True)

plt.tight_layout()
plt.show()