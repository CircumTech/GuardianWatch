#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "sensor_manager.h"
#include "ble_manager.h"
#include "storage_manager.h"
#include "power_manager.h"
#include "display_manager.h"
#include "insight_engine.h"

static const char *TAG = "GUARDIAN_MAIN";

void sensor_task(void *pvParameters)
{
    while (1)
    {
        sensor_data_t data;

        read_all_sensors(&data);

        process_insights(&data);

        store_sensor_data(&data);

        update_display(&data);

        ble_send_sensor_data(&data);

        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Guardian Watch Booting...");

    init_power_manager();

    init_storage();

    init_ble();

    init_display();

    init_sensors();

    xTaskCreate(sensor_task,
                "sensor_task",
                4096,
                NULL,
                5,
                NULL);
}