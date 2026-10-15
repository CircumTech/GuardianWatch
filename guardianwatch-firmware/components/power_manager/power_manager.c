#include "power_manager.h"
#include "board.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"

static const char *TAG = "power";

static power_state_t s_state = PWR_NORMAL;
static float         s_soc = 100.0f;
static float         s_soc_smooth = 100.0f;

static void (*s_btn_cb)(void) = NULL;
static void (*s_low_cb)(void) = NULL;

static esp_timer_handle_t s_btn_timer;

/* SOC thresholds (%) */
#define SOC_LOW         20.0f
#define SOC_CRITICAL    10.0f
#define SOC_SHUTDOWN     3.0f

/* Exponential smoothing factor */
#define SOC_ALPHA        0.2f

static void btn_timer_cb(void *arg)
{
    if (gpio_get_level(BOARD_BTN_POWER) == 0 && s_btn_cb) {
        s_btn_cb();
    }
}

esp_err_t power_manager_init(void)
{
    esp_timer_create_args_t args = {
        .callback = btn_timer_cb,
        .name = "btn_long",
    };
    ESP_ERROR_CHECK(esp_timer_create(&args, &s_btn_timer));
    ESP_LOGI(TAG, "Power manager ready");
    return ESP_OK;
}

esp_err_t power_manager_register_button_cb(void (*cb)(void))
{
    s_btn_cb = cb;
    return ESP_OK;
}

esp_err_t power_manager_register_low_battery_cb(void (*cb)(void))
{
    s_low_cb = cb;
    return ESP_OK;
}

void power_manager_update_gauge(const max17048_sample_t *s)
{
    s_soc = s->soc_percent;
    s_soc_smooth = (1.0f - SOC_ALPHA) * s_soc_smooth + SOC_ALPHA * s_soc;

    power_state_t prev = s_state;
    if (s_soc_smooth <= SOC_SHUTDOWN)      s_state = PWR_SHUTDOWN;
    else if (s_soc_smooth <= SOC_CRITICAL) s_state = PWR_CRITICAL;
    else if (s_soc_smooth <= SOC_LOW)      s_state = PWR_LOW;
    else                                   s_state = PWR_NORMAL;

    if (s_state != prev) {
        ESP_LOGW(TAG, "Power state %d -> %d (SOC %.1f%%)",
                 prev, s_state, s_soc_smooth);
        if (s_state == PWR_LOW && s_low_cb) s_low_cb();
        if (s_state == PWR_SHUTDOWN)        power_manager_shutdown();
    }
}

power_state_t power_manager_state(void) { return s_state; }
float         power_manager_soc(void)   { return s_soc_smooth; }

void power_manager_shutdown(void)
{
    ESP_LOGW(TAG, "Shutting down (deep sleep)");
    /* TODO: persist any pending state before sleeping */
    esp_deep_sleep_start();
}