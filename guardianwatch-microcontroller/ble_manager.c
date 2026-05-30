#include "ble_manager.h"
#include "esp_log.h"

static const char *TAG = "BLE_MANAGER";

void init_ble()
{
    ESP_LOGI(TAG, "Initializing BLE...");

    // Initialize NimBLE stack
    // Create GATT services
    // Setup secure pairing
}

void ble_send_sensor_data(sensor_data_t *data)
{
    ESP_LOGI(TAG,
             "HR: %.2f | SpO2: %.2f | Temp: %.2f",
             data->heart_rate,
             data->spo2,
             data->temperature);

    // Serialize sensor packet
    // Send BLE notifications
}