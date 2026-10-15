$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"
function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

W "components\board_support\CMakeLists.txt" @'
idf_component_register(SRCS "board.c"
                       INCLUDE_DIRS "."
                       REQUIRES driver esp_driver_gpio esp_driver_i2c esp_driver_spi)
'@

W "components\board_support\board.h" @'
#pragma once
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_err.h"

#define BOARD_I2C_PORT          0
#define BOARD_I2C_SDA           GPIO_NUM_4
#define BOARD_I2C_SCL           GPIO_NUM_5
#define BOARD_I2C_FREQ_HZ       400000

#define BOARD_SPI_HOST          SPI2_HOST
#define BOARD_SPI_MOSI          GPIO_NUM_11
#define BOARD_SPI_SCK           GPIO_NUM_12
#define BOARD_SPI_MISO          GPIO_NUM_13

#define BOARD_DISP_CS           GPIO_NUM_14
#define BOARD_DISP_DC           GPIO_NUM_15
#define BOARD_DISP_RST          GPIO_NUM_16
#define BOARD_DISP_BL           GPIO_NUM_17
#define BOARD_DISP_SPI_HZ       (40 * 1000 * 1000)

#define BOARD_FLASH_CS          GPIO_NUM_18
#define BOARD_FLASH_SPI_HZ      (20 * 1000 * 1000)

#define BOARD_MAX30101_INT      GPIO_NUM_6
#define BOARD_MAX30205_ALERT    GPIO_NUM_7
#define BOARD_LIS2DW12_INT1     GPIO_NUM_10
#define BOARD_ADS1115_ALERT     GPIO_NUM_3

#define BOARD_AD8232_LOD_NEG    GPIO_NUM_1
#define BOARD_AD8232_LOD_POS    GPIO_NUM_2

#define BOARD_BUZZER            GPIO_NUM_19
#define BOARD_BTN_POWER         GPIO_NUM_20
#define BOARD_UART_TX           GPIO_NUM_21
#define BOARD_UART_RX           GPIO_NUM_22

esp_err_t board_init(void);
i2c_master_bus_handle_t board_i2c_bus(void);
spi_device_handle_t     board_display_spi(void);
spi_device_handle_t     board_flash_spi(void);
'@

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
    ESP_RETURN_ON_ERROR(spi_bus_initialize(BOARD_SPI_HOST, &bus, SPI_DMA_CH_AUTO), TAG, "spi");

    spi_device_interface_config_t disp_cfg = {
        .clock_speed_hz = BOARD_DISP_SPI_HZ, .mode = 0,
        .spics_io_num = BOARD_DISP_CS, .queue_size = 4,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &disp_cfg, &s_disp), TAG, "disp");

    spi_device_interface_config_t flash_cfg = {
        .clock_speed_hz = BOARD_FLASH_SPI_HZ, .mode = 0,
        .spics_io_num = BOARD_FLASH_CS, .queue_size = 2,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &flash_cfg, &s_flash), TAG, "flash");
    return ESP_OK;
}

static esp_err_t gpio_init(void)
{
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << BOARD_DISP_DC) | (1ULL << BOARD_DISP_RST) |
                        (1ULL << BOARD_BUZZER),
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&out), TAG, "out");

    gpio_config_t in = {
        .pin_bit_mask = (1ULL << BOARD_MAX30101_INT) | (1ULL << BOARD_LIS2DW12_INT1) |
                        (1ULL << BOARD_ADS1115_ALERT) | (1ULL << BOARD_AD8232_LOD_NEG) |
                        (1ULL << BOARD_AD8232_LOD_POS) | (1ULL << BOARD_BTN_POWER),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
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

typedef enum { PWR_NORMAL = 0, PWR_LOW, PWR_CRITICAL, PWR_SHUTDOWN } power_state_t;

esp_err_t power_manager_init(void);
esp_err_t power_manager_register_button_cb(void (*cb)(void));
esp_err_t power_manager_register_low_battery_cb(void (*cb)(void));
void      power_manager_update_gauge(const max17048_sample_t *s);
power_state_t power_manager_state(void);
float     power_manager_soc(void);
void      power_manager_shutdown(void);
'@

W "components\power_manager\power_manager.c" @'
#include "power_manager.h"
#include "board.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"

static const char *TAG = "power";
static power_state_t s_state = PWR_NORMAL;
static float s_soc = 100.0f, s_soc_smooth = 100.0f;
static void (*s_btn_cb)(void) = NULL;
static void (*s_low_cb)(void) = NULL;
static esp_timer_handle_t s_btn_timer;

static void btn_timer_cb(void *arg)
{
    if (gpio_get_level(BOARD_BTN_POWER) == 0 && s_btn_cb) s_btn_cb();
}

esp_err_t power_manager_init(void)
{
    esp_timer_create_args_t args = { .callback = btn_timer_cb, .name = "btn_long" };
    ESP_ERROR_CHECK(esp_timer_create(&args, &s_btn_timer));
    ESP_LOGI(TAG, "Power manager ready");
    return ESP_OK;
}

esp_err_t power_manager_register_button_cb(void (*cb)(void))      { s_btn_cb = cb; return ESP_OK; }
esp_err_t power_manager_register_low_battery_cb(void (*cb)(void)) { s_low_cb = cb; return ESP_OK; }

void power_manager_update_gauge(const max17048_sample_t *s)
{
    s_soc = s->soc_percent;
    s_soc_smooth = 0.8f * s_soc_smooth + 0.2f * s_soc;
    power_state_t prev = s_state;
    if (s_soc_smooth <= 3.0f)       s_state = PWR_SHUTDOWN;
    else if (s_soc_smooth <= 10.0f) s_state = PWR_CRITICAL;
    else if (s_soc_smooth <= 20.0f) s_state = PWR_LOW;
    else                            s_state = PWR_NORMAL;
    if (s_state != prev) {
        ESP_LOGW(TAG, "Power %d -> %d (SOC %.1f%%)", prev, s_state, s_soc_smooth);
        if (s_state == PWR_LOW && s_low_cb) s_low_cb();
        if (s_state == PWR_SHUTDOWN) power_manager_shutdown();
    }
}

power_state_t power_manager_state(void) { return s_state; }
float          power_manager_soc(void)  { return s_soc_smooth; }

void power_manager_shutdown(void)
{
    ESP_LOGW(TAG, "Shutting down");
    esp_deep_sleep_start();
}
'@

Write-Host "setup-2a done." -ForegroundColor Green