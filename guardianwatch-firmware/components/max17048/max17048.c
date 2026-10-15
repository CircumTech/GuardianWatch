#include "max17048.h"
#include "board.h"
#include "esp_log.h"
#include "driver/i2c_master.h"

static const char *TAG = "max17048";
#define ADDR       0x36
#define REG_VCELL  0x02
#define REG_SOC    0x04
#define REG_CRATE  0x16

static i2c_master_dev_handle_t s_dev;

esp_err_t max17048_init(void)
{
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ADDR,
        .scl_speed_hz = BOARD_I2C_FREQ_HZ,
    };
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(board_i2c_bus(), &cfg, &s_dev),
                        TAG, "add");
    ESP_LOGI(TAG, "MAX17048 initialized");
    return ESP_OK;
}

static esp_err_t rd16(uint8_t reg, uint16_t *val)
{
    uint8_t b[2];
    ESP_RETURN_ON_ERROR(i2c_master_transmit_receive(s_dev, &reg, 1, b, 2, 100),
                        TAG, "rd16");
    *val = ((uint16_t)b[0] << 8) | b[1];
    return ESP_OK;
}

esp_err_t max17048_read(max17048_sample_t *out)
{
    uint16_t vcell, soc, crate;
    ESP_RETURN_ON_ERROR(rd16(REG_VCELL, &vcell), TAG, "vcell");
    ESP_RETURN_ON_ERROR(rd16(REG_SOC, &soc), TAG, "soc");
    ESP_RETURN_ON_ERROR(rd16(REG_CRATE, &crate), TAG, "crate");

    out->voltage     = vcell * 78.125e-6f;         /* 78.125 uV/LSB */
    out->soc_percent = soc * 1.0f / 256.0f;        /* 1/256 % per LSB */
    out->crate       = (int16_t)crate * 0.208f;    /* 0.208 %/hr per LSB */
    return ESP_OK;
}