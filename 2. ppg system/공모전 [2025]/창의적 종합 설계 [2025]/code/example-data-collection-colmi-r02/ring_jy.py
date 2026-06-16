import argparse
import asyncio
import json
import os
import csv
from datetime import datetime

import pandas as pd
import matplotlib.pyplot as plt
from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
import requests

# ===== UUIDs (Colmi R02 계열에서 공통적으로 쓰이는 MAIN / RXTX) =====
MAIN_SERVICE_UUID = "de5bf728-d711-4e47-af26-65e3012a5dc7"
MAIN_WRITE_CHARACTERISTIC_UUID = "de5bf72a-d711-4e47-af26-65e3012a5dc7"
MAIN_NOTIFY_CHARACTERISTIC_UUID = "de5bf729-d711-4e47-af26-65e3012a5dc7"

RXTX_SERVICE_UUID = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
RXTX_WRITE_CHARACTERISTIC_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RXTX_NOTIFY_CHARACTERISTIC_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

# ===== Commands (Telink/R02 계열) =====
def create_command(hex_string: str) -> bytes:
    arr = [int(hex_string[i:i+2], 16) for i in range(0, len(hex_string), 2)]
    while len(arr) < 15:
        arr.append(0)
    checksum = sum(arr) & 0xFF
    arr.append(checksum)
    return bytes(arr)

BATTERY_CMD = create_command("03")
SET_UNITS_METRICS = create_command("0a0200")
ENABLE_RAW_SENSOR_CMD = create_command("a104")
DISABLE_RAW_SENSOR_CMD = create_command("a102")

# ===== Paths / Config =====
CONFIG_FILE = "config.json"
DATA_FOLDER = "raw_data"
INGESTION_URL = "https://ingestion.edgeimpulse.com"

os.makedirs(DATA_FOLDER, exist_ok=True)
timestamp_now = datetime.now().strftime("%Y%m%d_%H%M%S")
csv_path = os.path.join(DATA_FOLDER, f"ring_data_{timestamp_now}.csv")

# ===== CSV writer 준비 =====
CSV_HEADER = [
    "timestamp", "payload",
    "accX", "accY", "accZ",
    "ppg", "ppg_max", "ppg_min", "ppg_diff",
    "spO2", "spO2_max", "spO2_min", "spO2_diff"
]
csv_file = open(csv_path, "w", newline="")
csv_writer = csv.writer(csv_file)
csv_writer.writerow(CSV_HEADER)

# ===== 유틸 =====
def load_config():
    return json.load(open(CONFIG_FILE, "r")) if os.path.exists(CONFIG_FILE) else {}

def save_config(cfg: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)

def load_api_key():
    return load_config().get("EI_API_KEY")

def save_api_key(key: str):
    cfg = load_config()
    cfg["EI_API_KEY"] = key
    save_config(cfg)

def upload_to_edge_impulse(fullpath, label, api_key, category="training", metadata=None):
    url = f"{INGESTION_URL}/api/{category}/files"
    headers = {
        "x-label": label,
        "x-api-key": api_key,
        "x-metadata": json.dumps(metadata or {}),
    }
    with open(fullpath, "rb") as f:
        files = {"data": (os.path.basename(fullpath), f, "text/csv")}
        res = requests.post(url=url, headers=headers, files=files)
    if res.status_code == 200:
        print("Data successfully uploaded to Edge Impulse.")
    else:
        print(f"Failed to upload data: {res.status_code} - {res.text}")

def resample_data(input_file, resample_ms, columns, output_path=None):
    freq = f"{resample_ms}ms"
    df = pd.read_csv(input_file, parse_dates=["timestamp"]).set_index("timestamp")
    df_res = df[columns].resample(freq).mean().interpolate("linear").reset_index()
    if output_path:
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        df_res.to_csv(output_path, index=False)
        print("Resampled data saved to", output_path)
    return df_res

def plot_data(df, columns, src_filename, label=None):
    os.makedirs("graphs", exist_ok=True)
    base = os.path.splitext(os.path.basename(src_filename))[0]
    if label: base = f"{label}.{base}"
    for col in columns:
        plt.figure(figsize=(10, 6))
        plt.plot(df["timestamp"], df[col], label=col)
        plt.title(f"{col} over Time"); plt.xlabel("Timestamp"); plt.ylabel(col)
        plt.xticks(rotation=45); plt.legend(); plt.tight_layout()
        out = f"graphs/{base}_{col}.png"
        plt.savefig(out); plt.close()
        print("Graph saved:", out)

# ===== Telink(R02_B501) 전용 디코더 =====
def decode_telink_frame(data: bytes):
    """
    Telink 계열 R02 프레임 파서
    - data[0] == 0xA1
      subtype 0x01: SpO2
      subtype 0x02: PPG
      subtype 0x03: ACC
    길이 검사를 엄격히 하여 잘못된 패킷 무시.
    """
    if not data or data[0] != 0xA1:
        return {}

    out = {}
    subtype = data[1]

    try:
        if subtype == 0x01 and len(data) >= 10:
            # SpO2: 16bit 값 + 단일바이트 통계(펌웨어별 상이)
            out["spO2"] = (data[2] << 8) | data[3]
            out["spO2_max"] = data[5]
            out["spO2_min"] = data[7]
            out["spO2_diff"] = data[9]

        elif subtype == 0x02 and len(data) >= 10:
            # PPG: 16bit 메인 + 16bit min/max/diff
            out["ppg"] = (data[2] << 8) | data[3]
            out["ppg_max"] = (data[4] << 8) | data[5]
            out["ppg_min"] = (data[6] << 8) | data[7]
            out["ppg_diff"] = (data[8] << 8) | data[9]

        elif subtype == 0x03 and len(data) >= 8:
            # ACC: 12-bit signed (nibble packed) 추정 스키마
            def s12(hi, lo4):
                raw = ((hi & 0xFF) << 4) | (lo4 & 0x0F)
                # 12-bit signed
                if raw & 0x800:  # sign bit
                    raw = raw - 0x1000
                return raw

            # 펌웨어마다 필드 순서 다를 수 있어 보수적으로 파싱
            # (Y, Z, X) 순서로 보이는 변종도 있으니 필요하면 스왑
            accY = s12(data[2], data[3])
            accZ = s12(data[4], data[5])
            accX = s12(data[6], data[7])
            out["accX"], out["accY"], out["accZ"] = accX, accY, accZ
    except Exception:
        # 안전하게 무시
        return {}

    return out

# ===== 알림 콜백 =====
def make_csv_row(payload_hex: str, parsed: dict):
    # CSV_HEADER 순서에 맞춰 생성
    ts = datetime.now().isoformat()
    row = [
        ts, payload_hex,
        parsed.get("accX", ""), parsed.get("accY", ""), parsed.get("accZ", ""),
        parsed.get("ppg", ""), parsed.get("ppg_max", ""), parsed.get("ppg_min", ""), parsed.get("ppg_diff", ""),
        parsed.get("spO2", ""), parsed.get("spO2_max", ""), parsed.get("spO2_min", ""), parsed.get("spO2_diff", "")
    ]
    return row

async def handle_notification(_sender: int, data: bytearray):
    try:
        payload_hex = data.hex()
        parsed = decode_telink_frame(data)
        row = make_csv_row(payload_hex, parsed)
        csv_writer.writerow(row)
        # 필요시 간단 모니터링
        if parsed:
            print("CSV <= ", {k: parsed[k] for k in ("ppg","accX","accY","accZ","spO2") if k in parsed})
    except Exception as e:
        print("notify error:", e)

# ===== BLE 장치 선택 / 연결 =====
async def pick_device() -> BLEDevice | None:
    print("Scanning BLE devices...")
    devices = await BleakScanner.discover(timeout=5.0)
    # R02_* 이름 우선
    r02s = [d for d in devices if (d.name or "").startswith("R02_")]
    lst = r02s if r02s else devices
    for i, d in enumerate(lst):
        print(f"{i}: {d.name} [{d.address}] RSSI={getattr(d,'rssi',None)}")
    if not lst:
        return None
    try:
        idx = int(input("Select a device by entering its number: "))
        return lst[idx]
    except Exception:
        return None

# ===== Main =====
async def main(duration, label, columns, resample_ms, plot, ei_upload):
    device: BLEDevice | None = None

    # 이전에 저장한 주소가 있으면 우선 사용(실패 시 스캔)
    cfg = load_config()
    saved_addr = cfg.get("device_address")
    if saved_addr:
        # 주소만 저장돼 있어도, 윈도우의 RPA 문제 회피를 위해 스캔해 같은 이름 찾기
        devs = await BleakScanner.discover(timeout=4.0)
        for d in devs:
            if d.address == saved_addr or (d.name or "").startswith("R02_"):
                device = d; break

    if device is None:
        device = await pick_device()
        if device is None:
            print("No device selected. Exiting.")
            return
        cfg["device_address"] = device.address
        save_config(cfg)

    print("Connecting to:", device.name, device.address)
    # 윈도우/RPA 환경에서 성공률 향상
    async with BleakClient(device, address_type="random") as client:
        if not client.is_connected:
            print("Failed to connect.")
            return
        print("Connected!")

        # 알림 설정
        await client.start_notify(MAIN_NOTIFY_CHARACTERISTIC_UUID, handle_notification)
        await client.start_notify(RXTX_NOTIFY_CHARACTERISTIC_UUID, handle_notification)
        await asyncio.sleep(1.5)

        # 초기 명령 전송
        async def send(cmd, where="RXTX"):
            try:
                char = RXTX_WRITE_CHARACTERISTIC_UUID if where == "RXTX" \
                    else MAIN_WRITE_CHARACTERISTIC_UUID
                await client.write_gatt_char(char, cmd, response=True)
            except Exception as e:
                print(f"write({where}) error:", e)

        await send(BATTERY_CMD, "RXTX")
        await send(SET_UNITS_METRICS, "RXTX")
        await send(ENABLE_RAW_SENSOR_CMD, "RXTX")

        try:
            await asyncio.sleep(duration)
        finally:
            await send(DISABLE_RAW_SENSOR_CMD, "RXTX")
            csv_file.close()
            print("Data saved to", csv_path)

            # 후처리
            if resample_ms:
                out = os.path.join("resampled",
                                   (f"{label}." if label else "") + os.path.basename(csv_path))
                df_res = resample_data(csv_path, resample_ms, columns, output_path=out)
                if plot:
                    plot_data(df_res, columns, csv_path, label)
                if ei_upload:
                    meta = {"timestamp": timestamp_now, "source": "Colmi R02_B501 (Telink)"}
                    api_key = load_api_key() or save_api_key(input("Edge Impulse API Key: ")) or load_api_key()
                    upload_to_edge_impulse(out, label or "unlabeled", api_key, metadata=meta)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bluetooth ring data logger (Telink/R02_B501)")
    parser.add_argument("--duration", type=int, default=60)
    parser.add_argument("--label", type=str)
    parser.add_argument("--axis", type=str, help="Columns for resample/plot, comma-separated")
    parser.add_argument("--resample", type=int, default=20)
    parser.add_argument("--plot", action="store_true")
    parser.add_argument("--ei_upload", action="store_true")
    args = parser.parse_args()

    columns = args.axis.split(",") if args.axis else ["accX", "accY", "accZ", "ppg", "spO2"]
    asyncio.run(main(args.duration, args.label, columns, args.resample, args.plot, args.ei_upload))
