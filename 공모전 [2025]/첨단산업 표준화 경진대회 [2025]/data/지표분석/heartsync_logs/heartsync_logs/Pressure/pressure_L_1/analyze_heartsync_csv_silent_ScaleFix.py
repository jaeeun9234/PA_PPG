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

# ===== HSI 재계산: 공식 기반 =====
# HSI = ln(AmpRatio_norm) / ln(1.30)  +  max(0, PWTT - 40) / 25

EPS = 1e-6  # ln 안정성 확보용

if {"DeltaTD_ms", "AmpRatio_norm"}.issubset(df.columns):

    # 1) 첫 번째 항: ln(AmpRatio_norm) / ln(1.30)
    term1 = np.log(df["AmpRatio_norm"].abs() + EPS) / np.log(1.30)

    # 2) 두 번째 항: max(0, PWTT - 40) / 25
    PWTT = df["DeltaTD_ms"]
    term2 = np.maximum(0, PWTT - 40) / 25

    # 최종 HSI
    df["HSI"] = term1 + term2

    # Y축 스케일 설정용 최대값
    max_abs_hsi = df["HSI"].abs().max()

else:
    max_abs_hsi = np.nan

# ===== 구간 매핑 =====
SECTION_MAP = {
    "baseline": "Baseline",
    "pressure_start": "Pressure",
    "pressure_release": "Recovery"
}
df["Section"] = df["marker"].map(SECTION_MAP).fillna("Other")

# ===== 구간별 통계 요약 (HSI는 재계산된 값 기준) =====
stats = (
    df.groupby("Section")[["DeltaTD_ms", "PAD_ms", "AUSPR", "HSI", "AmpRatio_norm"]]
    .agg(["mean", "std", "count"])
    .round(3)
)

timestamp = datetime.now().strftime("%Y-%m-%d_%H%M")
OUT_CSV = os.path.join(CUR_DIR, f"summary_stats_{timestamp}_ScaleFix.csv")
stats.to_csv(OUT_CSV, encoding="utf-8-sig")

# ===== 그래프 저장 세팅 =====
plt.rcParams["font.family"] = "Malgun Gothic"
plt.rcParams["axes.unicode_minus"] = False

# HSI, AmpRatio_norm은 데이터에 맞춰 Y축 자동 설정
amp_abs_max = df["AmpRatio_norm"].abs().max() if "AmpRatio_norm" in df.columns else np.nan
amp_ymax = float(amp_abs_max) * 1.1 if not np.isnan(amp_abs_max) else 2.0
hsi_ymax = float(max_abs_hsi) * 1.1 if not np.isnan(max_abs_hsi) else 5.5

# 절댓값 기준이므로 모두 0 이상으로 설정
Y_LIMS = {
    "DeltaTD_ms": (0, 110),
    "PAD_ms": (0, 110),
    "AUSPR": (0, 2.2),
    "AmpRatio_norm": (0, amp_ymax),
    "HSI": (0, hsi_ymax)
}

# x축 범위 (beat index 205 ~ 225만 표시)
X_MIN = 0
X_MAX = 225

def save_metric_plot(df, ycol, ylabel, title, fname):
    plt.figure(figsize=(8, 4))

    for sec, color in zip(["Baseline", "Pressure", "Recovery"],
                          ["black", "tab:red", "tab:green"]):

        # 205~225 구간만 사용
        sub = df[(df["Section"] == sec) & (df.index >= X_MIN) & (df.index <= X_MAX)]
        if not sub.empty:
            # Y값은 절댓값으로 그림
            y_vals = sub[ycol].abs()

            plt.scatter(sub.index, y_vals, alpha=0.6, label=sec, color=color)

            mean = y_vals.mean()
            std = y_vals.std()

            plt.axhline(mean, color=color, linestyle="--", linewidth=1)
            plt.fill_between(
                sub.index,
                mean - std,
                mean + std,
                alpha=0.1,
                color=color
            )

    plt.title(title)
    plt.ylabel(ylabel)
    plt.xlabel("Beat index")
    # plt.legend()  # 필요하면 켜기
    plt.grid(alpha=0.3)
    plt.tight_layout()

    # X, Y축 범위 고정
    plt.xlim(X_MIN, X_MAX)
    if ycol in Y_LIMS:
        plt.ylim(Y_LIMS[ycol])

    out_path = os.path.join(CUR_DIR, f"{fname}_{timestamp}_ScaleFix.png")
    plt.savefig(out_path, dpi=200)
    plt.close()
    return out_path

# ===== 실행 =====
paths = []
paths.append(save_metric_plot(df, "DeltaTD_ms", "PWTT (ms)", "PWTT 변화 (|PWTT|)", "graph_PWTT"))
paths.append(save_metric_plot(df, "PAD_ms", "PAD (ms)", "PAD 변화 (|Foot-to-Foot 차이|)", "graph_PAD"))
paths.append(save_metric_plot(df, "AUSPR", "AUSPR (R/L 면적비)", "AUSPR 변화 (|AUSPR|)", "graph_AUSPR"))
paths.append(save_metric_plot(df, "AmpRatio_norm", "AmpRatio_norm", "AmpRatio_norm 변화 (|AmpRatio_norm|)", "graph_AmpRatio"))
paths.append(save_metric_plot(df, "HSI", "HSI", "HSI 변화", "graph_HSI"))

print("✅ 자동 분석 완료 (X=205~225, Y 절댓값, AmpRatio_norm/HSI 포함, 현재 폴더 저장)")
print(f"요약 CSV: {OUT_CSV}")
print("그래프 저장 완료:")
for p in paths:
    print(" -", p)
