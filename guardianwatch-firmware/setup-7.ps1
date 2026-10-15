# =====================================================================
#  Guardian Watch Firmware - Step 7
#  Creates:
#    components/ad8232_ads1115/  (single-lead ECG front-end + ADC)
#  ADS1115 is on I2C address 0x49 (ADDR pin tied to VDD) to avoid
#  collision with MAX30205 at 0x48.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 7: AD8232 + ADS1115 ECG ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/ad8232_ads1115/CMakeLists.txt ---
W "components\ad8232_ads1115\CMakeLists.txt" @'
idf_component_register(SRCS "ad8232_ads1115.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

Write-Host "  + components\ad8232_ads1115\CMakeLists.txt" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.h ---
W "components\ad8232_ads1115\ad8232_ads1115.h" @'
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end — no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ±4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.h" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.c ---
W "components\ad8232_ads1115\ad8232_ads1115.c" @'
#include "ad8232_ads1115.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"

static const char *TAG = "ecg";

/* ADS1115 at 0x49 (ADDR tied to VDD) to avoid clashing with MAX30205 at 0x48 */
#define ADS1115_ADDR        0x49

/* Registers */
#define REG_CONVERSION      0x00
#define REG_CONFIG          0x01

/* Config register bit fields */
#define CFG_OS_SINGLE       0x8000   /* Start single conversion (or NOP in continuous) */
#define CFG_MUX_AIN0_GND    0x4000   /* AIN0 vs GND single-ended */
#define CFG_MUX_AIN0_AIN1   0x0000   /* AIN0 vs AIN1 differential */
#define CFG_PGA_4_096V      0x0200   /* ±4.096 V */
#define CFG_MODE_CONT       0x0000   /* Continuous conversion */
#define CFG_MODE_SINGLE     0x0100
#define CFG_DR_860SPS       0x00E0   /* 860 samples/sec */
#define CFG_COMP_DISABLE    0x0003   /* Disable comparator */

/* Full-scale voltage for the PGA setting used (±4.096 V) */
#define PGA_FULL_SCALE_MV   4096

/* AD8232 power gate.
 * In this baseline design we assume the AD8232 is always powered from
 * the 3.3 V rail, and we only track the "session active" flag here.
 * If your PCB has a load switch on the AD8232 SDN pin, drive it from
 * a GPIO here and this becomes an actual power gate. */
static bool s_powered = false;

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr16(uint8_t reg, uint16_t val)
{
    uint8_t b[3] = {reg, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF)};
    return i2c_master_transmit(s_dev, b, 3, 100);
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t ad8232_ads1115_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADS1115_ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Configure ADS1115 in continuous conversion mode:
     * - AIN0 vs GND (single-ended input from AD8232 OUT)
     * - ±4.096 V range
     * - 860 SPS
     * - Comparator disabled
     */
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    ESP_RETURN_ON_ERROR(wr16(REG_CONFIG, cfg_reg), TAG, "config");

    ESP_LOGI(TAG, "ADS1115 initialized at 0x%02X", ADS1115_ADDR);
    return ESP_OK;
}

esp_err_t ad8232_power(bool on)
{
    s_powered = on;
    ESP_LOGI(TAG, "AD8232 %s", on ? "ON" : "OFF");
    /* If your board has a load-switch on the AD8232, drive it here. */
    return ESP_OK;
}

bool ad8232_lead_off(void)
{
    /* LOD+ and LOD- are active-high when the corresponding electrode
     * is disconnected. Inputs are pulled up on the ESP32 side. */
    return gpio_get_level(BOARD_AD8232_LOD_POS) ||
           gpio_get_level(BOARD_AD8232_LOD_NEG);
}

esp_err_t ads1115_start_continuous(void)
{
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    return wr16(REG_CONFIG, cfg_reg);
}

esp_err_t ads1115_stop(void)
{
    /* Power-down single-shot config: comparator disabled, no conversion */
    return wr16(REG_CONFIG, 0x8003);
}

esp_err_t ads1115_read_sample(int16_t *millivolts)
{
    uint16_t raw = 0;
    ESP_RETURN_ON_ERROR(rd16(REG_CONVERSION, &raw), TAG, "conv");

    /* Convert raw 16-bit signed value to millivolts. */
    int32_t mv = ((int32_t)(int16_t)raw * PGA_FULL_SCALE_MV) / 32768;
    *millivolts = (int16_t)mv;
    return ESP_OK;
}
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 7 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\ad8232_ads1115\CMakeLists.txt"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.h"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.c"
Write-Host ""# =====================================================================
#  Guardian Watch Firmware - Step 7
#  Creates:
#    components/ad8232_ads1115/  (single-lead ECG front-end + ADC)
#  ADS1115 is on I2C address 0x49 (ADDR pin tied to VDD) to avoid
#  collision with MAX30205 at 0x48.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 7: AD8232 + ADS1115 ECG ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/ad8232_ads1115/CMakeLists.txt ---
W "components\ad8232_ads1115\CMakeLists.txt" @'
idf_component_register(SRCS "ad8232_ads1115.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

Write-Host "  + components\ad8232_ads1115\CMakeLists.txt" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.h ---
W "components\ad8232_ads1115\ad8232_ads1115.h" @'
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end — no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ±4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.h" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.c ---
W "components\ad8232_ads1115\ad8232_ads1115.c" @'
#include "ad8232_ads1115.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"

static const char *TAG = "ecg";

/* ADS1115 at 0x49 (ADDR tied to VDD) to avoid clashing with MAX30205 at 0x48 */
#define ADS1115_ADDR        0x49

/* Registers */
#define REG_CONVERSION      0x00
#define REG_CONFIG          0x01

/* Config register bit fields */
#define CFG_OS_SINGLE       0x8000   /* Start single conversion (or NOP in continuous) */
#define CFG_MUX_AIN0_GND    0x4000   /* AIN0 vs GND single-ended */
#define CFG_MUX_AIN0_AIN1   0x0000   /* AIN0 vs AIN1 differential */
#define CFG_PGA_4_096V      0x0200   /* ±4.096 V */
#define CFG_MODE_CONT       0x0000   /* Continuous conversion */
#define CFG_MODE_SINGLE     0x0100
#define CFG_DR_860SPS       0x00E0   /* 860 samples/sec */
#define CFG_COMP_DISABLE    0x0003   /* Disable comparator */

/* Full-scale voltage for the PGA setting used (±4.096 V) */
#define PGA_FULL_SCALE_MV   4096

/* AD8232 power gate.
 * In this baseline design we assume the AD8232 is always powered from
 * the 3.3 V rail, and we only track the "session active" flag here.
 * If your PCB has a load switch on the AD8232 SDN pin, drive it from
 * a GPIO here and this becomes an actual power gate. */
static bool s_powered = false;

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr16(uint8_t reg, uint16_t val)
{
    uint8_t b[3] = {reg, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF)};
    return i2c_master_transmit(s_dev, b, 3, 100);
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t ad8232_ads1115_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADS1115_ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Configure ADS1115 in continuous conversion mode:
     * - AIN0 vs GND (single-ended input from AD8232 OUT)
     * - ±4.096 V range
     * - 860 SPS
     * - Comparator disabled
     */
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    ESP_RETURN_ON_ERROR(wr16(REG_CONFIG, cfg_reg), TAG, "config");

    ESP_LOGI(TAG, "ADS1115 initialized at 0x%02X", ADS1115_ADDR);
    return ESP_OK;
}

esp_err_t ad8232_power(bool on)
{
    s_powered = on;
    ESP_LOGI(TAG, "AD8232 %s", on ? "ON" : "OFF");
    /* If your board has a load-switch on the AD8232, drive it here. */
    return ESP_OK;
}

bool ad8232_lead_off(void)
{
    /* LOD+ and LOD- are active-high when the corresponding electrode
     * is disconnected. Inputs are pulled up on the ESP32 side. */
    return gpio_get_level(BOARD_AD8232_LOD_POS) ||
           gpio_get_level(BOARD_AD8232_LOD_NEG);
}

esp_err_t ads1115_start_continuous(void)
{
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    return wr16(REG_CONFIG, cfg_reg);
}

esp_err_t ads1115_stop(void)
{
    /* Power-down single-shot config: comparator disabled, no conversion */
    return wr16(REG_CONFIG, 0x8003);
}

esp_err_t ads1115_read_sample(int16_t *millivolts)
{
    uint16_t raw = 0;
    ESP_RETURN_ON_ERROR(rd16(REG_CONVERSION, &raw), TAG, "conv");

    /* Convert raw 16-bit signed value to millivolts. */
    int32_t mv = ((int32_t)(int16_t)raw * PGA_FULL_SCALE_MV) / 32768;
    *millivolts = (int16_t)mv;
    return ESP_OK;
}
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 7 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\ad8232_ads1115\CMakeLists.txt"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.h"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.c"
Write-Host ""# =====================================================================
#  Guardian Watch Firmware - Step 7
#  Creates:
#    components/ad8232_ads1115/  (single-lead ECG front-end + ADC)
#  ADS1115 is on I2C address 0x49 (ADDR pin tied to VDD) to avoid
#  collision with MAX30205 at 0x48.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 7: AD8232 + ADS1115 ECG ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/ad8232_ads1115/CMakeLists.txt ---
W "components\ad8232_ads1115\CMakeLists.txt" @'
idf_component_register(SRCS "ad8232_ads1115.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

Write-Host "  + components\ad8232_ads1115\CMakeLists.txt" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.h ---
W "components\ad8232_ads1115\ad8232_ads1115.h" @'
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end — no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ±4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.h" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.c ---
W "components\ad8232_ads1115\ad8232_ads1115.c" @'
#include "ad8232_ads1115.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"

static const char *TAG = "ecg";

/* ADS1115 at 0x49 (ADDR tied to VDD) to avoid clashing with MAX30205 at 0x48 */
#define ADS1115_ADDR        0x49

/* Registers */
#define REG_CONVERSION      0x00
#define REG_CONFIG          0x01

/* Config register bit fields */
#define CFG_OS_SINGLE       0x8000   /* Start single conversion (or NOP in continuous) */
#define CFG_MUX_AIN0_GND    0x4000   /* AIN0 vs GND single-ended */
#define CFG_MUX_AIN0_AIN1   0x0000   /* AIN0 vs AIN1 differential */
#define CFG_PGA_4_096V      0x0200   /* ±4.096 V */
#define CFG_MODE_CONT       0x0000   /* Continuous conversion */
#define CFG_MODE_SINGLE     0x0100
#define CFG_DR_860SPS       0x00E0   /* 860 samples/sec */
#define CFG_COMP_DISABLE    0x0003   /* Disable comparator */

/* Full-scale voltage for the PGA setting used (±4.096 V) */
#define PGA_FULL_SCALE_MV   4096

/* AD8232 power gate.
 * In this baseline design we assume the AD8232 is always powered from
 * the 3.3 V rail, and we only track the "session active" flag here.
 * If your PCB has a load switch on the AD8232 SDN pin, drive it from
 * a GPIO here and this becomes an actual power gate. */
static bool s_powered = false;

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr16(uint8_t reg, uint16_t val)
{
    uint8_t b[3] = {reg, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF)};
    return i2c_master_transmit(s_dev, b, 3, 100);
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t ad8232_ads1115_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADS1115_ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Configure ADS1115 in continuous conversion mode:
     * - AIN0 vs GND (single-ended input from AD8232 OUT)
     * - ±4.096 V range
     * - 860 SPS
     * - Comparator disabled
     */
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    ESP_RETURN_ON_ERROR(wr16(REG_CONFIG, cfg_reg), TAG, "config");

    ESP_LOGI(TAG, "ADS1115 initialized at 0x%02X", ADS1115_ADDR);
    return ESP_OK;
}

esp_err_t ad8232_power(bool on)
{
    s_powered = on;
    ESP_LOGI(TAG, "AD8232 %s", on ? "ON" : "OFF");
    /* If your board has a load-switch on the AD8232, drive it here. */
    return ESP_OK;
}

bool ad8232_lead_off(void)
{
    /* LOD+ and LOD- are active-high when the corresponding electrode
     * is disconnected. Inputs are pulled up on the ESP32 side. */
    return gpio_get_level(BOARD_AD8232_LOD_POS) ||
           gpio_get_level(BOARD_AD8232_LOD_NEG);
}

esp_err_t ads1115_start_continuous(void)
{
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    return wr16(REG_CONFIG, cfg_reg);
}

esp_err_t ads1115_stop(void)
{
    /* Power-down single-shot config: comparator disabled, no conversion */
    return wr16(REG_CONFIG, 0x8003);
}

esp_err_t ads1115_read_sample(int16_t *millivolts)
{
    uint16_t raw = 0;
    ESP_RETURN_ON_ERROR(rd16(REG_CONVERSION, &raw), TAG, "conv");

    /* Convert raw 16-bit signed value to millivolts. */
    int32_t mv = ((int32_t)(int16_t)raw * PGA_FULL_SCALE_MV) / 32768;
    *millivolts = (int16_t)mv;
    return ESP_OK;
}
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 7 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\ad8232_ads1115\CMakeLists.txt"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.h"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.c"
Write-Host ""# =====================================================================
#  Guardian Watch Firmware - Step 7
#  Creates:
#    components/ad8232_ads1115/  (single-lead ECG front-end + ADC)
#  ADS1115 is on I2C address 0x49 (ADDR pin tied to VDD) to avoid
#  collision with MAX30205 at 0x48.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 7: AD8232 + ADS1115 ECG ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/ad8232_ads1115/CMakeLists.txt ---
W "components\ad8232_ads1115\CMakeLists.txt" @'
idf_component_register(SRCS "ad8232_ads1115.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

Write-Host "  + components\ad8232_ads1115\CMakeLists.txt" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.h ---
W "components\ad8232_ads1115\ad8232_ads1115.h" @'
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end — no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ±4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.h" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.c ---
W "components\ad8232_ads1115\ad8232_ads1115.c" @'
#include "ad8232_ads1115.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"

static const char *TAG = "ecg";

/* ADS1115 at 0x49 (ADDR tied to VDD) to avoid clashing with MAX30205 at 0x48 */
#define ADS1115_ADDR        0x49

/* Registers */
#define REG_CONVERSION      0x00
#define REG_CONFIG          0x01

/* Config register bit fields */
#define CFG_OS_SINGLE       0x8000   /* Start single conversion (or NOP in continuous) */
#define CFG_MUX_AIN0_GND    0x4000   /* AIN0 vs GND single-ended */
#define CFG_MUX_AIN0_AIN1   0x0000   /* AIN0 vs AIN1 differential */
#define CFG_PGA_4_096V      0x0200   /* ±4.096 V */
#define CFG_MODE_CONT       0x0000   /* Continuous conversion */
#define CFG_MODE_SINGLE     0x0100
#define CFG_DR_860SPS       0x00E0   /* 860 samples/sec */
#define CFG_COMP_DISABLE    0x0003   /* Disable comparator */

/* Full-scale voltage for the PGA setting used (±4.096 V) */
#define PGA_FULL_SCALE_MV   4096

/* AD8232 power gate.
 * In this baseline design we assume the AD8232 is always powered from
 * the 3.3 V rail, and we only track the "session active" flag here.
 * If your PCB has a load switch on the AD8232 SDN pin, drive it from
 * a GPIO here and this becomes an actual power gate. */
static bool s_powered = false;

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr16(uint8_t reg, uint16_t val)
{
    uint8_t b[3] = {reg, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF)};
    return i2c_master_transmit(s_dev, b, 3, 100);
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t ad8232_ads1115_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADS1115_ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Configure ADS1115 in continuous conversion mode:
     * - AIN0 vs GND (single-ended input from AD8232 OUT)
     * - ±4.096 V range
     * - 860 SPS
     * - Comparator disabled
     */
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    ESP_RETURN_ON_ERROR(wr16(REG_CONFIG, cfg_reg), TAG, "config");

    ESP_LOGI(TAG, "ADS1115 initialized at 0x%02X", ADS1115_ADDR);
    return ESP_OK;
}

esp_err_t ad8232_power(bool on)
{
    s_powered = on;
    ESP_LOGI(TAG, "AD8232 %s", on ? "ON" : "OFF");
    /* If your board has a load-switch on the AD8232, drive it here. */
    return ESP_OK;
}

bool ad8232_lead_off(void)
{
    /* LOD+ and LOD- are active-high when the corresponding electrode
     * is disconnected. Inputs are pulled up on the ESP32 side. */
    return gpio_get_level(BOARD_AD8232_LOD_POS) ||
           gpio_get_level(BOARD_AD8232_LOD_NEG);
}

esp_err_t ads1115_start_continuous(void)
{
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    return wr16(REG_CONFIG, cfg_reg);
}

esp_err_t ads1115_stop(void)
{
    /* Power-down single-shot config: comparator disabled, no conversion */
    return wr16(REG_CONFIG, 0x8003);
}

esp_err_t ads1115_read_sample(int16_t *millivolts)
{
    uint16_t raw = 0;
    ESP_RETURN_ON_ERROR(rd16(REG_CONVERSION, &raw), TAG, "conv");

    /* Convert raw 16-bit signed value to millivolts. */
    int32_t mv = ((int32_t)(int16_t)raw * PGA_FULL_SCALE_MV) / 32768;
    *millivolts = (int16_t)mv;
    return ESP_OK;
}
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 7 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\ad8232_ads1115\CMakeLists.txt"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.h"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.c"
Write-Host ""# =====================================================================
#  Guardian Watch Firmware - Step 7
#  Creates:
#    components/ad8232_ads1115/  (single-lead ECG front-end + ADC)
#  ADS1115 is on I2C address 0x49 (ADDR pin tied to VDD) to avoid
#  collision with MAX30205 at 0x48.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 7: AD8232 + ADS1115 ECG ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/ad8232_ads1115/CMakeLists.txt ---
W "components\ad8232_ads1115\CMakeLists.txt" @'
idf_component_register(SRCS "ad8232_ads1115.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)
'@

Write-Host "  + components\ad8232_ads1115\CMakeLists.txt" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.h ---
W "components\ad8232_ads1115\ad8232_ads1115.h" @'
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end — no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ±4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.h" -ForegroundColor Green

# --- components/ad8232_ads1115/ad8232_ads1115.c ---
W "components\ad8232_ads1115\ad8232_ads1115.c" @'
#include "ad8232_ads1115.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"

static const char *TAG = "ecg";

/* ADS1115 at 0x49 (ADDR tied to VDD) to avoid clashing with MAX30205 at 0x48 */
#define ADS1115_ADDR        0x49

/* Registers */
#define REG_CONVERSION      0x00
#define REG_CONFIG          0x01

/* Config register bit fields */
#define CFG_OS_SINGLE       0x8000   /* Start single conversion (or NOP in continuous) */
#define CFG_MUX_AIN0_GND    0x4000   /* AIN0 vs GND single-ended */
#define CFG_MUX_AIN0_AIN1   0x0000   /* AIN0 vs AIN1 differential */
#define CFG_PGA_4_096V      0x0200   /* ±4.096 V */
#define CFG_MODE_CONT       0x0000   /* Continuous conversion */
#define CFG_MODE_SINGLE     0x0100
#define CFG_DR_860SPS       0x00E0   /* 860 samples/sec */
#define CFG_COMP_DISABLE    0x0003   /* Disable comparator */

/* Full-scale voltage for the PGA setting used (±4.096 V) */
#define PGA_FULL_SCALE_MV   4096

/* AD8232 power gate.
 * In this baseline design we assume the AD8232 is always powered from
 * the 3.3 V rail, and we only track the "session active" flag here.
 * If your PCB has a load switch on the AD8232 SDN pin, drive it from
 * a GPIO here and this becomes an actual power gate. */
static bool s_powered = false;

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr16(uint8_t reg, uint16_t val)
{
    uint8_t b[3] = {reg, (uint8_t)(val >> 8), (uint8_t)(val & 0xFF)};
    return i2c_master_transmit(s_dev, b, 3, 100);
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t ad8232_ads1115_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADS1115_ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Configure ADS1115 in continuous conversion mode:
     * - AIN0 vs GND (single-ended input from AD8232 OUT)
     * - ±4.096 V range
     * - 860 SPS
     * - Comparator disabled
     */
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    ESP_RETURN_ON_ERROR(wr16(REG_CONFIG, cfg_reg), TAG, "config");

    ESP_LOGI(TAG, "ADS1115 initialized at 0x%02X", ADS1115_ADDR);
    return ESP_OK;
}

esp_err_t ad8232_power(bool on)
{
    s_powered = on;
    ESP_LOGI(TAG, "AD8232 %s", on ? "ON" : "OFF");
    /* If your board has a load-switch on the AD8232, drive it here. */
    return ESP_OK;
}

bool ad8232_lead_off(void)
{
    /* LOD+ and LOD- are active-high when the corresponding electrode
     * is disconnected. Inputs are pulled up on the ESP32 side. */
    return gpio_get_level(BOARD_AD8232_LOD_POS) ||
           gpio_get_level(BOARD_AD8232_LOD_NEG);
}

esp_err_t ads1115_start_continuous(void)
{
    uint16_t cfg_reg = CFG_OS_SINGLE
                     | CFG_MUX_AIN0_GND
                     | CFG_PGA_4_096V
                     | CFG_MODE_CONT
                     | CFG_DR_860SPS
                     | CFG_COMP_DISABLE;
    return wr16(REG_CONFIG, cfg_reg);
}

esp_err_t ads1115_stop(void)
{
    /* Power-down single-shot config: comparator disabled, no conversion */
    return wr16(REG_CONFIG, 0x8003);
}

esp_err_t ads1115_read_sample(int16_t *millivolts)
{
    uint16_t raw = 0;
    ESP_RETURN_ON_ERROR(rd16(REG_CONVERSION, &raw), TAG, "conv");

    /* Convert raw 16-bit signed value to millivolts. */
    int32_t mv = ((int32_t)(int16_t)raw * PGA_FULL_SCALE_MV) / 32768;
    *millivolts = (int16_t)mv;
    return ESP_OK;
}
'@

Write-Host "  + components\ad8232_ads1115\ad8232_ads1115.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 7 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\ad8232_ads1115\CMakeLists.txt"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.h"
Write-Host "  - components\ad8232_ads1115\ad8232_ads1115.c"
Write-Host ""