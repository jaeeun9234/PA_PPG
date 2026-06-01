import argparse
import asyncio
import csv
import os
from datetime import datetime

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

# ==== UUIDs ====
MAIN_SERVICE_UUID = "de5bf728-d711-4e47-af26-65e3012a5dc7"
MAIN_WRITE_CHARACTERISTIC_UUID = "de5bf72a-d711-4e47-af26-65e3012a5dc7"
MAIN_NOTIFY_CHARACTERISTIC_UUID = "de5bf729-d711-4e47-af26-65e3012a5dc7"

RXTX_SERVICE_UUID = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
RXTX_WRITE_CHARACTERISTIC_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
RXTX_NOTIFY_CHARACTERISTIC_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

# ==== Commands ====
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

# ==== Parser (당신 디코더 유지) ====
def decode_telink_frame(data: bytes):
    if not data or data[0] != 0xA1:
        return {}
    out = {}
    t = data[1]
    try:
        if t == 0x01 and len(data) >= 10:  # SpO2
            out["spO2"] = (data[2] << 8) | data[3]
            out["spO2_max"] = data[5]
            out["spO2_min"] = data[7]
            out["spO2_diff"] = data[9]
        elif t == 0x02 and len(data) >= 10:  # PPG
            out["ppg"] = (data[2] << 8) | data[3]
            out["ppg_max"] = (data[4] << 8) | data[5]
            out["ppg_min"] = (data[6] << 8) | data[7]
            out["ppg_diff"] = (data[8] << 8) | data[9]
        elif t == 0x03 and len(data) >= 8:  # ACC
            def s12(hi, lo4):
                raw = ((hi & 0xFF) << 4) | (lo4 & 0x0F)
                if raw & 0x800:
                    raw -= 0x1000
                return raw
            accY = s12(data[2], data[3])
            accZ = s12(data[4], data[5])
            accX = s12(data[6], data[7])
            out["accX"], out["accY"], out["accZ"] = accX, accY, accZ
    except:
        return {}
    return out

def row_from(tag: str, payload_hex: str, parsed: dict):
    ts = datetime.now().isoformat()
    return [
        ts, tag, payload_hex,
        parsed.get("accX", ""), parsed.get("accY", ""), parsed.get("accZ", ""),
        parsed.get("ppg", ""), parsed.get("ppg_max", ""), parsed.get("ppg_min", ""), parsed.get("ppg_diff", ""),
        parsed.get("spO2", ""), parsed.get("spO2_max", ""), parsed.get("spO2_min", ""), parsed.get("spO2_diff", "")
    ]

# ==== 스캔 유틸 ====
async def find_device(mac: str|None, name_sub: str|None) -> BLEDevice|None:
    devices = await BleakScanner.discover(timeout=8.0)
    if mac:
        for d in devices:
            if d.address.lower() == mac.lower():
                return d
    cands = devices
    if name_sub:
        cands = [d for d in devices if name_sub.lower() in (d.name or "").lower()]
    if not cands and not mac:
        cands = [d for d in devices if (d.name or "").startswith("R02_")]
    # RSSI 높은 순
    cands.sort(key=lambda d: getattr(d, "rssi", -9999) or -9999, reverse=True)
    return cands[0] if cands else None

# ==== 링 하나를 관리하는 태스크 ====
async def run_ring(tag: str, mac: str|None, name_sub: str|None,
                   stop_event: asyncio.Event,
                   csv_writer: csv.writer, write_lock: asyncio.Lock):
    dev = await find_device(mac, name_sub)
    if not dev:
        print(f"[{tag}] not found (mac={mac}, name={name_sub})")
        return

    print(f"[{tag}] Connecting: {dev.name} {dev.address}")
    client = BleakClient(dev, address_type="random", timeout=10.0)

    def on_notify(_sender: int, data: bytearray):
        try:
            payload_hex = data.hex()
            parsed = decode_telink_frame(data)
            row = row_from(tag, payload_hex, parsed)
            # 공용 CSV 동시 접근 보호
            # (notify 콜백은 sync지만, asyncio.Lock을 run_in_executor 없이 직접 못 await 하므로
            #  loop.call_soon_threadsafe로 안전히 스케줄링)
            loop = asyncio.get_event_loop()
            loop.call_soon_threadsafe(write_queue.put_nowait, row)
        except Exception as e:
            print(f"[{tag}] notify error:", e)

    # notify 콜백에서 바로 파일 쓰기 대신, 큐로 모아서 순차 기록
    write_queue: asyncio.Queue = asyncio.Queue()

    async def writer_task():
        while not (stop_event.is_set() and write_queue.empty()):
            row = await write_queue.get()
            async with write_lock:
                csv_writer.writerow(row)

    writer = asyncio.create_task(writer_task())

    try:
        await client.connect()
        if not client.is_connected:
            print(f"[{tag}] connect failed")
            return
        print(f"[{tag}] Connected")

        await client.start_notify(MAIN_NOTIFY_CHARACTERISTIC_UUID, on_notify)
        await client.start_notify(RXTX_NOTIFY_CHARACTERISTIC_UUID, on_notify)
        await asyncio.sleep(1.0)

        async def send(cmd, where="RXTX"):
            try:
                char = RXTX_WRITE_CHARACTERISTIC_UUID if where == "RXTX" else MAIN_WRITE_CHARACTERISTIC_UUID
                await client.write_gatt_char(char, cmd, response=True)
            except Exception as e:
                print(f"[{tag}] write({where}) error:", e)

        await send(BATTERY_CMD, "RXTX")
        await send(SET_UNITS_METRICS, "RXTX")
        await send(ENABLE_RAW_SENSOR_CMD, "RXTX")

        # 종료 신호가 올 때까지 유지
        while not stop_event.is_set():
            await asyncio.sleep(0.1)

        await send(DISABLE_RAW_SENSOR_CMD, "RXTX")

    finally:
        try:
            await client.stop_notify(MAIN_NOTIFY_CHARACTERISTIC_UUID)
        except: pass
        try:
            await client.stop_notify(RXTX_NOTIFY_CHARACTERISTIC_UUID)
        except: pass
        if client.is_connected:
            try:
                await client.disconnect()
            except: pass

        # writer 종료
        await asyncio.sleep(0)  # 큐에 남은 거 flush 기회
        writer.cancel()
        print(f"[{tag}] closed")

# ==== 메인: 두 링 동시 + 한 CSV ====
async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=int, default=60)
    parser.add_argument("--mac1", type=str)
    parser.add_argument("--mac2", type=str)
    parser.add_argument("--name1", type=str, help="substring, e.g., 4E05")
    parser.add_argument("--name2", type=str, help="substring, e.g., B501")
    parser.add_argument("--out", type=str, default=None, help="output CSV path")
    args = parser.parse_args()

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = args.out or os.path.join("raw_data", f"rings_dual_{ts}.csv")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    # 공용 CSV
    csv_file = open(out_path, "w", newline="")
    writer = csv.writer(csv_file)
    writer.writerow([
        "timestamp","ring_id","payload",
        "accX","accY","accZ",
        "ppg","ppg_max","ppg_min","ppg_diff",
        "spO2","spO2_max","spO2_min","spO2_diff"
    ])
    write_lock = asyncio.Lock()

    stop_event = asyncio.Event()

    # 두 링 동시 태스크
    t1 = asyncio.create_task(run_ring("A", args.mac1, args.name1, stop_event, writer, write_lock))
    t2 = asyncio.create_task(run_ring("B", args.mac2, args.name2, stop_event, writer, write_lock))

    # 지정한 시간만큼 수집
    try:
        await asyncio.sleep(args.duration)
    finally:
        stop_event.set()
        await asyncio.gather(t1, t2, return_exceptions=True)
        csv_file.close()
        print("Data saved to", out_path)

if __name__ == "__main__":
    asyncio.run(main())
