# =====================================================================
#  Guardian Watch Firmware - Step 5
#  Creates:
#    components/max30101/   (PPG / HR / SpO2 optical sensor)
#    components/max30205/   (digital body temperature sensor)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 5: MAX30101 + MAX30205 ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ============================================================
# MAX30101 — Pulse Oximeter / Heart Rate sensor
# ============================================================

W "components\max30101\CMakeLists.txt" @'
idf_component_register(SRCS "max30101.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

W "components\max30101\max30101.h" @'
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

typedef enum {
    MAX30101_MODE_HR     = 0x02,   /* Red LED only */
    MAX30101_MODE_SPO2   = 0x03,   /* Red + IR */
    MAX30101_MODE_MULTI  = 0x07,   /* Red + IR + Green */
} max30101_mode_t;

typedef struct {
    uint32_t red;        /* 18-bit raw Red channel */
    uint32_t ir;         /* 18-bit raw IR channel */
    uint8_t  hr_valid;
    uint8_t  spo2_valid;
} max30101_sample_t;

esp_err_t max30101_init(void);
esp_err_t max30101_set_mode(max30101_mode_t mode);
esp_err_t max30101_read_fifo(max30101_sample_t *out);
esp_err_t max30101_set_led_current(uint8_t red_ma, uint8_t ir_ma);
esp_err_t max30101_shutdown(bool enable);
'@

W "components\max30101\max30101.c" @'
#include "max30101.h"
#include "board.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"

static const char *TAG = "max30101";

/* I2C address and register map */
#define ADDR               0x57
#define REG_INT_STATUS_1   0x00
#define REG_INT_ENABLE_1   0x02
#define REG_FIFO_WR_PTR    0x04
#define REG_OVF_COUNTER    0x05
#define REG_FIFO_RD_PTR    0x06
#define REG_FIFO_DATA      0x07
#define REG_FIFO_CONFIG    0x08
#define REG_MODE_CONFIG    0x09
#define REG_SPO2_CONFIG    0x0A
#define REG_LED1_PA        0x0C
#define REG_LED2_PA        0x0D
#define REG_PART_ID        0xFF

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = {reg, val};
    return i2c_master_transmit(s_dev, b, 2, 100);
}

static esp_err_t rd(uint8_t reg, uint8_t *val)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, val, 1, 100);
}

esp_err_t max30101_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    uint8_t part = 0;
    ESP_RETURN_ON_ERROR(rd(REG_PART_ID, &part), TAG, "part_id");
    if (part != 0x15) {
        ESP_LOGE(TAG, "Unexpected PART_ID 0x%02X", part);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /* Soft reset */
    wr(REG_MODE_CONFIG, 0x40);
    vTaskDelay(pdMS_TO_TICKS(10));

    /* FIFO: 4-sample average, roll-over on, almost-full at 17 */
    wr(REG_FIFO_CONFIG, 0x4F);

    /* Mode: SpO2 (Red + IR) */
    wr(REG_MODE_CONFIG, MAX30101_MODE_SPO2);

    /* SpO2 config: 50 Hz sample rate, 411 us pulse width, 4096 nA range */
    wr(REG_SPO2_CONFIG, 0x27);

    /* LED currents ~6 mA each */
    wr(REG_LED1_PA, 0x24);
    wr(REG_LED2_PA, 0x24);

    /* Clear FIFO pointers */
    wr(REG_FIFO_WR_PTR, 0);
    wr(REG_OVF_COUNTER, 0);
    wr(REG_FIFO_RD_PTR, 0);

    ESP_LOGI(TAG, "MAX30101 initialized (PART_ID 0x%02X)", part);
    return ESP_OK;
}

esp_err_t max30101_set_mode(max30101_mode_t mode)
{
    return wr(REG_MODE_CONFIG, (uint8_t)mode);
}

esp_err_t max30101_set_led_current(uint8_t red_ma, uint8_t ir_ma)
{
    /* LED current register: ~0.2 mA per LSB */
    ESP_RETURN_ON_ERROR(wr(REG_LED1_PA, red_ma), TAG, "LED1");
    ESP_RETURN_ON_ERROR(wr(REG_LED2_PA, ir_ma),  TAG, "LED2");
    return ESP_OK;
}

esp_err_t max30101_shutdown(bool enable)
{
    return wr(REG_MODE_CONFIG, enable ? 0x80 : MAX30101_MODE_SPO2);
}

esp_err_t max30101_read_fifo(max30101_sample_t *out)
{
    uint8_t wrp = 0, ovf = 0, rdp = 0;
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_WR_PTR, &wrp), TAG, "wr_ptr");
    ESP_RETURN_ON_ERROR(rd(REG_OVF_COUNTER, &ovf), TAG, "ovf");
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_RD_PTR, &rdp), TAG, "rd_ptr");

    if (wrp == rdp) {
        return ESP_ERR_NOT_FOUND; /* FIFO empty */
    }

    /* Read 6 bytes = 3 Red + 3 IR */
    uint8_t data[6];
    uint8_t reg = REG_FIFO_DATA;
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, data, 6, 100),
                        TAG, "fifo_data");

    out->red = (((uint32_t)data[0] << 16) |
                ((uint32_t)data[1] << 8)  |
                 (uint32_t)data[2]) & 0x3FFFF;
    out->ir  = (((uint32_t)data[3] << 16) |
                ((uint32_t)data[4] << 8)  |
                 (uint32_t)data[5]) & 0x3FFFF;
    out->hr_valid   = 0;
    out->spo2_valid = 0;

    /* Advance read pointer */
    wr(REG_FIFO_RD_PTR, (rdp + 1) % 32);
    return ESP_OK;
}
'@

Write-Host "  + components\max30101\CMakeLists.txt" -ForegroundColor Green
Write-Host "  + components\max30101\max30101.h"    -ForegroundColor Green
Write-Host "  + components\max30101\max30101.c"    -ForegroundColor Green

# ============================================================
# MAX30205 — Digital body temperature sensor
# ============================================================

W "components\max30205\CMakeLists.txt" @'
idf_component_register(SRCS "max30205.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)
'@

W "components\max30205\max30205.h" @'
#pragma once

#include "esp_err.h"

esp_err_t max30205_init(void);
esp_err_t max30205_read_temp(float *celsius);
'@

W "components\max30205\max30205.c" @'
#include "max30205.h"
#include "board.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"

static const char *TAG = "max30205";

#define ADDR        0x48
#define REG_TEMP    0x00
#define REG_CONFIG  0x01

/* Config bits:
 *   bit7 = shutdown
 *   bit0 = one-shot (auto-clear, triggers single conversion)
 */
#define CFG_SHUTDOWN  (1 << 0)
#define CFG_ONESHOT   (1 << 7)

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = {reg, val};
    return i2c_master_transmit(s_dev, b, 2, 100);
}

esp_err_t max30205_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Put into shutdown mode (conversion only on demand) */
    wr(REG_CONFIG, 0x01);

    ESP_LOGI(TAG, "MAX30205 initialized");
    return ESP_OK;
}

esp_err_t max30205_read_temp(float *celsius)
{
    /* Trigger one-shot conversion (shutdown=1, oneshot=1) */
    ESP_RETURN_ON_ERROR(wr(REG_CONFIG, 0x81), TAG, "oneshot");

    /* Wait for conversion (max 50 ms per datasheet) */
    vTaskDelay(pdMS_TO_TICKS(50));

    /* Read 16-bit temperature */
    uint8_t reg = REG_TEMP;
    uint8_t buf[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, buf, 2, 100),
                        TAG, "read");

    int16_t raw = ((int16_t)buf[0] << 8) | buf[1];
    *celsius = raw * 0.00390625f; /* 1/256 °C per LSB */
    return ESP_OK;
}
'@

Write-Host "  + components\max30205\CMakeLists.txt" -ForegroundColor Green
Write-Host "  + components\max30205\max30205.h"    -ForegroundColor Green
Write-Host "  + components\max30205\max30205.c"    -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 5 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\max30101\CMakeLists.txt"
Write-Host "  - components\max30101\max30101.h"
Write-Host "  - components\max30101\max30101.c"
Write-Host "  - components\max30205\CMakeLists.txt"
Write-Host "  - components\max30205\max30205.h"
Write-Host "  - components\max30205\max30205.c"
Write-Host ""