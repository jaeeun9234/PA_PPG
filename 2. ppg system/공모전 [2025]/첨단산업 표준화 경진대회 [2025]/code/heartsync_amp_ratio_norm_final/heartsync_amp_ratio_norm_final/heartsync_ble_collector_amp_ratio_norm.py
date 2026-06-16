# -*- coding: utf-8 -*-
# HeartSync BLE Collector — FOI + ln-ratio + smoothing + RT fix (+ AmpRatio direction w/ baseline normalization)
# - Original logic retained
# - ADDED: Amp_L/Amp_R per beat; dir_amp decided by normalized ratio:
#     AmpRatio_norm = (ampR/baseR_med) / (ampL/baseL_med)
#   where base*_med are per-side median amplitudes collected during baseline marker or auto-baseline window.
# - If no explicit/auto baseline found, uses rolling median of last K beats as fallback.
# - Optional manual gains via env: GAIN_L, GAIN_R (applied to filtered samples before amp calc).
#
# CSV adds: Amp_L, Amp_R, AmpRatio, AmpNorm_L, AmpNorm_R, AmpRatio_norm, dir_amp

import asyncio, sys, csv, os, signal, time
from datetime import datetime
from collections import deque
import numpy as np
from bleak import BleakScanner, BleakClient

DEVICE_NAME  = os.getenv("HEARTSYNC_NAME", "HeartSync")
DEVICE_ADDR  = os.getenv("HEARTSYNC_ADDR", "").strip() or None

SERVICE_UUID = "5ba7a52c-c3fe-46eb-8ade-0dacbd466278"
CHAR_UUID    = "5dde726d-4cf3-4e2f-ab24-323caa359b78"

FS_HZ = 50
DT = 1.0 / FS_HZ
DC_WIN_SEC = 1.5
DC_N = max(3, int(DC_WIN_SEC * FS_HZ))
SMOOTH_N = 5

REFRACT_SEC = 0.35
MIN_PEAK_PROM = 30.0
PAIR_TOL_SEC = 0.10

FOI_ALPHA = float(os.getenv("FOI_ALPHA", "0.1"))
AUSPR_NORMAL_BAND = 0.30   # ln-band (log tolerance = ln(1+band))
HSI_TD_BASE  = 40.0
HSI_TD_SCALE = 25.0

# AUSPR stabilization
AUSPR_SMOOTH_K = 5
AUSPR_CLAMP_LOW  = 0.5
AUSPR_CLAMP_HIGH = 2.0

# physiological RT minimum (rise time foot->peak)
MIN_RT_MS = 100.0

HSI_WARN = 1.5
HSI_HIGH = 3.0

# Amplitude-Ratio bands
AMP_RATIO_BAND = float(os.getenv("AMP_RATIO_BAND", "0.30"))  # 30% band ⇒ hi=1.30, lo≈0.769

# Manual gains (optional)
GAIN_L = float(os.getenv("GAIN_L", "1.0"))
GAIN_R = float(os.getenv("GAIN_R", "1.0"))

LOG_DIR = "./heartsync_logs"
RAW_CSV = os.path.join(LOG_DIR, "raw_stream.csv")
BEAT_CSV = os.path.join(LOG_DIR, "beats_metrics.csv")

AUTO_BASELINE_SEC = int(os.getenv("AUTO_BASELINE_SEC", "8"))

current_marker = "none"
_baseline_seen = False
_start_wall = None

def wall_time_str():
    return datetime.now().isoformat(timespec="seconds")

def risk_from_hsi(hsi: float) -> str:
    if not np.isfinite(hsi): return "NA"
    if hsi >= HSI_HIGH: return "HIGH"
    if hsi >= HSI_WARN: return "WARN"
    return "OK"

class MovingAverage:
    def __init__(self, n):
        self.n = max(1, int(n)); self.buf = deque(maxlen=self.n); self.sum = 0.0
    def push(self, x: float) -> float:
        if len(self.buf) == self.n: self.sum -= self.buf[0]
        self.buf.append(x); self.sum += x
        return self.sum / len(self.buf)

def foi_area(seg, dt, alpha):
    if len(seg) < 2: return 0.0
    if alpha <= 0.0: return float(np.trapz(seg, dx=dt))
    n = len(seg)
    k = np.arange(1, n + 1, dtype=float)**(alpha - 1.0)
    k /= k.sum()
    return float(np.dot(seg, k) * n * dt)

class BeatDetector:
    """
    Peak detection with widened local window (15 samples ≈ 300 ms @50Hz).
    Foot estimated as the minimum over the first 8 samples before the mid (peak) index.
    """
    def __init__(self, fs_hz, min_prom, refract_sec):
        self.fs = fs_hz
        self.min_prom = min_prom
        self.refract = int(refract_sec * fs_hz)
        self.last_peak_idx = -99999
        self.buffer = deque(maxlen=15)  # widened window
        self.peaks, self.foots = [], []
    def update(self, x, idx):
        self.buffer.append((idx, x))
        if len(self.buffer) == self.buffer.maxlen:
            mid = self.buffer.maxlen // 2  # 7 for 15
            i_mid, y_mid = self.buffer[mid]
            _, y_prev = self.buffer[mid-1]
            _, y_next = self.buffer[mid+1]
            if y_mid > y_prev and y_mid > y_next:
                if (i_mid - self.last_peak_idx) >= self.refract and y_mid >= self.min_prom:
                    local = list(self.buffer)
                    search_end = min(8, mid)  # safety; foot in first 8 samples
                    foot_idx, foot_val = min(local[:search_end], key=lambda t: t[1])
                    self.foots.append((foot_idx, foot_val))
                    self.peaks.append((i_mid, y_mid))
                    self.last_peak_idx = i_mid
    def consume_beats(self):
        n = min(len(self.foots), len(self.peaks)); out = []
        for k in range(n):
            fi, fv = self.foots[k]; pi, pv = self.peaks[k]
            if pi > fi: out.append({"foot_idx": fi, "foot_val": fv, "peak_idx": pi, "peak_val": pv})
        self.foots, self.peaks = [], []; return out

class Pairer:
    def __init__(self, fs_hz, tol_sec):
        self.fs = fs_hz; self.tol = tol_sec; self.L, self.R = deque(), deque()
    def push_beats(self, side, beats):
        (self.L if side=='L' else self.R).extend(beats)
    def pair(self):
        out = []; 
        if not self.L or not self.R: return out
        used_R = set(); Rlist = list(self.R)
        for bl in list(self.L):
            tL = bl["peak_idx"] / self.fs; best = None; best_j = None
            for j, br in enumerate(Rlist):
                if j in used_R: continue
                tR = br["peak_idx"] / self.fs; d = abs(tL - tR)
                if d <= self.tol and (best is None or d < best):
                    best, best_j = d, j
            if best_j is not None:
                used_R.add(best_j); out.append((bl, Rlist[best_j]))
        if out:
            matchedL = {bL["peak_idx"] for bL,_ in out}
            matchedR = {bR["peak_idx"] for _,bR in out}
            self.L = deque([b for b in self.L if b["peak_idx"] not in matchedL])
            self.R = deque([b for b in self.R if b["peak_idx"] not in matchedR])
        return out

async def scan_pick_device(timeout_s=12):
    print(f"[BLE] Scanning for {timeout_s}s ...")
    devices = await BleakScanner.discover(timeout=timeout_s)
    if not devices: print("! No BLE devices found."); return None
    candidates = []
    for d in devices:
        name = d.name or ""; md = getattr(d, "metadata", {}) or {}; uuids = md.get("uuids") or []
        if (name and DEVICE_NAME.lower() in name.lower()) or (uuids and any(SERVICE_UUID.lower() == u.lower() for u in uuids)):
            candidates.append(d)
    lst = candidates if candidates else devices
    print("\n[BLE] Select device index to connect:")
    for i, d in enumerate(lst): print(f"  [{i}] addr={d.address}  name={d.name}  rssi={getattr(d, 'rssi', 'NA')}")
    if len(lst) == 1: print(f"[BLE] Auto-selecting: {lst[0].address} ({lst[0].name})"); return lst[0]
    try:
        sel = int(input("Enter index: ").strip())
        if 0 <= sel < len(lst): return lst[sel]
    except Exception as e:
        print("! Invalid selection.", e)
    return None

async def read_markers():
    global current_marker, _baseline_seen, _start_wall
    print("[Marker] b=baseline, s=start, p=peak, u=release, e=end, n=none")
    _start_wall = time.time()
    if os.name == "nt":
        try:
            import msvcrt
            while True:
                if msvcrt.kbhit():
                    ch = msvcrt.getwch().lower()
                    mapping = {"b":"baseline","s":"pressure_start","p":"peak_pressure","u":"peak_release","e":"pressure_end","n":"none"}
                    if ch in mapping:
                        current_marker = mapping[ch]
                        if ch == "b": _baseline_seen = True
                        print(f"[Marker] -> {current_marker}")
                await asyncio.sleep(0.02)
        except Exception as e:
            print("[Marker] msvcrt failed, falling back to stdin:", e)
    loop = asyncio.get_event_loop()
    def blocking_input():
        try: return sys.stdin.readline()
        except: return None
    while True:
        line = await loop.run_in_executor(None, blocking_input)
        if not line:
            await asyncio.sleep(0.05); continue
        line = line.strip().lower()
        mapping = {"b":"baseline","s":"pressure_start","p":"peak_pressure","u":"peak_release","e":"pressure_end","n":"none"}
        if line in mapping:
            current_marker = mapping[line]
            if line == "b": _baseline_seen = True
            print(f"[Marker] -> {current_marker}")

async def connect_and_run():
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(RAW_CSV, "w", newline="") as f:
        csv.writer(f).writerow(["wall_time","elapsed_s","marker","rawL","rawR","filtL","filtR","baseLenL","baseLenR","autoBase"])
    with open(BEAT_CSV, "w", newline="") as f:
        csv.writer(f).writerow([
            "wall_time","elapsed_s","marker","beat_id",
            "footL_idx","peakL_idx","footR_idx","peakR_idx",
            "RT_L_ms","RT_R_ms","DeltaRT_ms",
            "AUSP_L","AUSP_R","AUSPR",
            "DeltaTD_ms","HSI","risk",
            "baseL","baseR","alpha_used","auto_baseline_active",
            # NEW (Amp-ratio, normalized)
            "Amp_L","Amp_R","AmpRatio","AmpNorm_L","AmpNorm_R","AmpRatio_norm","dir_amp"
        ])

    dev = None
    if DEVICE_ADDR:
        print(f"[BLE] Finding device by address: {DEVICE_ADDR} ...")
        dev = await BleakScanner.find_device_by_address(DEVICE_ADDR, timeout=10.0)
        if not dev: print("! Address not found; falling back to scan/select.")
    if not dev:
        print(f"[BLE] Scanning for device (name contains '{DEVICE_NAME}' or service UUID match)...")
        dev = await scan_pick_device(timeout_s=12)
    if not dev:
        print("! Device not found. Make sure it is advertising (and not already connected)."); return

    start_mono = asyncio.get_event_loop().time()
    dcL, dcR = MovingAverage(DC_N), MovingAverage(DC_N)
    smoothL, smoothR = MovingAverage(SMOOTH_N), MovingAverage(SMOOTH_N)
    idx = 0
    detL = BeatDetector(FS_HZ, MIN_PEAK_PROM, REFRACT_SEC)
    detR = BeatDetector(FS_HZ, MIN_PEAK_PROM, REFRACT_SEC)
    pairer = Pairer(FS_HZ, PAIR_TOL_SEC)
    filtL_hist, filtR_hist = [], []
    base_buf_L, base_buf_R = [], []
    auspr_hist = deque(maxlen=AUSPR_SMOOTH_K)

    # NEW: per-side baseline amplitude (from early beats)
    base_amp_L_hist = deque(maxlen=64)
    base_amp_R_hist = deque(maxlen=64)
    base_amp_L_med = None
    base_amp_R_med = None

    # Fallback rolling window of last K beats (if no baseline)
    ROLL_K = 20
    roll_amp_L = deque(maxlen=ROLL_K)
    roll_amp_R = deque(maxlen=ROLL_K)

    def base_amp(arr, recent_hist):
        if arr:
            return float(np.mean(np.clip(np.array(arr, dtype=float), 0, None)) + 1e-6)
        if recent_hist:
            N = min(len(recent_hist), FS_HZ * 2)
            seg = np.array(recent_hist[-N:], dtype=float)
            val = float(np.mean(np.clip(seg, 0, None)) + 1e-6)
            return val if np.isfinite(val) and val > 0 else 1.0
        return 1.0

    beat_counter = 0

    def parse_and_process(data: bytearray):
        nonlocal idx, beat_counter, filtL_hist, filtR_hist, base_buf_L, base_buf_R
        nonlocal base_amp_L_med, base_amp_R_med

        try:
            _, rawL_str, rawR_str = data.decode("utf-8").strip().split(",")
            rawL, rawR = int(rawL_str), int(rawR_str)
        except Exception:
            return

        now_wall = wall_time_str()
        elapsed_s = asyncio.get_event_loop().time() - start_mono

        # DC & smoothing
        xL = rawL - dcL.push(rawL); xR = rawR - dcR.push(rawR)
        yL = smoothL.push(xL) * GAIN_L;     yR = smoothR.push(xR) * GAIN_R  # apply manual gains here if set

        auto_baseline_active = (not _baseline_seen) and (_start_wall is not None) and ((time.time() - _start_wall) <= AUTO_BASELINE_SEC)
        if current_marker == "baseline" or auto_baseline_active:
            base_buf_L.append(yL); base_buf_R.append(yR)
            if len(base_buf_L) > FS_HZ * 10:
                base_buf_L = base_buf_L[-FS_HZ*10:]; base_buf_R = base_buf_R[-FS_HZ*10:]

        filtL_hist.append(yL); filtR_hist.append(yR)

        with open(RAW_CSV, "a", newline="") as f:
            csv.writer(f).writerow([now_wall, f"{elapsed_s:.3f}", current_marker,
                                    rawL, rawR, f"{yL:.3f}", f"{yR:.3f}",
                                    len(base_buf_L), len(base_buf_R), int(auto_baseline_active)])

        detL.update(yL, idx); detR.update(yR, idx)
        beatsL = detL.consume_beats(); beatsR = detR.consume_beats()

        bL_amp = max(base_amp(base_buf_L, filtL_hist), 1e-3)
        bR_amp = max(base_amp(base_buf_R, filtR_hist), 1e-3)

        for b in beatsL:
            fi, pi = b["foot_idx"], b["peak_idx"]
            if 0 <= fi < pi <= len(filtL_hist)-1:
                seg = np.array(filtL_hist[fi:pi+1], float)
                seg = np.clip(seg, 0, None) / bL_amp
                b["AUSP"] = foi_area(seg, DT, FOI_ALPHA)
                b["RT_ms"] = (pi - fi) * 1000.0 * DT
            else:
                b["AUSP"] = 0.0; b["RT_ms"] = np.nan
        for b in beatsR:
            fi, pi = b["foot_idx"], b["peak_idx"]
            if 0 <= fi < pi <= len(filtR_hist)-1:
                seg = np.array(filtR_hist[fi:pi+1], float)
                seg = np.clip(seg, 0, None) / bR_amp
                b["AUSP"] = foi_area(seg, DT, FOI_ALPHA)
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
                    # Enforce physiological RT minimum
                    rtL = bL.get("RT_ms", np.nan); rtR = bR.get("RT_ms", np.nan)
                    min_rt = min(rtL if np.isfinite(rtL) else 1e9, rtR if np.isfinite(rtR) else 1e9)
                    if np.isfinite(min_rt) and min_rt < MIN_RT_MS:
                        continue

                    nonlocal beat_counter
                    beat_counter += 1

                    dt_ms  = abs(bL["peak_idx"] - bR["peak_idx"]) * 1000.0 * DT
                    drt_ms = abs(rtL - rtR) if (np.isfinite(rtL) and np.isfinite(rtR)) else np.nan
                    auspr_raw = (bR["AUSP"] / bL["AUSP"]) if bL["AUSP"] > 1e-9 else np.nan

                    # AUSPR stabilization (unchanged)
                    if np.isfinite(auspr_raw):
                        auspr_hist.append(auspr_raw)
                        med = float(np.median(auspr_hist))
                        auspr = min(max(med, AUSPR_CLAMP_LOW), AUSPR_CLAMP_HIGH)
                    else:
                        auspr = 1.0

                    tol   = np.log(1.0 + AUSPR_NORMAL_BAND)
                    term1 = abs(np.log(max(auspr,1e-6))) / tol
                    term2 = max(0.0, dt_ms - HSI_TD_BASE) / HSI_TD_SCALE
                    hsi   = term1 + term2
                    risk  = risk_from_hsi(hsi)

                    # === Amplitude calc on filtered (with optional gains) ===
                    def seg_amp(hist, fi, pi):
                        if 0 <= fi < pi <= len(hist)-1:
                            s = np.array(hist[fi:pi+1], float)
                            return float(s.max() - s.min())
                        return np.nan
                    ampL = seg_amp(filtL_hist, bL["foot_idx"], bL["peak_idx"])
                    ampR = seg_amp(filtR_hist, bR["foot_idx"], bR["peak_idx"])

                    # Collect baseline amplitudes during baseline/auto-baseline
                    if (current_marker == "baseline") or auto_baseline_active:
                        if np.isfinite(ampL) and ampL>0: base_amp_L_hist.append(ampL)
                        if np.isfinite(ampR) and ampR>0: base_amp_R_hist.append(ampR)
                        if len(base_amp_L_hist) >= 8: base_amp_L_med = float(np.median(base_amp_L_hist))
                        if len(base_amp_R_hist) >= 8: base_amp_R_med = float(np.median(base_amp_R_hist))

                    # Fallback rolling medians if baseline not available yet
                    if np.isfinite(ampL) and ampL>0: roll_amp_L.append(ampL)
                    if np.isfinite(ampR) and ampR>0: roll_amp_R.append(ampR)
                    rollL_med = float(np.median(roll_amp_L)) if len(roll_amp_L)>=6 else np.nan
                    rollR_med = float(np.median(roll_amp_R)) if len(roll_amp_R)>=6 else np.nan

                    # Normalize
                    denomL = base_amp_L_med if (base_amp_L_med and base_amp_L_med>0) else (rollL_med if (rollL_med and rollL_med>0) else np.nan)
                    denomR = base_amp_R_med if (base_amp_R_med and base_amp_R_med>0) else (rollR_med if (rollR_med and rollR_med>0) else np.nan)
                    ampNormL = (ampL/denomL) if (np.isfinite(ampL) and np.isfinite(denomL) and denomL>0) else np.nan
                    ampNormR = (ampR/denomR) if (np.isfinite(ampR) and np.isfinite(denomR) and denomR>0) else np.nan
                    amp_ratio_raw = (ampR/ampL) if (np.isfinite(ampR) and np.isfinite(ampL) and ampL>1e-9) else np.nan
                    amp_ratio_norm = (ampNormR/ampNormL) if (np.isfinite(ampNormR) and np.isfinite(ampNormL) and ampNormL>1e-9) else np.nan

                    band_hi = 1.0 + AMP_RATIO_BAND
                    band_lo = 1.0 / band_hi

                    # Prefer normalized ratio when available; fall back to raw ratio
                    ratio_used = amp_ratio_norm if np.isfinite(amp_ratio_norm) else amp_ratio_raw
                    dir_amp = "BAL"
                    if np.isfinite(ratio_used):
                        if ratio_used < band_lo:
                            dir_amp = "R↓"
                        elif ratio_used > band_hi:
                            dir_amp = "L↓"

                    # Console log
                    ampL_str = f"{ampL:.3f}" if np.isfinite(ampL) else "nan"
                    ampR_str = f"{ampR:.3f}" if np.isfinite(ampR) else "nan"
                    rraw_str = f"{amp_ratio_raw:.3f}" if np.isfinite(amp_ratio_raw) else "nan"
                    nL_str = f"{ampNormL:.3f}" if np.isfinite(ampNormL) else "nan"
                    nR_str = f"{ampNormR:.3f}" if np.isfinite(ampNormR) else "nan"
                    rnorm_str = f"{amp_ratio_norm:.3f}" if np.isfinite(amp_ratio_norm) else "nan"
                    print(f"[{risk}] beat#{beat_counter} HSI={hsi:.2f} AUSPR={auspr:.3f} ΔTD={dt_ms:.1f}ms | "
                          f"Amp[L,R]=({ampL_str},{ampR_str}) Ratio_raw={rraw_str} | "
                          f"Norm[L,R]=({nL_str},{nR_str}) Ratio_norm={rnorm_str} -> dir_amp={dir_amp} marker={current_marker}")

                    w.writerow([
                        wall_time_str(), f"{elapsed_s:.3f}", current_marker,
                        beat_counter,
                        bL["foot_idx"], bL["peak_idx"], bR["foot_idx"], bR["peak_idx"],
                        f"{rtL:.1f}", f"{rtR:.1f}", f"{drt_ms:.1f}" if np.isfinite(drt_ms) else "",
                        f"{bL['AUSP']:.6f}", f"{bR['AUSP']:.6f}",
                        f"{auspr:.6f}",
                        f"{dt_ms:.1f}", f"{hsi:.3f}", risk,
                        f"{bL_amp:.4f}", f"{bR_amp:.4f}", f"{FOI_ALPHA:.2f}", int(auto_baseline_active),
                        # Amp fields
                        f"{ampL:.6f}" if np.isfinite(ampL) else "",
                        f"{ampR:.6f}" if np.isfinite(ampR) else "",
                        f"{amp_ratio_raw:.6f}" if np.isfinite(amp_ratio_raw) else "",
                        f"{ampNormL:.6f}" if np.isfinite(ampNormL) else "",
                        f"{ampNormR:.6f}" if np.isfinite(ampNormR) else "",
                        f"{amp_ratio_norm:.6f}" if np.isfinite(amp_ratio_norm) else "",
                        dir_amp
                    ])

        idx += 1

    async def run(client):
        if not client.is_connected: print("! Failed to connect"); return
        print(f"[BLE] Connected: {client.address if hasattr(client,'address') else 'OK'}")
        global _start_wall; _start_wall = time.time()
        await client.start_notify(CHAR_UUID, lambda _, data: parse_and_process(data))
        print(f"[BLE] Notifications started. FOI α={FOI_ALPHA}  (Ctrl+C to stop)")
        stop_event = asyncio.Event()
        def handle_sig(*_): stop_event.set()
        for s in (signal.SIGINT, signal.SIGTERM):
            try: asyncio.get_event_loop().add_signal_handler(s, handle_sig)
            except NotImplementedError: pass
        await stop_event.wait()
        await client.stop_notify(CHAR_UUID)
        print("[BLE] Stopped.")

    dev = None
    if DEVICE_ADDR:
        dev = await BleakScanner.find_device_by_address(DEVICE_ADDR, timeout=10.0)
    if not dev:
        dev = await scan_pick_device(timeout_s=12)
    if not dev: print("! Device not found."); return

    async with BleakClient(dev) as client:
        await run(client)

async def main():
    await asyncio.gather(connect_and_run(), read_markers())

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
