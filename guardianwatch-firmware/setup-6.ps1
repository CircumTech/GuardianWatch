# =====================================================================
#  Guardian Watch Firmware - Step 6
#  Creates:
#    components/lis2dw12/   (3-axis accelerometer driver)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 6: LIS2DW12 accelerometer ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/lis2dw12/CMakeLists.txt ---
W "components\lis2dw12\CMakeLists.txt" @'
idf_component_register(SRCS "lis2dw12.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)
'@

Write-Host "  + components\lis2dw12\CMakeLists.txt" -ForegroundColor Green

# --- components/lis2dw12/lis2dw12.h ---
W "components\lis2dw12\lis2dw12.h" @'
#pragma once

#include <stdbool.h>
#include "esp_err.h"

typedef struct {
    float ax;   /* g */
    float ay;   /* g */
    float az;   /* g */
} lis2dw12_sample_t;

esp_err_t lis2dw12_init(void);
esp_err_t lis2dw12_read(lis2dw12_sample_t *out);
esp_err_t lis2dw12_set_odr(uint8_t odr_hz);
'@

Write-Host "  + components\lis2dw12\lis2dw12.h" -ForegroundColor Green

# --- components/lis2dw12/lis2dw12.c ---
W "components\lis2dw12\lis2dw12.c" @'
#include "lis2dw12.h"
#include "board.h"
#include "esp_log.h"
#include "driver/i2c_master.h"

static const char *TAG = "lis2dw12";

/* I2C address (SA0 = GND => 0x18, SA0 = VDD => 0x19). We use 0x19. */
#define ADDR            0x19

/* Register map */
#define REG_WHO_AM_I    0x0F
#define REG_CTRL1       0x20
#define REG_CTRL2       0x21
#define REG_CTRL6       0x25
#define REG_OUT_X_L     0x28
#define REG_OUT_X_H     0x29
#define REG_OUT_Y_L     0x2A
#define REG_OUT_Y_H     0x2B
#define REG_OUT_Z_L     0x2C
#define REG_OUT_Z_H     0x2D

/* Expected WHO_AM_I value for LIS2DW12 */
#define WHOAMI_LIS2DW12 0x44

/* Sensitivity for ±2 g full scale: 0.061 mg/LSB = 0.000061 g/LSB */
#define LSENS_2G        0.000061f

/* Output data rate encodings (CTRL1 bits 7..4) for low-power mode */
#define ODR_POWERDOWN   0x00
#define ODR_12HZ5       0x20
#define ODR_25HZ        0x30
#define ODR_50HZ        0x40
#define ODR_100HZ       0x50
#define ODR_200HZ       0x60
#define ODR_400HZ       0x70
#define ODR_800HZ       0x80
#define ODR_1600HZ      0x90

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

esp_err_t lis2dw12_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    uint8_t who = 0;
    ESP_RETURN_ON_ERROR(rd(REG_WHO_AM_I, &who), TAG, "whoami");
    if (who != WHOAMI_LIS2DW12) {
        ESP_LOGE(TAG, "Unexpected WHO_AM_I 0x%02X (expected 0x%02X)",
                 who, WHOAMI_LIS2DW12);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /* CTRL1: 50 Hz ODR, high-performance mode, no low-power */
    ESP_RETURN_ON_ERROR(wr(REG_CTRL1, ODR_50HZ), TAG, "ctr1");

    /* CTRL2: Block Data Update enabled (readings consistent) */
    ESP_RETURN_ON_ERROR(wr(REG_CTRL2, 0x04), TAG, "ctr2");

    /* CTRL6: ±2 g full scale, no filtering */
    ESP_RETURN_ON_ERROR(wr(REG_CTRL6, 0x00), TAG, "ctr6");

    ESP_LOGI(TAG, "LIS2DW12 initialized (WHO_AM_I 0x%02X)", who);
    return ESP_OK;
}

esp_err_t lis2dw12_set_odr(uint8_t odr_hz)
{
    uint8_t ctrl1 = 0;
    switch (odr_hz) {
        case 12:   ctrl1 = ODR_12HZ5;   break;
        case 25:   ctrl1 = ODR_25HZ;    break;
        case 50:   ctrl1 = ODR_50HZ;    break;
        case 100:  ctrl1 = ODR_100HZ;   break;
        case 200:  ctrl1 = ODR_200HZ;   break;
        case 400:  ctrl1 = ODR_400HZ;   break;
        case 800:  ctrl1 = ODR_800HZ;   break;
        case 1600: ctrl1 = ODR_1600HZ;  break;
        default:
            ESP_LOGW(TAG, "Unsupported ODR %d Hz", odr_hz);
            return ESP_ERR_INVALID_ARG;
    }
    return wr(REG_CTRL1, ctrl1);
}

esp_err_t lis2dw12_read(lis2dw12_sample_t *out)
{
    /* Read 6 bytes starting at OUT_X_L, auto-increment */
    uint8_t buf[6] = {0};
    uint8_t reg = REG_OUT_X_L;
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, buf, 6, 100),
                        TAG, "read");

    int16_t x = (int16_t)((buf[1] << 8) | buf[0]);
    int16_t y = (int16_t)((buf[3] << 8) | buf[2]);
    int16_t z = (int16_t)((buf[5] << 8) | buf[4]);

    out->ax = x * LSENS_2G;
    out->ay = y * LSENS_2G;
    out->az = z * LSENS_2G;
    return ESP_OK;
}
'@

Write-Host "  + components\lis2dw12\lis2dw12.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 6 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\lis2dw12\CMakeLists.txt"
Write-Host "  - components\lis2dw12\lis2dw12.h"
Write-Host "  - components\lis2dw12\lis2dw12.c"
Write-Host ""