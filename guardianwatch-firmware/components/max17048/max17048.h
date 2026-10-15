#pragma once

#include "esp_err.h"

typedef struct {
    float soc_percent;   /* 0-100 */
    float voltage;       /* volts */
    float crate;         /* %/hr */
} max17048_sample_t;

esp_err_t max17048_init(void);
esp_err_t max17048_read(max17048_sample_t *out);