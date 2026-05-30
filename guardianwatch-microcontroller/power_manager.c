#include "esp_sleep.h"

void init_power_manager()
{
    // Configure wakeup sources
}

void enter_low_power_mode()
{
    esp_sleep_enable_timer_wakeup(5000000);

    esp_deep_sleep_start();
}