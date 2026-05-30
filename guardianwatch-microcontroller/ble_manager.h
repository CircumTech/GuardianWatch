#ifndef BLE_MANAGER_H
#define BLE_MANAGER_H

#include "sensor_manager.h"

void init_ble();

void ble_send_sensor_data(sensor_data_t *data);

#endif