#pragma once

#include <stdbool.h>
#include "esp_err.h"

typedef struct {
    float ax;   /* g */
    float ay;   /* g */
    float az;   /* g */
} lis2dw12_sample_t;

esp_err_t lis2dw12_init(void);
esp_err_t lis2dw12_read(lis2dw12_sample_t *out);
esp_err_t lis2dw12_set_odr(uint8_t odr_hz);