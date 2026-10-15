#pragma once

#include "esp_err.h"

esp_err_t max30205_init(void);
esp_err_t max30205_read_temp(float *celsius);