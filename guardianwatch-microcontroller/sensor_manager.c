#include "sensor_manager.h"
#include "max30101.h"
#include "max30205.h"
#include "ecg_manager.h"
#include "esp_timer.h"

void init_sensors()
{
    max30101_init();

    max30205_init();

    ecg_init();
}

void read_all_sensors(sensor_data_t *data)
{
    data->heart_rate = max30101_get_heart_rate();

    data->spo2 = max30101_get_spo2();

    data->temperature = max30205_get_temperature();

    data->ecg_value = ecg_read();

    data->battery_level = 87;

    data->timestamp = esp_timer_get_time();
}