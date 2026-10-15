#include "max30205.h"
#include "board.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"

static const char *TAG = "max30205";

#define ADDR        0x48
#define REG_TEMP    0x00
#define REG_CONFIG  0x01

/* Config bits:
 *   bit7 = shutdown
 *   bit0 = one-shot (auto-clear, triggers single conversion)
 */
#define CFG_SHUTDOWN  (1 << 0)
#define CFG_ONESHOT   (1 << 7)

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = {reg, val};
    return i2c_master_transmit(s_dev, b, 2, 100);
}

esp_err_t max30205_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    /* Put into shutdown mode (conversion only on demand) */
    wr(REG_CONFIG, 0x01);

    ESP_LOGI(TAG, "MAX30205 initialized");
    return ESP_OK;
}

esp_err_t max30205_read_temp(float *celsius)
{
    /* Trigger one-shot conversion (shutdown=1, oneshot=1) */
    ESP_RETURN_ON_ERROR(wr(REG_CONFIG, 0x81), TAG, "oneshot");

    /* Wait for conversion (max 50 ms per datasheet) */
    vTaskDelay(pdMS_TO_TICKS(50));

    /* Read 16-bit temperature */
    uint8_t reg = REG_TEMP;
    uint8_t buf[2] = {0};
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, buf, 2, 100),
                        TAG, "read");

    int16_t raw = ((int16_t)buf[0] << 8) | buf[1];
    *celsius = raw * 0.00390625f; /* 1/256 ??C per LSB */
    return ESP_OK;
}