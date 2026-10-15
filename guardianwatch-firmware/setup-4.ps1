# =====================================================================
#  Guardian Watch Firmware - Step 4
#  Creates:
#    components/max17048/       (fuel gauge driver)
#    components/power_manager/  (battery state, low-power, shutdown)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 4: MAX17048 + Power Manager ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ============================================================
# MAX17048 fuel gauge
# ============================================================

W "components\max17048\CMakeLists.txt" @'
idf_component_register(SRCS "max17048.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)
'@

W "components\max17048\max17048.h" @'
#pragma once

#include "esp_err.h"

typedef struct {
    float soc_percent;   /* 0-100 */
    float voltage;       /* volts */
    float crate;         /* %/hr */
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
#define ADDR       0x36
#define REG_VCELL  0x02
#define REG_SOC    0x04
#define REG_CRATE  0x16

static i2c_master_dev_handle_t s_dev;

esp_err_t max17048_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add");
    ESP_LOGI(TAG, "MAX17048 initialized");
    return ESP_OK;
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2];
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t max17048_read(max17048_sample_t *out)
{
    uint16_t vcell, soc, crate;
    ESP_RETURN_ON_ERROR(rd16(REG_VCELL, &vcell), TAG, "vcell");
    ESP_RETURN_ON_ERROR(rd16(REG_SOC, &soc), TAG, "soc");
    ESP_RETURN_ON_ERROR(rd16(REG_CRATE, &crate), TAG, "crate");

    out->voltage     = vcell * 78.125e-6f;         /* 78.125 uV/LSB */
    out->soc_percent = soc * 1.0f / 256.0f;        /* 1/256 % per LSB */
    out->crate       = (int16_t)crate * 0.208f;    /* 0.208 %/hr per LSB */
    return ESP_OK;
}
'@

Write-Host "  + components\max17048\CMakeLists.txt" -ForegroundColor Green
Write-Host "  + components\max17048\max17048.h"    -ForegroundColor Green
Write-Host "  + components\max17048\max17048.c"    -ForegroundColor Green

# ============================================================
# Power Manager
# ============================================================

W "components\power_manager\CMakeLists.txt" @'
idf_component_register(SRCS "power_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support max17048 esp_driver_gpio esp_timer nvs_flash)
'@

W "components\power_manager\power_manager.h" @'
#pragma once

#include <stdbool.h>
#include "esp_err.h"
#include "max17048.h"

typedef enum {
    PWR_NORMAL = 0,
    PWR_LOW,
    PWR_CRITICAL,
    PWR_SHUTDOWN,
} power_state_t;

esp_err_t power_manager_init(void);

esp_err_t power_manager_register_button_cb(void (*cb)(void));
esp_err_t power_manager_register_low_battery_cb(void (*cb)(void));

void          power_manager_update_gauge(const max17048_sample_t *s);
power_state_t power_manager_state(void);
float         power_manager_soc(void);
void          power_manager_shutdown(void);
'@

W "components\power_manager\power_manager.c" @'
#include "power_manager.h"
#include "board.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"

static const char *TAG = "power";

static power_state_t s_state = PWR_NORMAL;
static float         s_soc = 100.0f;
static float         s_soc_smooth = 100.0f;

static void (*s_btn_cb)(void) = NULL;
static void (*s_low_cb)(void) = NULL;

static esp_timer_handle_t s_btn_timer;

/* SOC thresholds (%) */
#define SOC_LOW         20.0f
#define SOC_CRITICAL    10.0f
#define SOC_SHUTDOWN     3.0f

/* Exponential smoothing factor */
#define SOC_ALPHA        0.2f

static void btn_timer_cb(void *arg)
{
    if (gpio_get_level(BOARD_BTN_POWER) == 0 && s_btn_cb) {
        s_btn_cb();
    }
}

esp_err_t power_manager_init(void)
{
    esp_timer_create_args_t args = {
        .callback = btn_timer_cb,
        .name = "btn_long",
    };
    ESP_ERROR_CHECK(esp_timer_create(&args, &s_btn_timer));
    ESP_LOGI(TAG, "Power manager ready");
    return ESP_OK;
}

esp_err_t power_manager_register_button_cb(void (*cb)(void))
{
    s_btn_cb = cb;
    return ESP_OK;
}

esp_err_t power_manager_register_low_battery_cb(void (*cb)(void))
{
    s_low_cb = cb;
    return ESP_OK;
}

void power_manager_update_gauge(const max17048_sample_t *s)
{
    s_soc = s->soc_percent;
    s_soc_smooth = (1.0f - SOC_ALPHA) * s_soc_smooth + SOC_ALPHA * s_soc;

    power_state_t prev = s_state;
    if (s_soc_smooth <= SOC_SHUTDOWN)      s_state = PWR_SHUTDOWN;
    else if (s_soc_smooth <= SOC_CRITICAL) s_state = PWR_CRITICAL;
    else if (s_soc_smooth <= SOC_LOW)      s_state = PWR_LOW;
    else                                   s_state = PWR_NORMAL;

    if (s_state != prev) {
        ESP_LOGW(TAG, "Power state %d -> %d (SOC %.1f%%)",
                 prev, s_state, s_soc_smooth);
        if (s_state == PWR_LOW && s_low_cb) s_low_cb();
        if (s_state == PWR_SHUTDOWN)        power_manager_shutdown();
    }
}

power_state_t power_manager_state(void) { return s_state; }
float         power_manager_soc(void)   { return s_soc_smooth; }

void power_manager_shutdown(void)
{
    ESP_LOGW(TAG, "Shutting down (deep sleep)");
    /* TODO: persist any pending state before sleeping */
    esp_deep_sleep_start();
}
'@

Write-Host "  + components\power_manager\CMakeLists.txt" -ForegroundColor Green
Write-Host "  + components\power_manager\power_manager.h" -ForegroundColor Green
Write-Host "  + components\power_manager\power_manager.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 4 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\max17048\CMakeLists.txt"
Write-Host "  - components\max17048\max17048.h"
Write-Host "  - components\max17048\max17048.c"
Write-Host "  - components\power_manager\CMakeLists.txt"
Write-Host "  - components\power_manager\power_manager.h"
Write-Host "  - components\power_manager\power_manager.c"
Write-Host ""