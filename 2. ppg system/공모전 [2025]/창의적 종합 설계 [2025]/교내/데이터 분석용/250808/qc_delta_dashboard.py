# qc_delta_dashboard.py
import argparse
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

def load_csv(path):
    df = pd.read_csv(path)

    # 헤더 정규화
    def norm(s): return str(s).lower().replace('\ufeff','').strip()
    df.columns = [norm(c) for c in df.columns]

    # 이 파일 헤더를 표준 키로 매핑
    rename = {
        "sensor1_smoothed": "s1",
        "sensor2_smoothed": "s2",
        "sensor1_bpm": "bpm1",
        "sensor2_bpm": "bpm2",
        # delta, timestamp, status 는 이름 그대로 사용
    }
    df = df.rename(columns=rename)

    # (선택) status 컬럼이 있으면 OK만 사용하고 싶다면 아래 두 줄 활성화
    if "status" in df.columns:
        df = df[df["status"].astype(str).str.upper().eq("OK")].copy()

    # 필요한 컬럼만 추려 표준 순서로
    expected = ["timestamp", "s1", "bpm1", "s2", "bpm2", "delta"]
    for c in expected:
        if c not in df.columns:
            raise ValueError(f"Missing expected column: {c}. Got {sorted(df.columns)}")
    df = df[expected]
    return df

def compute_time(df, fs):
    # timestamp가 있으면 그대로, 없으면 샘플 인덱스 기반 생성
    if "timestamp" in df.columns:
        t = pd.to_datetime(df["timestamp"], errors="coerce")
        if t.isna().any():
            # 형식 문제가 있으면 샘플 인덱스로 대체
            t = pd.to_datetime(np.arange(len(df)) / fs, unit="s")
    else:
        t = pd.to_datetime(np.arange(len(df)) / fs, unit="s")
    return t

def robust_amp(series, win):
    # 중앙값 기반 MAD로 진폭(대충 pk-pk) 추정
    med = series.rolling(win, center=True, min_periods=1).median()
    mad = (series - med).abs().rolling(win, center=True, min_periods=1).median()
    amp = 2 * 1.4826 * mad
    return amp

def main(args):
    df = load_csv(args.csv)
    fs = args.fs

    # 시간축 생성
    df["t"] = compute_time(df, fs)

    # 수치형 변환 (timestamp 제외)
    for col in ["s1", "bpm1", "s2", "bpm2", "delta"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    # Δ 이벤트 검출: 값이 변한 시점만 포착
    d = df["delta"].astype(float)
    # pandas FutureWarning 회피: ffill() 사용
    delta_event = d.ffill().diff().fillna(0).abs() > 0.9
    df["delta_event"] = delta_event

    # 품질 관리(QC) 마스크 구성
    # 1) BPM 차이
    bpm_ok = (df["bpm1"] - df["bpm2"]).abs() <= args.bpm_tol

    # 2) 진폭 비율
    win = max(int(1.5 * fs), 5)
    amp1 = robust_amp(df["s1"], win)
    amp2 = robust_amp(df["s2"], win)
    ratio = (amp1 / amp2.replace(0, np.nan)).replace([np.inf, -np.inf], np.nan)
    amp_ok = ratio.between(1/args.amp_ratio, args.amp_ratio)

    # 3) Δ 범위
    delta_ok = d.between(-args.delta_clip, args.delta_clip)

    qc_mask = bpm_ok & amp_ok & delta_ok & df["delta_event"]

    # 매칭률(근사): 기대 박동 수 ≈ ∑(bpm1)/60/fs
    expected_beats = (df["bpm1"].fillna(0).sum() / 60.0) / fs
    matched = int(qc_mask.sum())
    match_rate = (matched / expected_beats) * 100 if expected_beats > 1e-6 else np.nan

    # Δ 통계 (QC 통과 이벤트만)
    delta_valid = d[qc_mask]
    med = delta_valid.median() if not delta_valid.empty else np.nan
    q1  = delta_valid.quantile(0.25) if not delta_valid.empty else np.nan
    q3  = delta_valid.quantile(0.75) if not delta_valid.empty else np.nan
    iqr = q3 - q1 if pd.notna(q3) and pd.notna(q1) else np.nan

    # ---- (1) 파형: 별도 창 ----
    plt.figure(figsize=(10, 4))
    plt.plot(df["t"], df["s1"], label="Sensor 1 Smoothed")
    plt.plot(df["t"], df["s2"], label="Sensor 2 Smoothed")
    plt.title("Smoothed PPG Signal (Sensor 1 vs Sensor 2)")
    plt.ylabel("Smoothed Value")
    plt.legend()
    if args.ylim is not None:
        plt.ylim(-abs(args.ylim), abs(args.ylim))
    plt.tight_layout()
    plt.show()

    # ---- (2) Δ 타임스캐터: 별도 창 ----
    plt.figure(figsize=(10, 4))
    plt.axhline(0, linestyle="--", linewidth=1)
    plt.scatter(df["t"][qc_mask], d[qc_mask], s=12, label="Δ (QC passed)")
    plt.title("Delta over Time (QC-passed events)")
    plt.ylabel("Delta (ms)")
    plt.xlabel("Time")
    plt.legend(loc="upper left")
    plt.tight_layout()
    plt.show()

    # ---- (3) Δ 히스토그램: 별도 창 ----
    plt.figure(figsize=(6, 4))
    if not delta_valid.empty:
        plt.hist(delta_valid, bins=25)
        plt.axvline(med, linestyle="--", label=f"Median {med:.1f} ms")
        plt.title("Delta Histogram (QC-passed)")
        plt.xlabel("Delta (ms)")
        plt.ylabel("Count")
        txt = (f"Matched: {matched}\n"
               f"Expected: {expected_beats:.1f}\n"
               f"Match rate: {match_rate:.1f}%\n"
               f"Median Δ: {med:.1f} ms\n"
               f"IQR: {iqr:.1f} ms\n"
               f"Avg BPM1: {df['bpm1'].mean():.1f}\n"
               f"Avg BPM2: {df['bpm2'].mean():.1f}\n"
               f"|BPM1-BPM2|≤{args.bpm_tol}, amp≤×{args.amp_ratio}, |Δ|≤{args.delta_clip}")
        plt.text(0.98, 0.98, txt, ha="right", va="top", transform=plt.gca().transAxes)
        plt.legend()
    else:
        plt.title("No QC-passed delta events")
        plt.text(0.5, 0.5, "No data after QC", ha="center", va="center", transform=plt.gca().transAxes)
    plt.tight_layout()
    plt.show()

    # 콘솔 요약(작은 화면에서 편하게 수치만 확인)
    print("\n=== QC SUMMARY ===")
    print(f"Matched events : {matched}")
    print(f"Expected beats : {expected_beats:.1f}")
    print(f"Match rate     : {match_rate:.1f}%")
    print(f"Median Δ (ms)  : {med:.1f}")
    print(f"IQR (ms)       : {iqr:.1f}")
    print(f"Avg BPM1       : {df['bpm1'].mean():.1f}")
    print(f"Avg BPM2       : {df['bpm2'].mean():.1f}")
    print(f"Filters        : |BPM1-BPM2|≤{args.bpm_tol}, amp≤×{args.amp_ratio}, |Δ|≤{args.delta_clip}")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("csv", help="CSV file path")
    p.add_argument("--fs", type=int, default=100, help="sampling rate (Hz)")
    p.add_argument("--delta_clip", type=float, default=200, help="abs delta limit (ms)")
    p.add_argument("--bpm_tol", type=float, default=8, help="|bpm1-bpm2| tolerance")
    p.add_argument("--amp_ratio", type=float, default=4, help="allowed amplitude ratio (max)")
    p.add_argument("--ylim", type=float, default=None, help="fix y-limit for waveform plot")
    args = p.parse_args()
    main(args)
