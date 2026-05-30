#include "storage_manager.h"
#include "esp_log.h"

void init_storage()
{
    ESP_LOGI("STORAGE", "Initializing local storage...");

    // SPI flash mount
    // Filesystem initialization
}

void store_sensor_data(sensor_data_t *data)
{
    // Save locally if not synced
}