$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"
function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ---- Signal Quality ----
W "components\signal_quality\CMakeLists.txt" @'
idf_component_register(SRCS "signal_quality.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_timer)
'@

W "components\signal_quality\signal_quality.h" @'
#pragma once
#include <stdint.h>
#include <stdbool.h>
#define QUALITY_OK              (1u << 0)
#define QUALITY_MOTION_ARTIFACT (1u << 1)
#define QUALITY_LOW_CONTACT     (1u << 2)
#define QUALITY_LEAD_OFF        (1u << 3)
#define QUALITY_SATURATED       (1u << 4)
typedef struct { uint16_t flags; uint8_t score; float motion_rms; } quality_report_t;
void signal_quality_init(void);
quality_report_t signal_quality_evaluate_ppg(uint32_t red, uint32_t ir, float motion_rms, float temp_c);
quality_report_t signal_quality_evaluate_ecg(bool lead_off, int16_t sample, float motion_rms);
'@

W "components\signal_quality\signal_quality.c" @'
#include "signal_quality.h"
#include <math.h>
#define MOTION_THRESHOLD 0.15f
#define SATURATION_HIGH  260000
#define SATURATION_LOW   100
void signal_quality_init(void) {}
quality_report_t signal_quality_evaluate_ppg(uint32_t red, uint32_t ir, float m, float t)
{
    quality_report_t r = {0}; r.motion_rms = m; r.flags = QUALITY_OK;
    if (red > SATURATION_HIGH || ir > SATURATION_HIGH || red < SATURATION_LOW || ir < SATURATION_LOW)
        r.flags |= QUALITY_SATURATED;
    if (m > MOTION_THRESHOLD) r.flags |= QUALITY_MOTION_ARTIFACT;
    if (t > 0.0f && t < 20.0f) r.flags |= QUALITY_LOW_CONTACT;
    int s = 100;
    if (r.flags & QUALITY_MOTION_ARTIFACT) s -= 40;
    if (r.flags & QUALITY_SATURATED)       s -= 30;
    if (r.flags & QUALITY_LOW_CONTACT)     s -= 20;
    r.score = s < 0 ? 0 : (uint8_t)s;
    return r;
}
quality_report_t signal_quality_evaluate_ecg(bool lo, int16_t s, float m)
{
    (void)s;
    quality_report_t r = {0}; r.motion_rms = m; r.flags = QUALITY_OK;
    if (lo) r.flags |= QUALITY_LEAD_OFF;
    if (m > MOTION_THRESHOLD) r.flags |= QUALITY_MOTION_ARTIFACT;
    int sc = 100;
    if (r.flags & QUALITY_LEAD_OFF)        sc -= 60;
    if (r.flags & QUALITY_MOTION_ARTIFACT) sc -= 30;
    r.score = sc < 0 ? 0 : (uint8_t)sc;
    return r;
}
'@

# ---- Data Manager ----
W "components\data_manager\CMakeLists.txt" @'
idf_component_register(SRCS "data_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES w25q64jv max30101 lis2dw12 nvs_flash esp_timer)
'@

W "components\data_manager\data_manager.h" @'
#pragma once
#include <stdint.h>
#include "esp_err.h"
#include "max30101.h"
#include "lis2dw12.h"
typedef struct __attribute__((packed)) {
    uint8_t  protocol_version;
    uint8_t  device_id[8];
    uint32_t sequence;
    uint64_t timestamp_ms;
    uint16_t flags;
    uint16_t hr_bpm_x10;
    uint16_t spo2_x10;
    uint16_t temp_c_x100;
    uint16_t motion_rms_x1000;
    uint8_t  quality_score;
    uint16_t crc16;
} telemetry_packet_t;
esp_err_t data_manager_init(void);
void     data_manager_push_ppg(const max30101_sample_t *s);
void     data_manager_push_motion(const lis2dw12_sample_t *s);
void     data_manager_push_temp(float t);
esp_err_t data_manager_push_telemetry(const telemetry_packet_t *p);
uint32_t data_manager_next_sequence(void);
void     data_manager_get_device_id(uint8_t out[8]);
'@

W "components\data_manager\data_manager.c" @'
#include "data_manager.h"
#include "w25q64jv.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string.h>

static const char *TAG = "datamgr";
#define FLASH_BASE_ADDR  0x330000
#define FLASH_SIZE       0x100000

typedef struct __attribute__((packed)) {
    uint32_t seq;
    uint64_t ts;
    uint16_t len;
    uint16_t crc;
} record_hdr_t;

static uint32_t s_seq = 0;
static uint8_t  s_device_id[8] = {0};
static uint32_t s_write_addr = 0;

static uint16_t crc16(const uint8_t *d, size_t n)
{
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= d[i];
        for (int b = 0; b < 8; b++) c = (c & 1) ? ((c >> 1) ^ 0xA001) : (c >> 1);
    }
    return c;
}

esp_err_t data_manager_init(void)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open("gw", NVS_READWRITE, &nvs), TAG, "nvs");
    size_t len = sizeof(s_device_id);
    esp_err_t err = nvs_get_blob(nvs, "device_id", s_device_id, &len);
    if (err != ESP_OK || len != sizeof(s_device_id)) {
        for (int i = 0; i < 8; i++) s_device_id[i] = (uint8_t)(esp_timer_get_time() >> (i * 4));
        nvs_set_blob(nvs, "device_id", s_device_id, sizeof(s_device_id));
        nvs_commit(nvs);
    }
    nvs_close(nvs);
    s_write_addr = FLASH_BASE_ADDR;
    ESP_LOGI(TAG, "Data manager ready");
    return ESP_OK;
}

void data_manager_push_ppg(const max30101_sample_t *s)    { (void)s; }
void data_manager_push_motion(const lis2dw12_sample_t *s) { (void)s; }
void data_manager_push_temp(float t)                      { (void)t; }

esp_err_t data_manager_push_telemetry(const telemetry_packet_t *p)
{
    record_hdr_t hdr = { .seq = p->sequence, .ts = p->timestamp_ms, .len = sizeof(*p), .crc = 0 };
    hdr.crc = crc16((const uint8_t *)p, sizeof(*p));
    ESP_RETURN_ON_ERROR(w25q64jv_write(s_write_addr, &hdr, sizeof(hdr)), TAG, "hdr");
    s_write_addr += sizeof(hdr);
    ESP_RETURN_ON_ERROR(w25q64jv_write(s_write_addr, p, sizeof(*p)), TAG, "pl");
    s_write_addr += sizeof(*p);
    if (s_write_addr >= FLASH_BASE_ADDR + FLASH_SIZE - 256) s_write_addr = FLASH_BASE_ADDR;
    return ESP_OK;
}

uint32_t data_manager_next_sequence(void) { return ++s_seq; }
void data_manager_get_device_id(uint8_t out[8]) { memcpy(out, s_device_id, 8); }
'@

# ---- Signal Processing ----
W "components\signal_processing\CMakeLists.txt" @'
idf_component_register(SRCS "signal_processing.c"
                       INCLUDE_DIRS "."
                       REQUIRES signal_quality max30101 data_manager esp_timer)
'@

W "components\signal_processing\signal_processing.h" @'
#pragma once
#include <stdint.h>
#include "esp_err.h"
#include "data_manager.h"
esp_err_t signal_processing_init(void);
void      signal_processing_tick(void);
void signal_processing_push_ppg(const max30101_sample_t *s);
void signal_processing_push_motion(const lis2dw12_sample_t *s);
esp_err_t signal_processing_get_telemetry(telemetry_packet_t *out);
'@

W "components\signal_processing\signal_processing.c" @'
#include "signal_processing.h"
#include "signal_quality.h"
#include "esp_log.h"
#include "esp_timer.h"
#include <math.h>
#include <string.h>

static const char *TAG = "sigproc";
#define PPG_WIN 256
#define MOT_WIN 64

static uint32_t s_red[PPG_WIN], s_ir[PPG_WIN];
static int s_ppg_idx = 0, s_ppg_count = 0;
static float s_motion[MOT_WIN];
static int s_mot_idx = 0, s_mot_count = 0;
static float s_hr_bpm = 0.0f, s_spo2 = 0.0f, s_temp = 0.0f;
static uint8_t  s_quality_score = 0;
static uint16_t s_quality_flags = 0;

esp_err_t signal_processing_init(void)
{
    memset(s_red, 0, sizeof(s_red));
    memset(s_ir, 0, sizeof(s_ir));
    memset(s_motion, 0, sizeof(s_motion));
    ESP_LOGI(TAG, "Signal processing init");
    return ESP_OK;
}

void signal_processing_push_ppg(const max30101_sample_t *s)
{
    s_red[s_ppg_idx] = s->red;
    s_ir[s_ppg_idx] = s->ir;
    s_ppg_idx = (s_ppg_idx + 1) % PPG_WIN;
    if (s_ppg_count < PPG_WIN) s_ppg_count++;
}

void signal_processing_push_motion(const lis2dw12_sample_t *s)
{
    float mag = sqrtf(s->ax*s->ax + s->ay*s->ay + s->az*s->az) - 1.0f;
    s_motion[s_mot_idx] = mag;
    s_mot_idx = (s_mot_idx + 1) % MOT_WIN;
    if (s_mot_count < MOT_WIN) s_mot_count++;
}

static float motion_rms(void)
{
    if (s_mot_count == 0) return 0.0f;
    float sum = 0.0f;
    for (int i = 0; i < s_mot_count; i++) sum += s_motion[i] * s_motion[i];
    return sqrtf(sum / s_mot_count);
}

static float estimate_hr(void)
{
    if (s_ppg_count < PPG_WIN) return 0.0f;
    float mean = 0.0f;
    for (int i = 0; i < PPG_WIN; i++) mean += s_ir[i];
    mean /= PPG_WIN;
    int peaks = 0, first = 0, last = 0;
    for (int i = 1; i < PPG_WIN - 1; i++) {
        float p = s_ir[(i-1+PPG_WIN)%PPG_WIN] - mean;
        float c = s_ir[i] - mean;
        float n = s_ir[(i+1)%PPG_WIN] - mean;
        if (c > p && c > n && c > 0) {
            if (peaks == 0) first = i;
            last = i; peaks++;
        }
    }
    if (peaks < 2) return 0.0f;
    float dur = (last - first) / 50.0f;
    if (dur <= 0) return 0.0f;
    float hr = 60.0f * (peaks - 1) / dur;
    return (hr < 30.0f || hr > 220.0f) ? 0.0f : hr;
}

static float estimate_spo2(void)
{
    if (s_ppg_count < PPG_WIN) return 0.0f;
    float rdc = 0, idc = 0;
    for (int i = 0; i < PPG_WIN; i++) { rdc += s_red[i]; idc += s_ir[i]; }
    rdc /= PPG_WIN; idc /= PPG_WIN;
    float rac = 0, iac = 0;
    for (int i = 0; i < PPG_WIN; i++) { rac += fabsf(s_red[i]-rdc); iac += fabsf(s_ir[i]-idc); }
    rac /= PPG_WIN; iac /= PPG_WIN;
    if (rdc < 1 || idc < 1 || iac < 1) return 0.0f;
    float R = (rac/rdc) / (iac/idc);
    float spo2 = 110.0f - 25.0f * R;
    if (spo2 < 70)  spo2 = 70;
    if (spo2 > 100) spo2 = 100;
    return spo2;
}

void signal_processing_tick(void)
{
    float m = motion_rms();
    quality_report_t q = signal_quality_evaluate_ppg(s_ir[s_ppg_idx], s_red[s_ppg_idx], m, s_temp);
    s_quality_flags = q.flags;
    s_quality_score = q.score;
    s_hr_bpm = estimate_hr();
    s_spo2   = estimate_spo2();
}

esp_err_t signal_processing_get_telemetry(telemetry_packet_t *out)
{
    memset(out, 0, sizeof(*out));
    out->protocol_version = 0x01;
    data_manager_get_device_id(out->device_id);
    out->sequence = data_manager_next_sequence();
    out->timestamp_ms = (uint64_t)(esp_timer_get_time() / 1000);
    out->flags = s_quality_flags;
    out->hr_bpm_x10 = (uint16_t)(s_hr_bpm * 10.0f);
    out->spo2_x10 = (uint16_t)(s_spo2 * 10.0f);
    out->temp_c_x100 = (uint16_t)(s_temp * 100.0f);
    out->motion_rms_x1000 = (uint16_t)(motion_rms() * 1000.0f);
    out->quality_score = s_quality_score;
    return ESP_OK;
}
'@

# ---- Security ----
W "components\security_manager\CMakeLists.txt" @'
idf_component_register(SRCS "security_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES nvs_flash mbedtls esp_timer)
'@

W "components\security_manager\security_manager.h" @'
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
esp_err_t security_manager_init(void);
esp_err_t security_compute_response(const uint8_t *nonce, size_t nonce_len, uint8_t *out, size_t *out_len);
'@

W "components\security_manager\security_manager.c" @'
#include "security_manager.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "mbedtls/md.h"
#include <string.h>

static const char *TAG = "security";
static uint8_t s_secret[32];
static bool    s_provisioned = false;

esp_err_t security_manager_init(void)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open("gw", NVS_READONLY, &nvs), TAG, "nvs");
    size_t len = sizeof(s_secret);
    esp_err_t err = nvs_get_blob(nvs, "device_secret", s_secret, &len);
    nvs_close(nvs);
    if (err == ESP_OK && len == sizeof(s_secret)) {
        s_provisioned = true;
        ESP_LOGI(TAG, "Device secret loaded");
    } else {
        ESP_LOGW(TAG, "Not provisioned - using default (DEV ONLY)");
        memset(s_secret, 0xA5, sizeof(s_secret));
    }
    return ESP_OK;
}

esp_err_t security_compute_response(const uint8_t *nonce, size_t nlen, uint8_t *out, size_t *olen)
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!md) return ESP_FAIL;
    if (mbedtls_md_hmac(md, s_secret, sizeof(s_secret), nonce, nlen, out) != 0) return ESP_FAIL;
    *olen = 32;
    return ESP_OK;
}
'@

Write-Host "setup-2d done." -ForegroundColor Green