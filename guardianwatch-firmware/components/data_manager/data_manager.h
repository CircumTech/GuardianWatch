#pragma once

#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"
#include "max30101.h"
#include "lis2dw12.h"

/* ------------------------------------------------------------------
 * Wire-format telemetry packet (little-endian on the wire).
 *
 * Layout must remain stable; the BLE characteristic and the Python
 * decoder both assume this exact structure. New fields must be added
 * at the end and gated behind protocol_version.
 * ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) {
    uint8_t  protocol_version;    /* = 0x01 */
    uint8_t  device_id[8];        /* non-secret unique device identifier */
    uint32_t sequence;            /* monotonic; wraps at 2^32 */
    uint64_t timestamp_ms;        /* device uptime in milliseconds */
    uint16_t flags;               /* OR of QUALITY_* bits */
    uint16_t hr_bpm_x10;          /* HR * 10 */
    uint16_t spo2_x10;            /* SpO2 * 10 */
    uint16_t temp_c_x100;         /* temperature * 100 */
    uint16_t motion_rms_x1000;    /* accel RMS * 1000 */
    uint8_t  quality_score;       /* 0..100 */
    uint16_t crc16;               /* CRC-16/IBM over all preceding bytes */
} telemetry_packet_t;

/* ------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------ */
esp_err_t data_manager_init(void);

/* ------------------------------------------------------------------
 * Sensor push (called from the sensor task).
 *
 * These currently act as no-ops ??? they exist so the API is stable
 * when we add a full-sample ring buffer later. The signal processing
 * task also calls them and does the real work.
 * ------------------------------------------------------------------ */
void data_manager_push_ppg(const max30101_sample_t *s);
void data_manager_push_motion(const lis2dw12_sample_t *s);
void data_manager_push_temp(float t);

/* Persist a complete telemetry packet to the SPI flash ring buffer. */
esp_err_t data_manager_push_telemetry(const telemetry_packet_t *p);

/* ------------------------------------------------------------------
 * Accessors
 * ------------------------------------------------------------------ */
uint32_t data_manager_next_sequence(void);
void     data_manager_get_device_id(uint8_t out[8]);