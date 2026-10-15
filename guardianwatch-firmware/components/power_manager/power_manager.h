#pragma once

#include <stdbool.h>
#include "esp_err.h"
#include "max17048.h"

typedef enum {
    PWR_NORMAL = 0,
    PWR_LOW,
    PWR_CRITICAL,
    PWR_SHUTDOWN,
} power_state_t;

esp_err_t power_manager_init(void);

esp_err_t power_manager_register_button_cb(void (*cb)(void));
esp_err_t power_manager_register_low_battery_cb(void (*cb)(void));

void          power_manager_update_gauge(const max17048_sample_t *s);
power_state_t power_manager_state(void);
float         power_manager_soc(void);
void          power_manager_shutdown(void);