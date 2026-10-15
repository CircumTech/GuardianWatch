#include "max30101.h"
#include "board.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"

static const char *TAG = "max30101";

/* I2C address and register map */
#define ADDR               0x57
#define REG_INT_STATUS_1   0x00
#define REG_INT_ENABLE_1   0x02
#define REG_FIFO_WR_PTR    0x04
#define REG_OVF_COUNTER    0x05
#define REG_FIFO_RD_PTR    0x06
#define REG_FIFO_DATA      0x07
#define REG_FIFO_CONFIG    0x08
#define REG_MODE_CONFIG    0x09
#define REG_SPO2_CONFIG    0x0A
#define REG_LED1_PA        0x0C
#define REG_LED2_PA        0x0D
#define REG_PART_ID        0xFF

static i2c_master_dev_handle_t s_dev;

static esp_err_t wr(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = {reg, val};
    return i2c_master_transmit(s_dev, b, 2, 100);
}

static esp_err_t rd(uint8_t reg, uint8_t *val)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, val, 1, 100);
}

esp_err_t max30101_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add device");

    uint8_t part = 0;
    ESP_RETURN_ON_ERROR(rd(REG_PART_ID, &part), TAG, "part_id");
    if (part != 0x15) {
        ESP_LOGE(TAG, "Unexpected PART_ID 0x%02X", part);
        return ESP_ERR_INVALID_RESPONSE;
    }

    /* Soft reset */
    wr(REG_MODE_CONFIG, 0x40);
    vTaskDelay(pdMS_TO_TICKS(10));

    /* FIFO: 4-sample average, roll-over on, almost-full at 17 */
    wr(REG_FIFO_CONFIG, 0x4F);

    /* Mode: SpO2 (Red + IR) */
    wr(REG_MODE_CONFIG, MAX30101_MODE_SPO2);

    /* SpO2 config: 50 Hz sample rate, 411 us pulse width, 4096 nA range */
    wr(REG_SPO2_CONFIG, 0x27);

    /* LED currents ~6 mA each */
    wr(REG_LED1_PA, 0x24);
    wr(REG_LED2_PA, 0x24);

    /* Clear FIFO pointers */
    wr(REG_FIFO_WR_PTR, 0);
    wr(REG_OVF_COUNTER, 0);
    wr(REG_FIFO_RD_PTR, 0);

    ESP_LOGI(TAG, "MAX30101 initialized (PART_ID 0x%02X)", part);
    return ESP_OK;
}

esp_err_t max30101_set_mode(max30101_mode_t mode)
{
    return wr(REG_MODE_CONFIG, (uint8_t)mode);
}

esp_err_t max30101_set_led_current(uint8_t red_ma, uint8_t ir_ma)
{
    /* LED current register: ~0.2 mA per LSB */
    ESP_RETURN_ON_ERROR(wr(REG_LED1_PA, red_ma), TAG, "LED1");
    ESP_RETURN_ON_ERROR(wr(REG_LED2_PA, ir_ma),  TAG, "LED2");
    return ESP_OK;
}

esp_err_t max30101_shutdown(bool enable)
{
    return wr(REG_MODE_CONFIG, enable ? 0x80 : MAX30101_MODE_SPO2);
}

esp_err_t max30101_read_fifo(max30101_sample_t *out)
{
    uint8_t wrp = 0, ovf = 0, rdp = 0;
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_WR_PTR, &wrp), TAG, "wr_ptr");
    ESP_RETURN_ON_ERROR(rd(REG_OVF_COUNTER, &ovf), TAG, "ovf");
    ESP_RETURN_ON_ERROR(rd(REG_FIFO_RD_PTR, &rdp), TAG, "rd_ptr");

    if (wrp == rdp) {
        return ESP_ERR_NOT_FOUND; /* FIFO empty */
    }

    /* Read 6 bytes = 3 Red + 3 IR */
    uint8_t data[6];
    uint8_t reg = REG_FIFO_DATA;
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, data, 6, 100),
                        TAG, "fifo_data");

    out->red = (((uint32_t)data[0] << 16) |
                ((uint32_t)data[1] << 8)  |
                 (uint32_t)data[2]) & 0x3FFFF;
    out->ir  = (((uint32_t)data[3] << 16) |
                ((uint32_t)data[4] << 8)  |
                 (uint32_t)data[5]) & 0x3FFFF;
    out->hr_valid   = 0;
    out->spo2_valid = 0;

    /* Advance read pointer */
    wr(REG_FIFO_RD_PTR, (rdp + 1) % 32);
    return ESP_OK;
}