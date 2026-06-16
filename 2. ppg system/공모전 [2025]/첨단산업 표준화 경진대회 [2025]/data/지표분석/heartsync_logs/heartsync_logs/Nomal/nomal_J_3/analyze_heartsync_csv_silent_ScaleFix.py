# -*- coding: utf-8 -*-
"""
HeartSync Dual-PPG Data Analyzer (Silent version, Scale-Fixed, Local)
---------------------------------------------------------------------
- beats_metrics.csv를 현재 폴더에서 읽고 분석
- 그래프 및 요약 CSV를 동일 폴더에 저장
- GUI 창 없이 자동 실행
"""

import os
import pandas as pd
import matplotlib
matplotlib.use("Agg")  # 🔇 GUI 비활성화
import matplotlib.pyplot as plt
import numpy as np
from datetime import datetime

# === 현재 폴더 기준 ===
CUR_DIR = os.path.dirname(os.path.abspath(__file__))
BEAT_CSV = os.path.join(CUR_DIR, "beats_metrics.csv")

if not os.path.exists(BEAT_CSV):
    raise FileNotFoundError(f"CSV 파일을 찾을 수 없습니다: {BEAT_CSV}")

df = pd.read_csv(BEAT_CSV)

# ===== 수치형 변환 =====
for col in ["DeltaTD_ms", "PAD_ms", "AUSPR", "HSI", "AmpRatio_norm"]:
    if col in df.columns:
        df[col] = pd.to_numeric(df[col], errors="coerce")

# ===== 구간 매핑 =====
SECTION_MAP = {
    "baseline": "Baseline",
    "pressure_start": "Pressure",
    "pressure_release": "Recovery"
}
df["Section"] = df["marker"].map(SECTION_MAP).fillna("Other")

# ===== 구간별 통계 요약 =====
stats = (
    df.groupby("Section")[["DeltaTD_ms", "PAD_ms", "AUSPR", "HSI", "AmpRatio_norm"]]
    .agg(["mean", "std", "count"])
    .round(3)
)

timestamp = datetime.now().strftime("%Y-%m-%d_%H%M")
OUT_CSV = os.path.join(CUR_DIR, f"summary_stats_{timestamp}_ScaleFix.csv")
stats.to_csv(OUT_CSV, encoding="utf-8-sig")

# ===== 그래프 저장 =====
plt.rcParams["font.family"] = "Malgun Gothic"
plt.rcParams["axes.unicode_minus"] = False

Y_LIMS = {
    "DeltaTD_ms": (-10, 110),
    "PAD_ms": (-110, 100),
    "AUSPR": (0, 2.2),
    "HSI": (0, 5.5)
}

def save_metric_plot(df, ycol, ylabel, title, fname):
    plt.figure(figsize=(8, 4))
    for sec, color in zip(["Baseline", "Pressure", "Recovery"], ["tab:blue", "tab:red", "tab:green"]):
        sub = df[df["Section"] == sec]
        if not sub.empty:
            plt.scatter(sub.index, sub[ycol], alpha=0.6, label=sec, color=color)
            mean = sub[ycol].mean()
            std = sub[ycol].std()
            plt.axhline(mean, color=color, linestyle="--", linewidth=1)
            plt.fill_between(sub.index, mean - std, mean + std, color=color, alpha=0.1)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xlabel("Beat index")
    plt.legend()
    plt.grid(alpha=0.3)
    plt.tight_layout()
    if ycol in Y_LIMS:
        plt.ylim(Y_LIMS[ycol])
    out_path = os.path.join(CUR_DIR, f"{fname}_{timestamp}_ScaleFix.png")
    plt.savefig(out_path, dpi=200)
    plt.close()
    return out_path

# ===== 실행 =====
paths = []
paths.append(save_metric_plot(df, "DeltaTD_ms", "PWTT (ms)", "PWTT 변화 (ΔTDₘₛ)", "graph_PWTT"))
paths.append(save_metric_plot(df, "PAD_ms", "PAD (ms)", "PADₘₛ 변화 (Foot-to-Foot 차이)", "graph_PAD"))
paths.append(save_metric_plot(df, "AUSPR", "AUSPR (R/L 면적비)", "AUSPR 변화", "graph_AUSPR"))
paths.append(save_metric_plot(df, "HSI", "HSI (혈류 비대칭 지수)", "HSI 변화", "graph_HSI"))

print("✅ 자동 분석 완료 (Y축 스케일 고정, 현재 폴더 저장)")
print(f"요약 CSV: {OUT_CSV}")
print("그래프 저장 완료:")
for p in paths:
    print(" -", p)
