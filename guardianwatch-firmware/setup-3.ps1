# =====================================================================
#  Guardian Watch Firmware - Step 3
#  Creates components/board_support/  (pin map + I2C/SPI/GPIO init)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 3: Board Support ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/board_support/CMakeLists.txt ---
W "components\board_support\CMakeLists.txt" @'
idf_component_register(SRCS "board.c"
                       INCLUDE_DIRS "."
                       REQUIRES driver esp_driver_gpio esp_driver_i2c esp_driver_spi)
'@

Write-Host "  + components\board_support\CMakeLists.txt" -ForegroundColor Green

# --- components/board_support/board.h ---
W "components\board_support\board.h" @'
#pragma once

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_err.h"

/* ---------- I2C bus (all sensors) ---------- */
#define BOARD_I2C_PORT          0
#define BOARD_I2C_SDA           GPIO_NUM_4
#define BOARD_I2C_SCL           GPIO_NUM_5
#define BOARD_I2C_FREQ_HZ       400000

/* ---------- SPI bus (display + flash) ---------- */
#define BOARD_SPI_HOST          SPI2_HOST
#define BOARD_SPI_MOSI          GPIO_NUM_11
#define BOARD_SPI_SCK           GPIO_NUM_12
#define BOARD_SPI_MISO          GPIO_NUM_13

/* Display (GC9A01) */
#define BOARD_DISP_CS           GPIO_NUM_14
#define BOARD_DISP_DC           GPIO_NUM_15
#define BOARD_DISP_RST          GPIO_NUM_16
#define BOARD_DISP_BL           GPIO_NUM_17
#define BOARD_DISP_SPI_HZ       (40 * 1000 * 1000)

/* Flash (W25Q64JV) */
#define BOARD_FLASH_CS          GPIO_NUM_18
#define BOARD_FLASH_SPI_HZ      (20 * 1000 * 1000)

/* ---------- Sensor interrupts ---------- */
#define BOARD_MAX30101_INT      GPIO_NUM_6
#define BOARD_MAX30205_ALERT    GPIO_NUM_7
#define BOARD_LIS2DW12_INT1     GPIO_NUM_10
#define BOARD_ADS1115_ALERT     GPIO_NUM_3

/* ---------- ECG lead-off detection ---------- */
#define BOARD_AD8232_LOD_NEG    GPIO_NUM_1
#define BOARD_AD8232_LOD_POS    GPIO_NUM_2

/* ---------- Misc ---------- */
#define BOARD_BUZZER            GPIO_NUM_19
#define BOARD_BTN_POWER         GPIO_NUM_20
#define BOARD_UART_TX           GPIO_NUM_21
#define BOARD_UART_RX           GPIO_NUM_22

/* ---------- Public API ---------- */
esp_err_t board_init(void);

i2c_master_bus_handle_t board_i2c_bus(void);
spi_device_handle_t     board_display_spi(void);
spi_device_handle_t     board_flash_spi(void);
'@

Write-Host "  + components\board_support\board.h" -ForegroundColor Green

# --- components/board_support/board.c ---
W "components\board_support\board.c" @'
#include "board.h"
#include "esp_log.h"

static const char *TAG = "board";

static i2c_master_bus_handle_t s_i2c_bus = NULL;
static spi_device_handle_t     s_disp = NULL;
static spi_device_handle_t     s_flash = NULL;

static esp_err_t i2c_bus_init(void)
{
    i2c_master_bus_config_t cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = BOARD_I2C_PORT,
        .scl_io_num = BOARD_I2C_SCL,
        .sda_io_num = BOARD_I2C_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    return i2c_new_master_bus(&cfg, &s_i2c_bus);
}

static esp_err_t spi_bus_init(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = BOARD_SPI_MOSI,
        .miso_io_num = BOARD_SPI_MISO,
        .sclk_io_num = BOARD_SPI_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4096,
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(BOARD_SPI_HOST, &bus, SPI_DMA_CH_AUTO),
                        TAG, "spi_bus_initialize");

    spi_device_interface_config_t disp_cfg = {
        .clock_speed_hz = BOARD_DISP_SPI_HZ,
        .mode = 0,
        .spics_io_num = BOARD_DISP_CS,
        .queue_size = 4,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &disp_cfg, &s_disp),
                        TAG, "add display");

    spi_device_interface_config_t flash_cfg = {
        .clock_speed_hz = BOARD_FLASH_SPI_HZ,
        .mode = 0,
        .spics_io_num = BOARD_FLASH_CS,
        .queue_size = 2,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &flash_cfg, &s_flash),
                        TAG, "add flash");
    return ESP_OK;
}

static esp_err_t gpio_init(void)
{
    /* Outputs: display DC, display RST, buzzer */
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << BOARD_DISP_DC) |
                        (1ULL << BOARD_DISP_RST) |
                        (1ULL << BOARD_BUZZER),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&out), TAG, "gpio out");

    /* Inputs: sensor interrupts, ECG lead-off, power button */
    gpio_config_t in = {
        .pin_bit_mask = (1ULL << BOARD_MAX30101_INT) |
                        (1ULL << BOARD_LIS2DW12_INT1) |
                        (1ULL << BOARD_ADS1115_ALERT) |
                        (1ULL << BOARD_AD8232_LOD_NEG) |
                        (1ULL << BOARD_AD8232_LOD_POS) |
                        (1ULL << BOARD_BTN_POWER),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_NEGEDGE,
    };
    return gpio_config(&in);
}

esp_err_t board_init(void)
{
    ESP_ERROR_CHECK(gpio_init());
    ESP_ERROR_CHECK(i2c_bus_init());
    ESP_ERROR_CHECK(spi_bus_init());
    ESP_LOGI(TAG, "Board init complete");
    return ESP_OK;
}

i2c_master_bus_handle_t board_i2c_bus(void)      { return s_i2c_bus; }
spi_device_handle_t     board_display_spi(void) { return s_disp; }
spi_device_handle_t     board_flash_spi(void)   { return s_flash; }
'@

Write-Host "  + components\board_support\board.c" -ForegroundColor Green
Write-Host ""
Write-Host "=== Step 3 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\board_support\CMakeLists.txt"
Write-Host "  - components\board_support\board.h"
Write-Host "  - components\board_support\board.c"
Write-Host ""