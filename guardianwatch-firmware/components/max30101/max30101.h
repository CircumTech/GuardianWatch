#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

typedef enum {
    MAX30101_MODE_HR     = 0x02,   /* Red LED only */
    MAX30101_MODE_SPO2   = 0x03,   /* Red + IR */
    MAX30101_MODE_MULTI  = 0x07,   /* Red + IR + Green */
} max30101_mode_t;

typedef struct {
    uint32_t red;        /* 18-bit raw Red channel */
    uint32_t ir;         /* 18-bit raw IR channel */
    uint8_t  hr_valid;
    uint8_t  spo2_valid;
} max30101_sample_t;

esp_err_t max30101_init(void);
esp_err_t max30101_set_mode(max30101_mode_t mode);
esp_err_t max30101_read_fifo(max30101_sample_t *out);
esp_err_t max30101_set_led_current(uint8_t red_ma, uint8_t ir_ma);
esp_err_t max30101_shutdown(bool enable);