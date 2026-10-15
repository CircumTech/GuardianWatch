#include "data_manager.h"
#include "w25q64jv.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string.h>

static const char *TAG = "datamgr";

/* Flash region reserved for the telemetry ring buffer.
 * Must match the 'telemetry' partition in partitions.csv:
 *   offset 0x330000, size 0x100000 (1 MB) */
#define FLASH_BASE_ADDR     0x330000u
#define FLASH_SIZE          0x100000u
#define FLASH_RESERVE_TAIL  256u        /* keep last page free as a marker */

/* Header written before every telemetry packet */
typedef struct __attribute__((packed)) {
    uint32_t seq;
    uint64_t ts;
    uint16_t len;   /* payload length in bytes */
    uint16_t crc;   /* CRC-16/IBM of the payload */
} record_hdr_t;

/* ------------------------------------------------------------------ */

static uint32_t s_seq         = 0;
static uint8_t  s_device_id[8] = {0};
static uint32_t s_write_addr  = FLASH_BASE_ADDR;
static uint32_t s_record_count = 0;

/* ------------------------------------------------------------------
 * CRC-16/IBM (a.k.a. ARC), polynomial 0x8005 reflected, init 0xFFFF.
 * ------------------------------------------------------------------ */
static uint16_t crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            if (crc & 1) crc = (crc >> 1) ^ 0xA001;
            else         crc >>= 1;
        }
    }
    return crc;
}

/* ------------------------------------------------------------------ */

esp_err_t data_manager_init(void)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open("gw", NVS_READWRITE, &nvs), TAG, "nvs_open");

    /* Load or generate device ID */
    size_t len = sizeof(s_device_id);
    esp_err_t err = nvs_get_blob(nvs, "device_id", s_device_id, &len);
    if (err != ESP_OK || len != sizeof(s_device_id)) {
        /* Generate a placeholder ID from the 64-bit uptime counter.
         * Production provisioning will overwrite this via the factory
         * UART handler. */
        uint64_t seed = (uint64_t)esp_timer_get_time();
        for (int i = 0; i < 8; i++) {
            s_device_id[i] = (uint8_t)(seed >> (i * 8));
        }
        nvs_set_blob(nvs, "device_id", s_device_id, sizeof(s_device_id));
        nvs_commit(nvs);
        ESP_LOGW(TAG, "Generated placeholder device ID");
    }
    nvs_close(nvs);

    s_write_addr = FLASH_BASE_ADDR;
    s_seq = 0;
    s_record_count = 0;

    ESP_LOGI(TAG, "Data manager ready");
    return ESP_OK;
}

/* ------------------------------------------------------------------
 * Sensor push stubs (see header for rationale)
 * ------------------------------------------------------------------ */

void data_manager_push_ppg(const max30101_sample_t *s)    { (void)s; }
void data_manager_push_motion(const lis2dw12_sample_t *s) { (void)s; }
void data_manager_push_temp(float t)                      { (void)t; }

/* ------------------------------------------------------------------
 * Persist a telemetry packet with a header that includes CRC
 * ------------------------------------------------------------------ */

esp_err_t data_manager_push_telemetry(const telemetry_packet_t *p)
{
    if (!p) return ESP_ERR_INVALID_ARG;

    record_hdr_t hdr = {
        .seq = p->sequence,
        .ts  = p->timestamp_ms,
        .len = (uint16_t)sizeof(*p),
        .crc = crc16((const uint8_t *)p, sizeof(*p)),
    };

    /* Write header */
    ESP_RETURN_ON_ERROR(w25q64jv_write(s_write_addr, &hdr, sizeof(hdr)),
                        TAG, "write hdr");
    s_write_addr += sizeof(hdr);

    /* Write payload */
    ESP_RETURN_ON_ERROR(w25q64jv_write(s_write_addr, p, sizeof(*p)),
                        TAG, "write payload");
    s_write_addr += sizeof(*p);

    /* Wrap when we approach the end of the region */
    if (s_write_addr >= FLASH_BASE_ADDR + FLASH_SIZE - FLASH_RESERVE_TAIL) {
        ESP_LOGI(TAG, "Ring buffer wrapped (%lu records written)",
                 (unsigned long)s_record_count);
        s_write_addr = FLASH_BASE_ADDR;
    }

    s_record_count++;
    return ESP_OK;
}

/* ------------------------------------------------------------------
 * Accessors
 * ------------------------------------------------------------------ */

uint32_t data_manager_next_sequence(void)
{
    return ++s_seq;
}

void data_manager_get_device_id(uint8_t out[8])
{
    if (out) memcpy(out, s_device_id, 8);
}