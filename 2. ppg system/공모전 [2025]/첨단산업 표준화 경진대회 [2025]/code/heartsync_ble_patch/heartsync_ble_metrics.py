# heartsync_ble_metrics.py
# - ESP32(위 아두이노 코드)의 BLE 노티("timestamp_us,left,right\n")를 수신
# - DC 제거(이동평균) + 이동평균 평활
# - 박(foot/peak) 검출 → AUSP(AUSPR), ΔTD(PWTT), ΔRT 계산
# - HSI = |AUSPR-1|/0.05 + max(0, ΔTD-20ms)/12  → risk 등급(OK/WARN/HIGH)
# - 마커: baseline / pressure_start / pressure_end / peak_pressure / peak_release / none
# - 초단위 벽시각 포함하여 raw_stream.csv, beats_metrics.csv 저장

import asyncio, sys, csv, os, signal
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
MIN_PEAK_PROM = 30.0
PAIR_TOL_SEC = 0.10

# ==== AUSPR/HSI & Risk 규칙 ====
AUSPR_NORMAL_BAND = 0.05       # |AUSPR-1| ≤ 0.05 정상대역(문헌 근거)
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

class BeatDetector:
    """
    Peak/foot detector for PPG.
    - Keeps a rolling history buffer.
    - Detects a peak with a simple 3-point local-maximum test.
    - Searches a pre-peak window for the foot (local minimum).
    - Validates SUT range and (optionally) monotonic rise right after the foot.
    """
    def __init__(
        self,
        fs_hz: int,
        min_prom: float,
        refract_sec: float,
        *,
        hist_win_sec: float = 1.0,        # history to retain (sec)
        pre_win_sec: float = 0.5,         # search window BEFORE peak (sec)
        min_sut_ms: float = 60.0,         # lower bound for SUT validity (ms)
        max_sut_ms: float = 400.0,        # upper bound for SUT validity (ms)
        monotonic_check: bool = True,     # require early monotonic rise after foot
        monotonic_win_sec: float = 0.12,  # window after foot to check rise (sec)
        monotonic_min_posdiff: int = 2    # at least N positive diffs required
    ):
        self.fs = int(fs_hz)
        self.min_prom = float(min_prom)
        self.refract = int(refract_sec * self.fs)

        self.hist = deque(maxlen=max(3, int(hist_win_sec * self.fs)))
        self.pre_win = max(1, int(pre_win_sec * self.fs))

        self.min_sut = float(min_sut_ms)
        self.max_sut = float(max_sut_ms)

        self.monotonic_check = bool(monotonic_check)
        self.monotonic_win = max(1, int(monotonic_win_sec * self.fs))
        self.monotonic_min_posdiff = int(monotonic_min_posdiff)

        self.last_peak_idx = -10**9
        self.peaks, self.foots = [], []

    def update(self, x: float, idx: int):
        """Feed one sample (x, idx). Emits nothing immediately; call consume_beats()."""
        self.hist.append((idx, float(x)))
        if len(self.hist) < 3:
            return

        # 3-point local-maximum at the center of the last 3
        i1, y1 = self.hist[-3]
        i2, y2 = self.hist[-2]
        i3, y3 = self.hist[-1]

        if not (y2 > y1 and y2 > y3):
            return
        if (i2 - self.last_peak_idx) < self.refract:
            return
        if y2 < self.min_prom:
            return

        # Search for foot (minimum) in the pre-peak window
        lo = i2 - self.pre_win
        candid = [p for p in self.hist if lo <= p[0] < i2]
        if not candid:
            return

        foot_idx, foot_val = min(candid, key=lambda t: t[1])

        # Validate SUT (foot -> peak) in ms
        sut_ms = (i2 - foot_idx) * 1000.0 / self.fs
        if not (self.min_sut <= sut_ms <= self.max_sut):
            return

        # Optional: monotonic-rise check right after the foot
        if self.monotonic_check:
            post = [v for j, v in self.hist if foot_idx <= j <= (foot_idx + self.monotonic_win)]
            if len(post) >= 4:
                # count how many positive diffs exist
                pos_count = int(np.sum(np.diff(post) > 0))
                if pos_count < self.monotonic_min_posdiff:
                    return

        # Accept the beat
        self.foots.append((foot_idx, foot_val))
        self.peaks.append((i2, y2))
        self.last_peak_idx = i2

    def consume_beats(self):
        """Return list of dicts: {'foot_idx','foot_val','peak_idx','peak_val'} and clear internal queues."""
        n = min(len(self.foots), len(self.peaks))
        out = []
        for k in range(n):
            fi, fv = self.foots[k]
            pi, pv = self.peaks[k]
            if pi > fi:
                out.append({
                    "foot_idx": fi, "foot_val": fv,
                    "peak_idx": pi, "peak_val": pv
                })
        # clear consumed
        self.foots = self.foots[n:]
        self.peaks = self.peaks[n:]
        return out



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

async def connect_and_run():
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(RAW_CSV, "w", newline="") as f:
        csv.writer(f).writerow(["wall_time", "elapsed_s", "marker", "rawL", "rawR", "filtL", "filtR"])
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

        filtL_hist.append(yL)
        filtR_hist.append(yR)

        with open(RAW_CSV, "a", newline="") as f:
            csv.writer(f).writerow([now_wall, f"{elapsed_s:.3f}", current_marker, rawL, rawR, f"{yL:.3f}", f"{yR:.3f}"])

        # 박 검출
        detL.update(yL, idx)
        detR.update(yR, idx)
        beatsL = detL.consume_beats()
        beatsR = detR.consume_beats()

        # AUSP, RT 계산
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
