# =====================================================================
#  Guardian Watch Firmware - Bootstrap Part 1
#  Root files + main application
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

Write-Host "Creating project at $root" -ForegroundColor Cyan

if (Test-Path $root) { Remove-Item -Recurse -Force $root }
New-Item -ItemType Directory -Force -Path $root | Out-Null

$dirs = @(
  "main","test","tools",
  "components\board_support",
  "components\power_manager",
  "components\max30101",
  "components\max30205",
  "components\ad8232_ads1115",
  "components\lis2dw12",
  "components\gc9a01",
  "components\w25q64jv",
  "components\max17048",
  "components\signal_quality",
  "components\signal_processing",
  "components\data_manager",
  "components\ble_manager",
  "components\ui_manager",
  "components\security_manager"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null }

function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# ---------------- Root ----------------
W "CMakeLists.txt" @'
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(guardian-watch-firmware)
'@

W "sdkconfig.defaults" @'
CONFIG_IDF_TARGET="esp32c3"
CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y
CONFIG_ESPTOOLPY_FLASHMODE_QIO=y
CONFIG_ESPTOOLPY_FLASHFREQ_80M=y
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions.csv"
CONFIG_FREERTOS_HZ=1000
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_160=y
CONFIG_BT_ENABLED=y
CONFIG_BT_BLE_ENABLED=y
CONFIG_BT_GATTS_ENABLE=y
CONFIG_BT_GATTC_ENABLE=n
CONFIG_BT_BLE_SMP_ENABLE=y
CONFIG_BT_BLE_42_FEATURES_SUPPORTED=y
CONFIG_BT_BLE_50_FEATURES_SUPPORTED=n
CONFIG_BTDM_CTRL_BLE_MAX_CONN=1
CONFIG_BT_BLE_DYNAMIC_ENV_MEMORY=y
CONFIG_ESP32C3_REV_MIN_3=y
CONFIG_PM_ENABLE=y
CONFIG_FREERTOS_USE_TICKLESS_IDLE=y
CONFIG_LOG_DEFAULT_LEVEL_INFO=y
CONFIG_LOG_MAXIMUM_LEVEL_DEBUG=y
CONFIG_NVS_ENCRYPTION=y
'@

W "partitions.csv" @'
# Name,     Type, SubType, Offset,   Size,     Flags
nvs,        data, nvs,     0x9000,   0x6000,
otadata,    data, ota,     0xf000,   0x2000,
phy_init,   data, phy,     0x11000,  0x1000,
factory,    app,  factory, 0x20000,  0x180000,
ota_0,      app,  ota_0,   0x1A0000, 0x180000,
otadata2,   data, ota,     0x320000, 0x2000,
telemetry,  data, spiffs,  0x330000, 0x100000,
ecg,        data, spiffs,  0x430000, 0x3C0000,
storage,    data, spiffs,  0x7F0000, 0x10000,
'@

# ---------------- main ----------------
W "main\CMakeLists.txt" @'
idf_component_register(SRCS "app_main.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support
                                power_manager
                                max30101
                                max30205
                                ad8232_ads1115
                                lis2dw12
                                gc9a01
                                w25q64jv
                                max17048
                                signal_quality
                                signal_processing
                                data_manager
                                ble_manager
                                ui_manager
                                security_manager
                                nvs_flash
                                esp_timer)
'@

W "main\app_main.c" @'
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "board.h"
#include "power_manager.h"
#include "max30101.h"
#include "max30205.h"
#include "ad8232_ads1115.h"
#include "lis2dw12.h"
#include "gc9a01.h"
#include "w25q64jv.h"
#include "max17048.h"
#include "signal_quality.h"
#include "signal_processing.h"
#include "data_manager.h"
#include "ble_manager.h"
#include "ui_manager.h"
#include "security_manager.h"

static const char *TAG = "gw_main";

typedef enum {
    APP_BOOT = 0, APP_SELF_TEST, APP_IDLE, APP_ADVERTISING,
    APP_CONNECTED, APP_SESSION_ACTIVE, APP_SAVE_SYNC, APP_FAULT,
} app_state_t;

static app_state_t s_state = APP_BOOT;
static EventGroupHandle_t s_evt;

#define EVT_BLE_CONNECTED    BIT0
#define EVT_BLE_DISCONNECTED BIT1
#define EVT_BLE_AUTHED       BIT2
#define EVT_SESSION_START    BIT3
#define EVT_SESSION_STOP     BIT4
#define EVT_BTN_LONG_PRESS   BIT5
#define EVT_LOW_BATTERY      BIT6
#define EVT_FAULT            BIT7

static esp_err_t self_test(void);
static void state_task(void *arg);
static void sensor_task(void *arg);
static void processing_task(void *arg);

static void on_ble_event(ble_event_t evt, void *data)
{
    switch (evt) {
    case BLE_EVT_CONNECTED:    xEventGroupSetBits(s_evt, EVT_BLE_CONNECTED);    break;
    case BLE_EVT_DISCONNECTED: xEventGroupSetBits(s_evt, EVT_BLE_DISCONNECTED); break;
    case BLE_EVT_AUTH_OK:      xEventGroupSetBits(s_evt, EVT_BLE_AUTHED);       break;
    case BLE_EVT_AUTH_FAIL:
        ESP_LOGW(TAG, "BLE auth failed");
        ble_manager_disconnect();
        break;
    default: break;
    }
}

static void on_button_long_press(void) { xEventGroupSetBits(s_evt, EVT_BTN_LONG_PRESS); }
static void on_low_battery(void)       { xEventGroupSetBits(s_evt, EVT_LOW_BATTERY); }

static esp_err_t self_test(void)
{
    ESP_LOGI(TAG, "Self-test begin");
    ESP_ERROR_CHECK(max30101_init());
    ESP_ERROR_CHECK(max30205_init());
    ESP_ERROR_CHECK(lis2dw12_init());
    ESP_ERROR_CHECK(max17048_init());
    ESP_ERROR_CHECK(w25q64jv_init());
    ESP_ERROR_CHECK(ad8232_ads1115_init());
    ESP_ERROR_CHECK(gc9a01_init());
    ESP_LOGI(TAG, "Self-test OK");
    return ESP_OK;
}

static void sensor_task(void *arg)
{
    const TickType_t period = pdMS_TO_TICKS(20);
    TickType_t last = xTaskGetTickCount();
    while (1) {
        vTaskDelayUntil(&last, period);
        if (s_state != APP_SESSION_ACTIVE && s_state != APP_CONNECTED) {
            static uint32_t idle_div = 0;
            if (++idle_div % 50 != 0) continue;
        }
        max30101_sample_t ppg;
        if (max30101_read_fifo(&ppg) == ESP_OK) data_manager_push_ppg(&ppg);

        lis2dw12_sample_t acc;
        if (lis2dw12_read(&acc) == ESP_OK) data_manager_push_motion(&acc);

        static uint32_t temp_div = 0;
        if (++temp_div % 1500 == 0) {
            float t;
            if (max30205_read_temp(&t) == ESP_OK) data_manager_push_temp(t);
        }
        static uint32_t gauge_div = 0;
        if (++gauge_div % 3000 == 0) {
            max17048_sample_t g;
            if (max17048_read(&g) == ESP_OK) power_manager_update_gauge(&g);
        }
    }
}

static void processing_task(void *arg)
{
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        signal_processing_tick();
        if (s_state == APP_CONNECTED || s_state == APP_SESSION_ACTIVE) {
            telemetry_packet_t pkt;
            if (signal_processing_get_telemetry(&pkt) == ESP_OK) {
                ble_manager_notify_telemetry(&pkt);
                data_manager_push_telemetry(&pkt);
            }
        }
    }
}

static void state_task(void *arg)
{
    EventBits_t bits;
    while (1) {
        bits = xEventGroupWaitBits(s_evt,
            EVT_BLE_CONNECTED | EVT_BLE_DISCONNECTED | EVT_BLE_AUTHED |
            EVT_SESSION_START | EVT_SESSION_STOP | EVT_BTN_LONG_PRESS |
            EVT_LOW_BATTERY | EVT_FAULT,
            pdTRUE, pdFALSE, portMAX_DELAY);

        if (bits & EVT_FAULT) { s_state = APP_FAULT; ui_manager_show_fault(); continue; }

        switch (s_state) {
        case APP_IDLE:
            if (bits & EVT_BLE_CONNECTED) { s_state = APP_CONNECTED; ui_manager_show_connected(); }
            else if (bits & EVT_SESSION_START) { s_state = APP_SESSION_ACTIVE; ui_manager_show_session(); }
            break;
        case APP_ADVERTISING:
            if (bits & EVT_BLE_CONNECTED) { s_state = APP_CONNECTED; ui_manager_show_connected(); }
            break;
        case APP_CONNECTED:
            if (bits & EVT_BLE_AUTHED) ble_manager_enable_trusted_services();
            if (bits & EVT_BLE_DISCONNECTED) {
                s_state = APP_IDLE;
                ble_manager_start_advertising();
                ui_manager_show_idle();
            }
            if (bits & EVT_SESSION_START) { s_state = APP_SESSION_ACTIVE; ui_manager_show_session(); }
            break;
        case APP_SESSION_ACTIVE:
            if (bits & EVT_SESSION_STOP) { s_state = APP_CONNECTED; ui_manager_show_connected(); }
            break;
        default: break;
        }

        if (bits & EVT_BTN_LONG_PRESS) { ESP_LOGI(TAG, "Long press: shutdown"); power_manager_shutdown(); }
        if (bits & EVT_LOW_BATTERY)    { ESP_LOGW(TAG, "Low battery"); ui_manager_show_low_battery(); }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Guardian Watch firmware starting");

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_evt = xEventGroupCreate();
    configASSERT(s_evt);

    board_init();
    ESP_ERROR_CHECK(power_manager_init());
    ESP_ERROR_CHECK(security_manager_init());
    ESP_ERROR_CHECK(self_test());
    ESP_ERROR_CHECK(data_manager_init());
    ESP_ERROR_CHECK(signal_processing_init());
    ESP_ERROR_CHECK(signal_quality_init());
    ESP_ERROR_CHECK(ui_manager_init());
    ESP_ERROR_CHECK(ble_manager_init(on_ble_event));
    ESP_ERROR_CHECK(power_manager_register_button_cb(on_button_long_press));
    ESP_ERROR_CHECK(power_manager_register_low_battery_cb(on_low_battery));

    xTaskCreate(state_task,      "state",      4096, NULL, 5, NULL);
    xTaskCreate(sensor_task,     "sensor",     4096, NULL, 6, NULL);
    xTaskCreate(processing_task, "processing", 4096, NULL, 4, NULL);

    s_state = APP_ADVERTISING;
    ui_manager_show_boot();
    ble_manager_start_advertising();
}
'@

Write-Host "setup-1 done." -ForegroundColor Green