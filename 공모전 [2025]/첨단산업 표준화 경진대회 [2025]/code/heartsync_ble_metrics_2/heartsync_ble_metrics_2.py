# heartsync_ble_metrics.py (FOI + linear HSI)
# - ESP32(위 아두이노 코드)의 BLE 노티("timestamp_us,left,right\n")를 수신
# - DC 제거(이동평균) + 이동평균 평활 + [옵션] FOI(분수차수 적분)
# - 박(foot/peak) 검출 → AUSP(AUSPR), ΔTD(PWTT), ΔRT 계산  [*FOI 신호 기준*]
# - HSI = |AUSPR-1|/0.05 + max(0, ΔTD-20ms)/12  → risk 등급(OK/WARN/HIGH)
# - 마커: baseline / pressure_start / pressure_end / peak_pressure / peak_release / none
# - 초단위 벽시각 포함하여 raw_stream.csv, beats_metrics.csv 저장

import asyncio, sys, csv, os, signal, math
from datetime import datetime
from collections import deque
import numpy as np
from bleak import BleakScanner, BleakClient

# ==== BLE UUIDs (ESP32 sketch와 동일) ====
SERVICE_UUID = "5ba7a52c-c3fe-46eb-8ade-0dacbd466278"
CHAR_UUID    = "5dde726d-4cf3-4e2f-ab24-323caa359b78"
DEVICE_NAME  = "HeartSync"

# ==== 필터/검출 파라미터 ====
FS_HZ = 50
DT = 1.0 / FS_HZ
DC_WIN_SEC = 1.5
DC_N = max(3, int(DC_WIN_SEC * FS_HZ))   # ~75
SMOOTH_N = 5

REFRACT_SEC = 0.35
MIN_PEAK_PROM = 30.0     # FOI 적용 후 진폭 스케일에 따라 20~40로 재튜닝 권장
PAIR_TOL_SEC = 0.10

# ==== FOI(분수차수 적분) 파라미터 ====
FOI_ENABLE   = True          # FOI 사용 여부
FOI_ORDER    = 0.7           # μ: 0<μ<1 (0.4~0.6 권장)
FOI_WIN_SEC  = 3.0           # 적분 윈도 길이(초) 2~5 s 권장
FOI_N        = max(10, int(FOI_WIN_SEC * FS_HZ))
LOG_FOI_COLUMNS = False      # raw_stream.csv에 FOI 신호 추가 로깅 여부(열 2개 추가)

# ==== AUSPR/HSI & Risk 규칙 ====
AUSPR_NORMAL_BAND = 0.05       # |AUSPR-1| ≤ 0.05 정상대역(문헌 참고치)
HSI_TD_BASE = 20.0             # ms
HSI_TD_SCALE = 12.0            # ms
HSI_WARN  = 1.0
HSI_HIGH  = 2.0

# ==== 출력 파일 ====
LOG_DIR = "./heartsync_logs"
RAW_CSV = os.path.join(LOG_DIR, "raw_stream.csv")
BEAT_CSV = os.path.join(LOG_DIR, "beats_metrics.csv")

# ==== 전역 상태 ====
current_marker = "none"  # baseline / pressure_start / pressure_end / peak_pressure / peak_release / none

# ===== 유틸 =====
def wall_time_str():
    return datetime.now().isoformat(timespec="seconds")

def risk_from_hsi(hsi: float) -> str:
    if not np.isfinite(hsi): return "NA"
    if hsi >= HSI_HIGH: return "HIGH"
    if hsi >= HSI_WARN: return "WARN"
    return "OK"

class MovingAverage:
    def __init__(self, n):
        self.n = max(1, int(n))
        self.buf = deque(maxlen=self.n)
        self.sum = 0.0
    def push(self, x: float) -> float:
        if len(self.buf) == self.n:
            self.sum -= self.buf[0]
        self.buf.append(x)
        self.sum += x
        return self.sum / len(self.buf)

def trapezoid_area(y: np.ndarray, dt: float) -> float:
    if len(y) < 2: return 0.0
    return float(np.trapz(y, dx=dt))

# ====== FOI (Grünwald–Letnikov fractional integral) ======
class FractionalIntegratorGL:
    """
    Grünwald–Letnikov fractional integral of order μ (>0), finite window M.
    y[n] = (dt^μ / Γ(μ)) * sum_{k=0..M-1} c_k * x[n-k]
    c_0 = 1, c_k = c_{k-1} * ((k-1+μ)/k)
    """
    def __init__(self, mu: float, M: int, dt: float):
        assert 0.0 < mu < 1.0
        self.mu = float(mu)
        self.M  = int(M)
        self.dt = float(dt)
        self.buf = deque(maxlen=self.M)
        # GL 계수 사전계산 (적분형, 양의 계수 단조감소)
        w = [1.0]
        for k in range(1, self.M):
            w.append(w[-1] * ((k - 1 + self.mu) / k))
        scale = (self.dt ** self.mu) / math.gamma(self.mu)
        self.weights = np.array(w, dtype=float) * scale  # shape (M,)
    def push(self, x: float) -> float:
        self.buf.append(float(x))
        arr = np.fromiter(self.buf, dtype=float)  # oldest→newest
        w = self.weights[:len(arr)]
        # newest가 arr[-1]이므로 arr[::-1]과 w를 내적
        return float(np.dot(w, arr[::-1]))

# ====== 박(foot/peak) 검출 ======
class BeatDetector:
    def __init__(self, fs_hz: int, min_prom: float, refract_sec: float):
        self.fs = fs_hz
        self.min_prom = min_prom
        self.refract = int(refract_sec * fs_hz)
        self.last_peak_idx = -99999
        self.buffer = deque(maxlen=7)  # 7-point 미분 없는 간단 로컬 최대 검출
        self.peaks, self.foots = [], []
    def update(self, x: float, idx: int):
        self.buffer.append((idx, x))
        if len(self.buffer) == self.buffer.maxlen:
            i_mid, y_mid = self.buffer[3]
            _, y_prev = self.buffer[2]
            _, y_next = self.buffer[4]
            if y_mid > y_prev and y_mid > y_next:
                if (i_mid - self.last_peak_idx) >= self.refract and y_mid >= self.min_prom:
                    local = list(self.buffer)
                    foot_idx, foot_val = min(local[:4], key=lambda t: t[1])
                    self.foots.append((foot_idx, foot_val))
                    self.peaks.append((i_mid, y_mid))
                    self.last_peak_idx = i_mid
    def consume_beats(self):
        n = min(len(self.foots), len(self.peaks))
        out = []
        for k in range(n):
            fi, fv = self.foots[k]
            pi, pv = self.peaks[k]
            if pi > fi:
                out.append({"foot_idx": fi, "foot_val": fv, "peak_idx": pi, "peak_val": pv})
        self.foots, self.peaks = [], []
        return out

# ====== 좌/우 beat pairing ======
class Pairer:
    def __init__(self, fs_hz: int, tol_sec: float):
        self.fs = fs_hz
        self.tol = tol_sec
        self.L, self.R = deque(), deque()
    def push_beats(self, side: str, beats: list):
        if side == "L":
            for b in beats: self.L.append(b)
        else:
            for b in beats: self.R.append(b)
    def pair(self):
        out = []
        if not self.L or not self.R: return out
        used_R = set()
        for bl in list(self.L):
            tL = bl["peak_idx"] / self.fs
            best = None; best_j = None
            for j, br in enumerate(list(self.R)):
                if j in used_R: continue
                tR = br["peak_idx"] / self.fs
                d = abs(tL - tR)
                if d <= self.tol and (best is None or d < best):
                    best, best_j = d, j
            if best_j is not None:
                used_R.add(best_j)
                out.append((bl, list(self.R)[best_j]))
        if out:
            matchedL = {bL["peak_idx"] for bL,_ in out}
            self.L = deque([b for b in self.L if b["peak_idx"] not in matchedL])
            matchedR = {bR["peak_idx"] for _,bR in out}
            self.R = deque([b for b in self.R if b["peak_idx"] not in matchedR])
        return out

# ====== 마커 입력 ======
async def read_markers():
    """
    콘솔 입력:
      b=baseline, s=pressure_start, e=pressure_end, p=peak_pressure, u=peak_release, n=none
    """
    global current_marker
    loop = asyncio.get_event_loop()
    def blocking_input():
        try: return sys.stdin.readline()
        except: return None
    print("[Marker] b=baseline, s=pressure_start, e=pressure_end, p=peak_pressure, u=peak_release, n=none")
    while True:
        line = await loop.run_in_executor(None, blocking_input)
        if not line:
            await asyncio.sleep(0.05)
            continue
        line = line.strip().lower()
        if   line == "b": current_marker = "baseline"
        elif line == "s": current_marker = "pressure_start"
        elif line == "e": current_marker = "pressure_end"
        elif line == "p": current_marker = "peak_pressure"
        elif line == "u": current_marker = "peak_release"
        elif line == "n": current_marker = "none"
        print(f"[Marker] -> {current_marker}")

# ====== 메인 처리 ======
async def connect_and_run():
    os.makedirs(LOG_DIR, exist_ok=True)
    # raw_stream.csv 헤더
    with open(RAW_CSV, "w", newline="") as f:
        header = ["wall_time", "elapsed_s", "marker", "rawL", "rawR", "filtL", "filtR"]
        if LOG_FOI_COLUMNS:
            header += ["filtL_foi", "filtR_foi"]
        csv.writer(f).writerow(header)
    # beats_metrics.csv 헤더 (동일 유지)
    with open(BEAT_CSV, "w", newline="") as f:
        csv.writer(f).writerow([
            "wall_time","elapsed_s","marker","beat_id",
            "footL_idx","peakL_idx","footR_idx","peakR_idx",
            "RT_L_ms","RT_R_ms","DeltaRT_ms",
            "AUSP_L","AUSP_R","AUSPR",
            "DeltaTD_ms","HSI","risk"
        ])

    print("[BLE] Scanning for device named 'HeartSync' ...")
    dev = await BleakScanner.find_device_by_filter(lambda d, ad: d.name and DEVICE_NAME in d.name)
    if not dev:
        print("! Device not found. Make sure it is advertising as 'HeartSync'")
        return

    start_mono = asyncio.get_event_loop().time()
    dcL, dcR = MovingAverage(DC_N), MovingAverage(DC_N)
    smoothL, smoothR = MovingAverage(SMOOTH_N), MovingAverage(SMOOTH_N)
    foiL = FractionalIntegratorGL(FOI_ORDER, FOI_N, DT) if FOI_ENABLE else None
    foiR = FractionalIntegratorGL(FOI_ORDER, FOI_N, DT) if FOI_ENABLE else None

    idx = 0
    detL = BeatDetector(FS_HZ, MIN_PEAK_PROM, REFRACT_SEC)
    detR = BeatDetector(FS_HZ, MIN_PEAK_PROM, REFRACT_SEC)
    pairer = Pairer(FS_HZ, PAIR_TOL_SEC)
    filtL_hist, filtR_hist = [], []
    beat_counter = 0

    def parse_and_process(data: bytearray):
        nonlocal idx, beat_counter, filtL_hist, filtR_hist
        try:
            t_us_str, rawL_str, rawR_str = data.decode("utf-8").strip().split(",")
            rawL, rawR = int(rawL_str), int(rawR_str)
        except:
            return

        now_wall = wall_time_str()
        elapsed_s = asyncio.get_event_loop().time() - start_mono

        # DC 제거 + 평활
        xL = rawL - dcL.push(rawL)
        xR = rawR - dcR.push(rawR)
        yL = smoothL.push(xL)
        yR = smoothR.push(xR)

        # === FOI 적용 ===
        if FOI_ENABLE:
            yL_foi = foiL.push(yL)
            yR_foi = foiR.push(yR)
        else:
            yL_foi, yR_foi = yL, yR

        # 검출·특징은 FOI 신호 기준
        filtL_hist.append(yL_foi)
        filtR_hist.append(yR_foi)

        # raw_stream.csv 로깅 (기존 열 유지, 옵션으로 FOI 열 추가)
        with open(RAW_CSV, "a", newline="") as f:
            row = [now_wall, f"{elapsed_s:.3f}", current_marker, rawL, rawR, f"{yL:.3f}", f"{yR:.3f}"]
            if LOG_FOI_COLUMNS:
                row += [f"{yL_foi:.3f}", f"{yR_foi:.3f}"]
            csv.writer(f).writerow(row)

        # 박 검출 (FOI 신호에서)
        detL.update(yL_foi, idx)
        detR.update(yR_foi, idx)
        beatsL = detL.consume_beats()
        beatsR = detR.consume_beats()

        # AUSP/RT 계산 (FOI 신호 구간 적분)
        for b in beatsL:
            fi, pi = b["foot_idx"], b["peak_idx"]
            if 0 <= fi < pi <= len(filtL_hist)-1:
                seg = np.clip(np.array(filtL_hist[fi:pi+1], float), 0, None)
                b["AUSP"] = trapezoid_area(seg, DT)
                b["RT_ms"] = (pi - fi) * 1000.0 * DT
            else:
                b["AUSP"] = 0.0; b["RT_ms"] = np.nan
        for b in beatsR:
            fi, pi = b["foot_idx"], b["peak_idx"]
            if 0 <= fi < pi <= len(filtR_hist)-1:
                seg = np.clip(np.array(filtR_hist[fi:pi+1], float), 0, None)
                b["AUSP"] = trapezoid_area(seg, DT)
                b["RT_ms"] = (pi - fi) * 1000.0 * DT
            else:
                b["AUSP"] = 0.0; b["RT_ms"] = np.nan

        if beatsL: pairer.push_beats("L", beatsL)
        if beatsR: pairer.push_beats("R", beatsR)

        # 좌우 beat 매칭 및 HSI 계산 (선형식 그대로)
        pairs = pairer.pair()
        if pairs:
            with open(BEAT_CSV, "a", newline="") as f:
                w = csv.writer(f)
                for (bL, bR) in pairs:
                    beat_counter += 1
                    dt_ms  = abs(bL["peak_idx"] - bR["peak_idx"]) * 1000.0 * DT
                    drt_ms = abs(bL.get("RT_ms", np.nan) - bR.get("RT_ms", np.nan))
                    auspr  = (bR["AUSP"] / bL["AUSP"]) if bL["AUSP"] > 1e-6 else np.nan
                    term1  = abs(auspr - 1.0) / AUSPR_NORMAL_BAND if np.isfinite(auspr) else 0.0
                    term2  = max(0.0, dt_ms - HSI_TD_BASE) / HSI_TD_SCALE
                    hsi    = term1 + term2
                    risk   = risk_from_hsi(hsi)

                    # 콘솔 피드백
                    tag = f"[{risk}]"
                    if risk == "HIGH": tag = f"\033[91m{tag}\033[0m"
                    elif risk == "WARN": tag = f"\033[93m{tag}\033[0m"
                    print(f"{tag} beat#{beat_counter}  AUSPR={auspr:.3f}  ΔTD={dt_ms:.1f}ms  HSI={hsi:.2f}  marker={current_marker}")

                    w.writerow([
                        now_wall, f"{elapsed_s:.3f}", current_marker,
                        beat_counter,
                        bL["foot_idx"], bL["peak_idx"], bR["foot_idx"], bR["peak_idx"],
                        f"{bL.get('RT_ms', np.nan):.1f}", f"{bR.get('RT_ms', np.nan):.1f}", f"{drt_ms:.1f}",
                        f"{bL['AUSP']:.3f}", f"{bR['AUSP']:.3f}",
                        f"{auspr:.3f}" if np.isfinite(auspr) else "",
                        f"{dt_ms:.1f}", f"{hsi:.3f}", risk
                    ])

        idx += 1

    async with BleakClient(dev) as client:
        if not client.is_connected:
            print("! Failed to connect")
            return
        print(f"[BLE] Connected: {dev.address}")
        await client.start_notify(CHAR_UUID, lambda _, data: parse_and_process(data))
        print("[BLE] Notifications started. Logging... (Ctrl+C to stop)")

        stop_event = asyncio.Event()
        def handle_sig(*_): stop_event.set()
        for s in (signal.SIGINT, signal.SIGTERM):
            try: asyncio.get_event_loop().add_signal_handler(s, handle_sig)
            except NotImplementedError: pass
        await stop_event.wait()
        await client.stop_notify(CHAR_UUID)
        print("[BLE] Stopped.")

async def main():
    await asyncio.gather(connect_and_run(), read_markers())

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
