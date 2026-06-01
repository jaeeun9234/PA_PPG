import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import argparse

def _dedup_legend(ax):
    h, l = ax.get_legend_handles_labels()
    seen, H, L = set(), [], []
    for hh, ll in zip(h, l):
        if ll and ll not in seen:
            H.append(hh); L.append(ll); seen.add(ll)
    if H: ax.legend(H, L, loc="best")

def plot_bpm_delta_ppg(csv_path: str, fs: int | None = None, target_points: int = 8000):
    # ---- Load & clean ----
    df = pd.read_csv(csv_path)
    df.columns = [str(c).strip() for c in df.columns]
    if "timestamp" not in df or "status" not in df:
        raise ValueError("CSV must include 'timestamp' and 'status' columns.")
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df["status"] = df["status"].astype(str).str.strip().str.lower()

    # 숫자형 변환
    for col in ["sensor1_smoothed","sensor2_smoothed","sensor1_bpm","sensor2_bpm","delta"]:
        if col in df.columns: df[col] = pd.to_numeric(df[col], errors="coerce")

    # SKIP 제외 + 원본 행순서(이벤트 매핑용) 보존
    df = df[df["status"] != "skip"].copy().reset_index(drop=True)
    df["orig_idx"] = np.arange(len(df))

    # ---- 이벤트(행 순서 기준) 수집 ----
    # start→end: 첫 start 이후의 첫 end만 1개 추출
    start_end_idx = None
    start_rows = df.index[df["status"] == "start"].tolist()
    if start_rows:
        s_i = int(df.loc[start_rows[0], "orig_idx"])
        # s_i 이후의 첫 end
        end_after = df.index[(df["status"] == "end") & (df["orig_idx"] > s_i)].tolist()
        if end_after:
            e_i = int(df.loc[end_after[0], "orig_idx"])
            start_end_idx = (s_i, e_i)

    # high→high: 첫 두 개 high만 1쌍 추출
    high_idx_all = df.loc[df["status"] == "high", "orig_idx"].astype(int).tolist()
    highpair_idx = (high_idx_all[0], high_idx_all[1]) if len(high_idx_all) >= 2 else None

    # ---- 플로팅 데이터: OK만 ----
    ok = df[df["status"] == "ok"].copy().reset_index(drop=True)
    if ok.empty:
        print("No OK rows to plot."); return

    # 샘플레이트
    if fs is None:
        per_sec = ok["timestamp"].dt.floor("S").value_counts().sort_index().values
        fs = int(np.median(per_sec)) if len(per_sec) else 100
    dt_ms = 1000.0 / fs

    # ms 축
    ok["sample_idx"] = np.arange(len(ok))
    x_ms = ok["sample_idx"] * dt_ms

    # 이벤트 인덱스를 OK축(ms)로 스냅
    def idx_to_ms(orig_i: int) -> float:
        ix = ok.index[ok["orig_idx"] >= orig_i]
        sidx = int(ok["sample_idx"].iloc[ix[0]]) if len(ix) else int(ok["sample_idx"].iloc[-1])
        return sidx * dt_ms

    start_end_ms = (idx_to_ms(start_end_idx[0]), idx_to_ms(start_end_idx[1])) if start_end_idx else None
    highpair_ms  = (idx_to_ms(highpair_idx[0]),  idx_to_ms(highpair_idx[1]))  if highpair_idx  else None

    # 디메이션
    n = len(ok); step = max(1, int(np.ceil(n / max(1, target_points))))
    dec = np.arange(n)[::step]

    # 공통: 두 구간 경계선(점선, 서로 다른 색)만 그리기
    def draw_range_lines(ax):
        # start→end : 회색 점선
        if start_end_ms:
            a, b = start_end_ms
            ax.axvline(a, linestyle="--", linewidth=1.8, color="tab:gray", label="start–end boundary")
            ax.axvline(b, linestyle="--", linewidth=1.8, color="tab:gray")
        # high→high : 주황 점선
        if highpair_ms:
            a, b = highpair_ms
            ax.axvline(a, linestyle="--", linewidth=1.8, color="tab:orange", label="high–high boundary")
            ax.axvline(b, linestyle="--", linewidth=1.8, color="tab:orange")

    # ===== Figure A: BPM =====
    plt.figure(figsize=(14,5))
    if "sensor1_bpm" in ok: plt.plot(x_ms.iloc[dec], ok["sensor1_bpm"].iloc[dec], label="Sensor 1 BPM")
    if "sensor2_bpm" in ok: plt.plot(x_ms.iloc[dec], ok["sensor2_bpm"].iloc[dec], label="Sensor 2 BPM")
    plt.title("BPM over Time (x: ms)"); plt.xlabel("Time (ms)"); plt.ylabel("BPM"); plt.grid(True)
    ax = plt.gca(); draw_range_lines(ax); _dedup_legend(ax); plt.tight_layout(); plt.show()

    # ===== Figure B: Δ (원형 마커) =====
    if "delta" in ok:
        plt.figure(figsize=(14,5))
        plt.plot(x_ms.iloc[dec], ok["delta"].iloc[dec], marker="o", linestyle="None", label="Δ (ms)")
        plt.axhline(0, linestyle="--")
        plt.title("Peak Time Difference, Δ (x: ms)"); plt.xlabel("Time (ms)"); plt.ylabel("Delta (ms)"); plt.grid(True)
        axd = plt.gca(); draw_range_lines(axd); _dedup_legend(axd); plt.tight_layout(); plt.show()

    # ===== Figure C: PPG(스무딩) =====
    has1, has2 = "sensor1_smoothed" in ok, "sensor2_smoothed" in ok
    if has1 or has2:
        plt.figure(figsize=(14,5))
        if has1: plt.plot(x_ms.iloc[dec], ok["sensor1_smoothed"].iloc[dec], label="Sensor 1 Smoothed")
        if has2: plt.plot(x_ms.iloc[dec], ok["sensor2_smoothed"].iloc[dec], label="Sensor 2 Smoothed")
        plt.title("PPG Waveforms (Smoothed, x: ms)"); plt.xlabel("Time (ms)"); plt.ylabel("Amplitude"); plt.grid(True)
        axp = plt.gca(); draw_range_lines(axp); _dedup_legend(axp); plt.tight_layout(); plt.show()

    # 요약
    print(f"fs used: {fs} Hz (dt={dt_ms:.2f} ms), OK points={len(ok)}, step={step}")
    print("start–end:", start_end_ms, " | high–high:", highpair_ms)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Plot BPM, Δ, PPG with two dashed ranges (start–end, high–high).")
    ap.add_argument("--csv", type=str, default="ppg_data_250812_4.csv")
    ap.add_argument("--fs", type=int, default=None)
    ap.add_argument("--points", type=int, default=8000)
    args = ap.parse_args()
    plot_bpm_delta_ppg(args.csv, fs=args.fs, target_points=args.points)
