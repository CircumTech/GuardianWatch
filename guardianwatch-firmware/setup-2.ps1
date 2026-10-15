# =====================================================================
#  Guardian Watch Firmware - Step 2
#  Creates main/CMakeLists.txt and main/app_main.c
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 2: Main application ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- main/CMakeLists.txt ---
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

Write-Host "  + main\CMakeLists.txt" -ForegroundColor Green

# --- main/app_main.c ---
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
    APP_BOOT = 0,
    APP_SELF_TEST,
    APP_IDLE,
    APP_ADVERTISING,
    APP_CONNECTED,
    APP_SESSION_ACTIVE,
    APP_SAVE_SYNC,
    APP_FAULT,
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

/* ---------- Event callbacks ---------- */

static void on_ble_event(ble_event_t evt, void *data)
{
    switch (evt) {
    case BLE_EVT_CONNECTED:    xEventGroupSetBits(s_evt, EVT_BLE_CONNECTED);    break;
    case BLE_EVT_DISCONNECTED: xEventGroupSetBits(s_evt, EVT_BLE_DISCONNECTED); break;
    case BLE_EVT_AUTH_OK:      xEventGroupSetBits(s_evt, EVT_BLE_AUTHED);       break;
    case BLE_EVT_AUTH_FAIL:
        ESP_LOGW(TAG, "BLE auth failed; disconnecting");
        ble_manager_disconnect();
        break;
    default: break;
    }
}

static void on_button_long_press(void)
{
    xEventGroupSetBits(s_evt, EVT_BTN_LONG_PRESS);
}

static void on_low_battery(void)
{
    xEventGroupSetBits(s_evt, EVT_LOW_BATTERY);
}

/* ---------- Self-test ---------- */

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

/* ---------- Sensor task ---------- */

static void sensor_task(void *arg)
{
    const TickType_t period = pdMS_TO_TICKS(20); /* 50 Hz */
    TickType_t last = xTaskGetTickCount();

    while (1) {
        vTaskDelayUntil(&last, period);

        if (s_state != APP_SESSION_ACTIVE && s_state != APP_CONNECTED) {
            static uint32_t idle_div = 0;
            if (++idle_div % 50 != 0) continue;
        }

        max30101_sample_t ppg;
        if (max30101_read_fifo(&ppg) == ESP_OK) {
            data_manager_push_ppg(&ppg);
        }

        lis2dw12_sample_t acc;
        if (lis2dw12_read(&acc) == ESP_OK) {
            data_manager_push_motion(&acc);
        }

        static uint32_t temp_div = 0;
        if (++temp_div % 1500 == 0) {
            float t;
            if (max30205_read_temp(&t) == ESP_OK) {
                data_manager_push_temp(t);
            }
        }

        static uint32_t gauge_div = 0;
        if (++gauge_div % 3000 == 0) {
            max17048_sample_t g;
            if (max17048_read(&g) == ESP_OK) {
                power_manager_update_gauge(&g);
            }
        }
    }
}

/* ---------- Processing task ---------- */

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

/* ---------- State task ---------- */

static void state_task(void *arg)
{
    EventBits_t bits;
    while (1) {
        bits = xEventGroupWaitBits(s_evt,
                                   EVT_BLE_CONNECTED | EVT_BLE_DISCONNECTED |
                                   EVT_BLE_AUTHED | EVT_SESSION_START |
                                   EVT_SESSION_STOP | EVT_BTN_LONG_PRESS |
                                   EVT_LOW_BATTERY | EVT_FAULT,
                                   pdTRUE, pdFALSE, portMAX_DELAY);

        if (bits & EVT_FAULT) {
            ESP_LOGE(TAG, "Fault event; entering FAULT");
            s_state = APP_FAULT;
            ui_manager_show_fault();
            continue;
        }

        switch (s_state) {
        case APP_IDLE:
            if (bits & EVT_BLE_CONNECTED) {
                s_state = APP_CONNECTED;
                ui_manager_show_connected();
            } else if (bits & EVT_SESSION_START) {
                s_state = APP_SESSION_ACTIVE;
                ui_manager_show_session();
            }
            break;

        case APP_ADVERTISING:
            if (bits & EVT_BLE_CONNECTED) {
                s_state = APP_CONNECTED;
                ui_manager_show_connected();
            }
            break;

        case APP_CONNECTED:
            if (bits & EVT_BLE_AUTHED) {
                ble_manager_enable_trusted_services();
            }
            if (bits & EVT_BLE_DISCONNECTED) {
                s_state = APP_IDLE;
                ble_manager_start_advertising();
                ui_manager_show_idle();
            }
            if (bits & EVT_SESSION_START) {
                s_state = APP_SESSION_ACTIVE;
                ui_manager_show_session();
            }
            break;

        case APP_SESSION_ACTIVE:
            if (bits & EVT_SESSION_STOP) {
                s_state = APP_CONNECTED;
                ui_manager_show_connected();
            }
            break;

        default:
            break;
        }

        if (bits & EVT_BTN_LONG_PRESS) {
            ESP_LOGI(TAG, "Long press: shutting down");
            power_manager_shutdown();
        }

        if (bits & EVT_LOW_BATTERY) {
            ESP_LOGW(TAG, "Low battery");
            ui_manager_show_low_battery();
        }
    }
}

/* ---------- Entry point ---------- */

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

Write-Host "  + main\app_main.c" -ForegroundColor Green
Write-Host ""
Write-Host "=== Step 2 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - main\CMakeLists.txt"
Write-Host "  - main\app_main.c"
Write-Host ""