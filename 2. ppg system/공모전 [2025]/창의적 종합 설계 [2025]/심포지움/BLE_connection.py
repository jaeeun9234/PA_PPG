# BLE_connection.py
import asyncio, json, os
from bleak import BleakScanner, BleakClient

CONFIG_FILE = "config.json"
NUS_SERVICE_UUID = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"  # Nordic UART

def load_cfg():
    return json.load(open(CONFIG_FILE, encoding="utf-8")) if os.path.exists(CONFIG_FILE) else {}

def save_cfg(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

async def pick_by_uuid_or_name(timeout=8.0):
    print(f"🔍 스캔 중...({int(timeout)}s)")
    # return_adv=True로 (device, adv) 쌍을 받음
    results = await BleakScanner.discover(timeout=timeout, return_adv=True)  # dict: addr -> (device, adv)
    if not results:
        print("아무 디바이스도 발견되지 않았습니다.")
        return None

    # 1) 전부 덤프 (connectable은 버전에 따라 없음)
    print("\n--- 스캔 결과 ---")
    for addr, (dev, adv) in results.items():
        name = dev.name or ""
        rssi = getattr(adv, "rssi", None)
        uuids = getattr(adv, "service_uuids", None)
        # connectable이 없는 버전 대비
        conn = getattr(adv, "connectable", None)
        print(f"{name or '(no name)'} [{addr}]  RSSI={rssi}  connectable={conn}  uuids={uuids}")

    # 2) 우선순위 필터: NUS(UUID)가 있는 기기
    cands = []
    for addr, (dev, adv) in results.items():
        uuids = set((getattr(adv, "service_uuids", None) or []))
        if any(u.lower() == NUS_SERVICE_UUID for u in uuids):
            cands.append((dev, adv))
    # 3) 없으면 이름으로 백업 필터 (R02/Colmi 등)
    if not cands:
        for addr, (dev, adv) in results.items():
            name = (dev.name or "").lower()
            if name.startswith("r02") or "colmi" in name:
                cands.append((dev, adv))

    if not cands:
        print("\n[N/A] NUS 또는 R02/Colmi 이름으로 필터된 기기가 없습니다.")
        print(" - 제조사 앱이 연결 중이면 광고 이름/UUID가 숨겨질 수 있습니다. 제조사 앱 완전 종료/언페어 후 재시도")
        print(" - 링을 깨우기(빼서 흔들기/터치), 블루투스 켰다껐다, 스캔 시간 12~15초로 늘려 재시도")
        return None

    # 4) RSSI 최대(덜 음수) 선택
    best = max(cands, key=lambda t: (getattr(t[1], "rssi", -999) or -999))
    dev, adv = best
    print(f"\n➡ 선택: {dev.name or '(no name)'} [{dev.address}]  RSSI={getattr(adv, 'rssi', None)}")
    return dev.address

async def main():
    cfg = load_cfg()
    addr = cfg.get("device_address")
    if not addr:
        addr = await pick_by_uuid_or_name(timeout=10.0)
        if not addr:
            return
        cfg["device_address"] = addr
        save_cfg(cfg)

    # 연결 검증: 서비스/특성 나열
    async with BleakClient(addr, timeout=10) as c:
        print("\n🔗 연결 시도:", addr)
        print("connected:", c.is_connected)
        svcs = await c.get_services()
        for s in svcs:
            print("SERVICE", s.uuid)
            for ch in s.characteristics:
                print("  CHAR", ch.uuid, ch.properties)

if __name__ == "__main__":
    asyncio.run(main())
