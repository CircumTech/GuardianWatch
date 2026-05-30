#ifndef SENSOR_MANAGER_H
#define SENSOR_MANAGER_H

#include <stdint.h>

typedef struct
{
    float heart_rate;
    float spo2;
    float temperature;
    int ecg_value;
    int battery_level;
    uint64_t timestamp;

} sensor_data_t;

void init_sensors();

void read_all_sensors(sensor_data_t *data);

#endif