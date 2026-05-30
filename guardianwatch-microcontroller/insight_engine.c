#include "insight_engine.h"
#include "esp_log.h"

void process_insights(sensor_data_t *data)
{
    if (data->heart_rate > 120)
    {
        ESP_LOGW("INSIGHT", "High heart rate detected");
    }

    if (data->spo2 < 92)
    {
        ESP_LOGW("INSIGHT", "Low oxygen detected");
    }

    if (data->temperature > 37.8)
    {
        ESP_LOGW("INSIGHT", "Possible fever detected");
    }
}