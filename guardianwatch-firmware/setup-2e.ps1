$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"
function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ---- BLE CMakeLists + header ----
W "components\ble_manager\CMakeLists.txt" @'
idf_component_register(SRCS "ble_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES bt nvs_flash data_manager security_manager power_manager esp_timer)
'@

W "components\ble_manager\ble_manager.h" @'
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"
#include "data_manager.h"
typedef enum {
    BLE_EVT_CONNECTED = 0,
    BLE_EVT_DISCONNECTED,
    BLE_EVT_AUTH_OK,
    BLE_EVT_AUTH_FAIL,
} ble_event_t;
typedef void (*ble_event_cb_t)(ble_event_t evt, void *data);
esp_err_t ble_manager_init(ble_event_cb_t cb);
esp_err_t ble_manager_start_advertising(void);
esp_err_t ble_manager_stop_advertising(void);
esp_err_t ble_manager_disconnect(void);
esp_err_t ble_manager_enable_trusted_services(void);
esp_err_t ble_manager_notify_telemetry(const telemetry_packet_t *p);
esp_err_t ble_manager_notify_ppg(const uint8_t *data, size_t len);
esp_err_t ble_manager_notify_ecg(const uint8_t *data, size_t len);
esp_err_t ble_manager_notify_battery(uint8_t percent);
bool ble_manager_is_authed(void);
bool ble_manager_is_connected(void);
'@

# ---- UI ----
W "components\ui_manager\CMakeLists.txt" @'
idf_component_register(SRCS "ui_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES gc9a01 power_manager)
'@

W "components\ui_manager\ui_manager.h" @'
#pragma once
#include "esp_err.h"
esp_err_t ui_manager_init(void);
void ui_manager_show_boot(void);
void ui_manager_show_idle(void);
void ui_manager_show_connected(void);
void ui_manager_show_session(void);
void ui_manager_show_low_battery(void);
void ui_manager_show_fault(void);
void ui_manager_update(float hr, float spo2, float temp, int battery);
'@

W "components\ui_manager\ui_manager.c" @'
#include "ui_manager.h"
#include "gc9a01.h"
#include "power_manager.h"
#include "esp_log.h"
#include <stdio.h>

static const char *TAG = "ui";
#define COL_BG      0x0000
#define COL_FG      0xFFFF
#define COL_ACCENT  0x07E0
#define COL_WARN    0xF800
#define COL_DIM     0x7BEF

esp_err_t ui_manager_init(void) { ESP_LOGI(TAG, "UI init"); return ESP_OK; }

void ui_manager_show_boot(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(60, 110, "GUARDIAN", COL_FG, COL_BG); gc9a01_draw_text(70, 130, "WATCH", COL_ACCENT, COL_BG); gc9a01_set_backlight(30); }
void ui_manager_show_idle(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(90, 110, "IDLE", COL_DIM, COL_BG); gc9a01_set_backlight(20); }
void ui_manager_show_connected(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(60, 110, "CONNECTED", COL_ACCENT, COL_BG); gc9a01_set_backlight(30); }
void ui_manager_show_session(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(70, 110, "SESSION", COL_FG, COL_BG); gc9a01_set_backlight(50); }
void ui_manager_show_low_battery(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(50, 110, "LOW BATTERY", COL_WARN, COL_BG); gc9a01_set_backlight(50); }
void ui_manager_show_fault(void) { gc9a01_fill(COL_BG); gc9a01_draw_text(80, 110, "FAULT", COL_WARN, COL_BG); gc9a01_set_backlight(50); }
void ui_manager_update(float hr, float spo2, float temp, int battery)
{
    char line[32];
    gc9a01_fill(COL_BG);
    snprintf(line, sizeof(line), "HR %d", (int)hr);        gc9a01_draw_text(70, 60,  line, COL_FG, COL_BG);
    snprintf(line, sizeof(line), "SpO2 %d", (int)spo2);    gc9a01_draw_text(70, 90,  line, COL_FG, COL_BG);
    snprintf(line, sizeof(line), "T %.1fC", temp);         gc9a01_draw_text(70, 120, line, COL_FG, COL_BG);
    snprintf(line, sizeof(line), "BAT %d%%", battery);     gc9a01_draw_text(70, 150, line, COL_ACCENT, COL_BG);
}
'@

# ---- Test ----
W "test\CMakeLists.txt" @'
idf_component_register(SRCS "test_main.c"
                       INCLUDE_DIRS "."
                       REQUIRES unity board_support max30101 max30205 lis2dw12
                                max17048 gc9a01 w25q64jv signal_quality
                                signal_processing data_manager security_manager)
'@

W "test\test_main.c" @'
#include "unity.h"
#include "esp_log.h"
#include "esp_system.h"
#include "max30101.h"
#include "max30205.h"
#include "lis2dw12.h"
#include "max17048.h"
#include "gc9a01.h"
#include "w25q64jv.h"
#include "signal_quality.h"
#include "signal_processing.h"
#include "data_manager.h"
#include "security_manager.h"

static const char *TAG = "test";

TEST_CASE("max30101 init", "[max30101]") { TEST_ASSERT_EQUAL(ESP_OK, max30101_init()); }
TEST_CASE("max30205 read", "[max30205]") {
    TEST_ASSERT_EQUAL(ESP_OK, max30205_init());
    float t = 0;
    TEST_ASSERT_EQUAL(ESP_OK, max30205_read_temp(&t));
    ESP_LOGI(TAG, "Temp: %.2f C", t);
}
TEST_CASE("lis2dw12 read", "[lis2dw12]") {
    TEST_ASSERT_EQUAL(ESP_OK, lis2dw12_init());
    lis2dw12_sample_t s;
    TEST_ASSERT_EQUAL(ESP_OK, lis2dw12_read(&s));
}
TEST_CASE("max17048 read", "[max17048]") {
    TEST_ASSERT_EQUAL(ESP_OK, max17048_init());
    max17048_sample_t s;
    TEST_ASSERT_EQUAL(ESP_OK, max17048_read(&s));
    ESP_LOGI(TAG, "SOC: %.1f%%", s.soc_percent);
}
TEST_CASE("flash JEDEC", "[w25q64jv]") { TEST_ASSERT_EQUAL(ESP_OK, w25q64jv_init()); }
TEST_CASE("signal quality", "[signal_quality]") {
    signal_quality_init();
    quality_report_t q = signal_quality_evaluate_ppg(100000, 100000, 0.01f, 32.0f);
    TEST_ASSERT_EQUAL_UINT8(100, q.score);
}
TEST_CASE("security HMAC", "[security]") {
    TEST_ASSERT_EQUAL(ESP_OK, security_manager_init());
    uint8_t nonce[16] = {0}, out[32];
    size_t olen = 0;
    TEST_ASSERT_EQUAL(ESP_OK, security_compute_response(nonce, sizeof(nonce), out, &olen));
    TEST_ASSERT_EQUAL(32, olen);
}
TEST_CASE("data manager seq", "[data_manager]") {
    TEST_ASSERT_EQUAL(ESP_OK, data_manager_init());
    uint32_t s1 = data_manager_next_sequence();
    uint32_t s2 = data_manager_next_sequence();
    TEST_ASSERT_EQUAL(s1 + 1, s2);
}
TEST_CASE("signal proc telemetry", "[signal_processing]") {
    TEST_ASSERT_EQUAL(ESP_OK, signal_processing_init());
    telemetry_packet_t p;
    TEST_ASSERT_EQUAL(ESP_OK, signal_processing_get_telemetry(&p));
    TEST_ASSERT_EQUAL_UINT8(0x01, p.protocol_version);
}

void app_main(void)
{
    ESP_LOGI(TAG, "Guardian Watch test runner");
    unity_run_menu();
}
'@

# ---- Tools ----
W "tools\provision.py" @'
#!/usr/bin/env python3
import argparse, secrets, serial, struct, time
def crc16_ccitt(d):
    c = 0xFFFF
    for b in d:
        c ^= b
        for _ in range(8): c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c & 0xFFFF
def build(cmd, payload):
    h = struct.pack("<BHI", cmd, len(payload), 0)
    body = h + payload
    return body + struct.pack("<H", crc16_ccitt(body))
def send(s, cmd, payload):
    s.write(build(cmd, payload)); s.flush(); time.sleep(0.1)
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--device-id", required=True)
    a = ap.parse_args()
    did = bytes.fromhex(a.device_id)
    if len(did) != 8: raise SystemExit("device-id must be 16 hex chars")
    sec = secrets.token_bytes(32)
    with serial.Serial(a.port, a.baud, timeout=1) as s:
        send(s, 0x01, b""); time.sleep(0.5)
        send(s, 0x10, did)
        send(s, 0x11, sec)
        send(s, 0x20, b"")
        print("Device ID:", did.hex())
        print("Secret:   ", sec.hex())
if __name__ == "__main__": main()
'@

W "tools\decode_packet.py" @'
#!/usr/bin/env python3
import struct, sys
FMT = "<B8sIQHHHHHBH"
SIZE = struct.calcsize(FMT)
def crc16(d):
    c = 0xFFFF
    for b in d:
        c ^= b
        for _ in range(8): c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c & 0xFFFF
def decode(h):
    raw = bytes.fromhex(h.replace(" ","").replace(":",""))
    if len(raw) != SIZE: raise SystemExit(f"Expected {SIZE} bytes, got {len(raw)}")
    body, crc = raw[:-2], struct.unpack("<H", raw[-2:])[0]
    if crc16(body) != crc: print("WARNING: CRC mismatch")
    v, did, seq, ts, fl, hr, so, te, mo, q, _ = struct.unpack(FMT, raw)
    print(f"version     : {v}")
    print(f"device_id   : {did.hex()}")
    print(f"sequence    : {seq}")
    print(f"timestamp   : {ts} ms")
    print(f"flags       : 0x{fl:04X}")
    print(f"heart rate  : {hr/10.0:.1f} bpm")
    print(f"SpO2        : {so/10.0:.1f} %")
    print(f"temperature : {te/100.0:.2f} C")
    print(f"motion RMS  : {mo/1000.0:.4f} g")
    print(f"quality     : {q}/100")
if __name__ == "__main__":
    if len(sys.argv) != 2: raise SystemExit(f"Usage: {sys.argv[0]} <hex>")
    decode(sys.argv[1])
'@

Write-Host "setup-2e done." -ForegroundColor Green