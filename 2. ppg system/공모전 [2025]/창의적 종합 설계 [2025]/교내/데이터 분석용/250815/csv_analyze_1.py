import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import argparse

def load_csv(path):
    df = pd.read_csv(path)
    # 컬럼 소문자/공백 정리
    df.columns = [c.strip().lower() for c in df.columns]
    # 필수 컬럼 체크
    need = ["timestamp","sensor1_smoothed","sensor1_bpm","sensor2_smoothed","sensor2_bpm","delta"]
    missing = [c for c in need if c not in df.columns]
    if missing:
        raise ValueError(f"CSV에 필요한 컬럼이 없습니다: {missing}")

    # datetime 변환
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df = df.dropna(subset=["timestamp"]).reset_index(drop=True)

    # 숫자 변환 (NaN 안전)
    for c in ["sensor1_smoothed","sensor1_bpm","sensor2_smoothed","sensor2_bpm","delta",
              "median_delta","iqr_delta","valid_ratio"]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    # status가 있으면 OK/나머지 구간 마스크 만들기
    if "status" in df.columns:
        df["ok"] = (df["status"].str.upper() == "OK")
    else:
        df["ok"] = True
    return df

def plot_all(df, title=None, save=None):
    t = df["timestamp"]

    # ===== Figure 1: Smoothed PPG (s1, s2) =====
    plt.figure(figsize=(12,4))
    plt.plot(t, df["sensor1_smoothed"], label="S1 smoothed")
    plt.plot(t, df["sensor2_smoothed"], label="S2 smoothed")
    plt.title(title or "Smoothed PPG signals")
    plt.xlabel("Time")
    plt.ylabel("Amplitude (a.u.)")
    plt.legend()
    plt.grid(True, alpha=0.3)
    if save: plt.savefig(f"{save}_smoothed.png", dpi=150, bbox_inches="tight")

    # ===== Figure 2: BPM (s1, s2) =====
    plt.figure(figsize=(12,4))
    plt.plot(t, df["sensor1_bpm"], label="S1 BPM")
    plt.plot(t, df["sensor2_bpm"], label="S2 BPM")
    plt.title("BPM over time")
    plt.xlabel("Time")
    plt.ylabel("BPM")
    plt.ylim(30, 180)  # 필요시 조정
    plt.legend()
    plt.grid(True, alpha=0.3)
    if save: plt.savefig(f"{save}_bpm.png", dpi=150, bbox_inches="tight")

    # ===== Figure 3: Δ time (ms) + (선택) median/IQR =====
    plt.figure(figsize=(12,4))
    # Δ 산점 + 선 (NaN 자동 생략)
    plt.plot(t, df["delta"], marker='.', linestyle='-', linewidth=1, markersize=2, label="Δ (ms)")

    # median_delta / iqr_delta 있으면 같이 표시
    if "median_delta" in df.columns:
        plt.plot(t, df["median_delta"], linestyle='--', label="median Δ (ms)")
    if "iqr_delta" in df.columns:
        plt.plot(t, df["iqr_delta"], linestyle=':', label="IQR Δ (ms)")

    # valid_ratio가 있으면 보조축으로 표시 (0~1)
    if "valid_ratio" in df.columns and df["valid_ratio"].notna().any():
        ax = plt.gca()
        ax2 = ax.twinx()
        ax2.plot(t, df["valid_ratio"], alpha=0.5, label="valid ratio", linewidth=1)
        ax2.set_ylabel("valid ratio")
        # 범례 합치기
        h1, l1 = ax.get_legend_handles_labels()
        h2, l2 = ax2.get_legend_handles_labels()
        ax2.legend(h1+h2, l1+l2, loc="upper left")
    else:
        plt.legend()

    plt.title("Δ time between sensors")
    plt.xlabel("Time")
    plt.ylabel("Δ (ms)")
    plt.grid(True, alpha=0.3)

    # status가 있으면 SKIP 구간 음영 처리
    if "ok" in df.columns and (~df["ok"]).any():
        ax = plt.gca()
        bad = df[~df["ok"]]["timestamp"]
        # 연속 구간 감지
        if len(bad)>0:
            # 인접한 시간 간격 기준으로 뭉치기 (간단히 연속 인덱스 방식)
            bad_idx = np.where(~df["ok"].values)[0]
            groups = np.split(bad_idx, np.where(np.diff(bad_idx)!=1)[0]+1)
            for g in groups:
                if len(g)==0: continue
                ax.axvspan(df["timestamp"].iloc[g[0]], df["timestamp"].iloc[g[-1]], color='gray', alpha=0.15)
    if save: plt.savefig(f"{save}_delta.png", dpi=150, bbox_inches="tight")

    plt.show()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", help="CSV file path")
    parser.add_argument("--save-prefix", default=None, help="파일로 저장할 때 접두사 (예: out/ppg)")
    args = parser.parse_args()

    df = load_csv(args.csv)
    plot_all(df, title=args.csv, save=args.save_prefix)
