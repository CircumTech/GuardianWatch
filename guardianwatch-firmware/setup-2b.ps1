$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"
function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ---- MAX30101 ----
W "components\max30101\CMakeLists.txt" @'
idf_component_register(SRCS "max30101.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

W "components\max30101\max30101.h" @'
#pragma once
#include <stdint.h>
#include "esp_err.h"

typedef enum {
    MAX30101_MODE_HR    = 0x02,
    MAX30101_MODE_SPO2  = 0x03,
    MAX30101_MODE_MULTI = 0x07,
} max30101_mode_t;

typedef struct {
    uint32_t red;
    uint32_t ir;
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
#define ADDR 0x57
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
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev), TAG, "add");
    uint8_t part;
    ESP_RETURN_ON_ERROR(rd(REG_PART_ID, &part), TAG, "part");
    if (part != 0x15) { ESP_LOGE(TAG, "PART_ID 0x%02X", part); return ESP_ERR_INVALID_RESPONSE; }
    wr(REG_MODE_CONFIG, 0x40);
    vTaskDelay(pdMS_TO_TICKS(10));
    wr(REG_FIFO_CONFIG, 0x4F);
    wr(REG_MODE_CONFIG, MAX30101_MODE_SPO2);
    wr(REG_SPO2_CONFIG, 0x27);
    wr(REG_LED1_PA, 0x24);
    wr(REG_LED2_PA, 0x24);
    wr(REG_FIFO_WR_PTR, 0);
    wr(REG_OVF_COUNTER, 0);
    wr(REG_FIFO_RD_PTR, 0);
    ESP_LOGI(TAG, "MAX30101 initialized (PART_ID 0x%02X)", part);
    return ESP_OK;
}

esp_err_t max30101_set_mode(max30101_mode_t mode) { return wr(REG_MODE_CONFIG, (uint8_t)mode); }

esp_err_t max30101_set_led_current(uint8_t red_ma, uint8_t ir_ma)
{
    ESP_RETURN_ON_ERROR(wr(REG_LED1_PA, red_ma), TAG, "l1");
    ESP_RETURN_ON_ERROR(wr(REG_LED2_PA, ir_ma),  TAG, "l2");
    return ESP_OK;
}

esp_err_t max30101_shutdown(bool enable)
{
    return wr(REG_MODE_CONFIG, enable ? 0x80 : MAX30101_MODE_SPO2);
}

esp_err_t max30101_read_fifo(max30101_sample_t *out)
{
    uint8_t wrp, ovf, rdp;
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_WR_PTR, &wrp), TAG, "wrp");
    ESP_RETURN_ON_ERROR(rd(REG_OVF_COUNTER, &ovf), TAG, "ovf");
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_RD_PTR, &rdp), TAG, "rdp");
    if (wrp == rdp) return ESP_ERR_NOT_FOUND;
    uint8_t data[6];
    uint8_t reg = REG_FIFO_DATA;
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, data, 6, 100), TAG, "fifo");
    out->red = (((uint32_t)data[0] << 16) | ((uint32_t)data[1] << 8) | data[2]) & 0x3FFFF;
    out->ir  = (((uint32_t)data[3] << 16) | ((uint32_t)data[4] << 8) | data[5]) & 0x3FFFF;
    out->hr_valid = 0; out->spo2_valid = 0;
    wr(REG_FIFO_RD_PTR, (rdp + 1) % 32);
    return ESP_OK;
}
'@

# ---- MAX30205 ----
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
#define ADDR 0x48
#define REG_TEMP   0x00
#define REG_CONFIG 0x01
static i2c_master_dev_handle_t s_dev;
static esp_err_t wr(uint8_t r, uint8_t v) { uint8_t b[2] = {r, v}; return i2c_master_transmit(s_dev, b, 2, 100); }

esp_err_t max30205_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev), TAG, "add");
    wr(REG_CONFIG, 0x01);
    ESP_LOGI(TAG, "MAX30205 initialized");
    return ESP_OK;
}

esp_err_t max30205_read_temp(float *celsius)
{
    ESP_RETURN_ON_ERROR(wr(REG_CONFIG, 0x81), TAG, "oneshot");
    vTaskDelay(pdMS_TO_TICKS(50));
    uint8_t reg = REG_TEMP;
    uint8_t buf[2];
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, buf, 2, 100), TAG, "rd");
    int16_t raw = ((int16_t)buf[0] << 8) | buf[1];
    *celsius = raw * 0.00390625f;
    return ESP_OK;
}
'@

# ---- LIS2DW12 ----
W "components\lis2dw12\CMakeLists.txt" @'
idf_component_register(SRCS "lis2dw12.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)
'@

W "components\lis2dw12\lis2dw12.h" @'
#pragma once
#include "esp_err.h"
typedef struct { float ax, ay, az; } lis2dw12_sample_t;
esp_err_t lis2dw12_init(void);
esp_err_t lis2dw12_read(lis2dw12_sample_t *out);
'@

W "components\lis2dw12\lis2dw12.c" @'
#include "lis2dw12.h"
#include "board.h"
#include "esp_log.h"
#include "driver/i2c_master.h"

static const char *TAG = "lis2dw12";
#define ADDR 0x19
#define REG_WHO_AM_I  0x0F
#define REG_CTRL1     0x20
#define REG_CTRL2     0x21
#define REG_CTRL6     0x25
#define REG_OUT_X_L   0x28

static i2c_master_dev_handle_t s_dev;
static esp_err_t wr(uint8_t r, uint8_t v) { uint8_t b[2] = {r, v}; return i2c_master_transmit(s_dev, b, 2, 100); }
static esp_err_t rd(uint8_t r, uint8_t *v) { return i2c_master_transmit_receive(s_dev, &r, 1, v, 1, 100); }

esp_err_t lis2dw12_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev), TAG, "add");
    uint8_t who;
    ESP_RETURN_ON_ERROR(rd(REG_WHO_AM_I, &who), TAG, "who");
    if (who != 0x44) { ESP_LOGE(TAG, "WHO_AM_I 0x%02X", who); return ESP_ERR_INVALID_RESPONSE; }
    wr(REG_CTRL1, 0x40);
    wr(REG_CTRL2, 0x04);
    wr(REG_CTRL6, 0x00);
    ESP_LOGI(TAG, "LIS2DW12 initialized");
    return ESP_OK;
}

esp_err_t lis2dw12_read(lis2dw12_sample_t *out)
{
    uint8_t buf[6];
    uint8_t reg = REG_OUT_X_L;
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, buf, 6, 100), TAG, "rd");
    int16_t x = (int16_t)((buf[1] << 8) | buf[0]);
    int16_t y = (int16_t)((buf[3] << 8) | buf[2]);
    int16_t z = (int16_t)((buf[5] << 8) | buf[4]);
    const float lsb = 0.000061f;
    out->ax = x * lsb; out->ay = y * lsb; out->az = z * lsb;
    return ESP_OK;
}
'@

# ---- MAX17048 ----
W "components\max17048\CMakeLists.txt" @'
idf_component_register(SRCS "max17048.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)
'@

W "components\max17048\max17048.h" @'
#pragma once
#include "esp_err.h"
typedef struct {
    float soc_percent;
    float voltage;
    float crate;
} max17048_sample_t;
esp_err_t max17048_init(void);
esp_err_t max17048_read(max17048_sample_t *out);
'@

W "components\max17048\max17048.c" @'
#include "max17048.h"
#include "board.h"
#include "esp_log.h"
#include "driver/i2c_master.h"

static const char *TAG = "max17048";
#define ADDR 0x36
#define REG_VCELL 0x02
#define REG_SOC   0x04
#define REG_CRATE 0x16
static i2c_master_dev_handle_t s_dev;

esp_err_t max17048_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev), TAG, "add");
    ESP_LOGI(TAG, "MAX17048 initialized");
    return ESP_OK;
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2];
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100), TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t max17048_read(max17048_sample_t *out)
{
    uint16_t v, s, c;
    ESP_RETURN_ON_ERROR(rd16(REG_VCELL, &v), TAG, "v");
    ESP_RETURN_ON_ERROR(rd16(REG_SOC, &s), TAG, "s");
    ESP_RETURN_ON_ERROR(rd16(REG_CRATE, &c), TAG, "c");
    out->voltage = v * 78.125e-6f;
    out->soc_percent = s * 1.0f / 256.0f;
    out->crate = (int16_t)c * 0.208f;
    return ESP_OK;
}
'@

Write-Host "setup-2b done." -ForegroundColor Green