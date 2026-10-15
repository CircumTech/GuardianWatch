#include "board.h"
#include "esp_log.h"

static const char *TAG = "board";

static i2c_master_bus_handle_t s_i2c_bus = NULL;
static spi_device_handle_t     s_disp = NULL;
static spi_device_handle_t     s_flash = NULL;

static esp_err_t i2c_bus_init(void)
{
    i2c_master_bus_config_t cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = BOARD_I2C_PORT,
        .scl_io_num = BOARD_I2C_SCL,
        .sda_io_num = BOARD_I2C_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    return i2c_new_master_bus(&cfg, &s_i2c_bus);
}

static esp_err_t spi_bus_init(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = BOARD_SPI_MOSI,
        .miso_io_num = BOARD_SPI_MISO,
        .sclk_io_num = BOARD_SPI_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4096,
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(BOARD_SPI_HOST, &bus, SPI_DMA_CH_AUTO),
                        TAG, "spi_bus_initialize");

    spi_device_interface_config_t disp_cfg = {
        .clock_speed_hz = BOARD_DISP_SPI_HZ,
        .mode = 0,
        .spics_io_num = BOARD_DISP_CS,
        .queue_size = 4,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &disp_cfg, &s_disp),
                        TAG, "add display");

    spi_device_interface_config_t flash_cfg = {
        .clock_speed_hz = BOARD_FLASH_SPI_HZ,
        .mode = 0,
        .spics_io_num = BOARD_FLASH_CS,
        .queue_size = 2,
    };
    ESP_RETURN_ON_ERROR(spi_bus_add_device(BOARD_SPI_HOST, &flash_cfg, &s_flash),
                        TAG, "add flash");
    return ESP_OK;
}

static esp_err_t gpio_init(void)
{
    /* Outputs: display DC, display RST, buzzer */
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << BOARD_DISP_DC) |
                        (1ULL << BOARD_DISP_RST) |
                        (1ULL << BOARD_BUZZER),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&out), TAG, "gpio out");

    /* Inputs: sensor interrupts, ECG lead-off, power button */
    gpio_config_t in = {
        .pin_bit_mask = (1ULL << BOARD_MAX30101_INT) |
                        (1ULL << BOARD_LIS2DW12_INT1) |
                        (1ULL << BOARD_ADS1115_ALERT) |
                        (1ULL << BOARD_AD8232_LOD_NEG) |
                        (1ULL << BOARD_AD8232_LOD_POS) |
                        (1ULL << BOARD_BTN_POWER),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_NEGEDGE,
    };
    return gpio_config(&in);
}

esp_err_t board_init(void)
{
    ESP_ERROR_CHECK(gpio_init());
    ESP_ERROR_CHECK(i2c_bus_init());
    ESP_ERROR_CHECK(spi_bus_init());
    ESP_LOGI(TAG, "Board init complete");
    return ESP_OK;
}

i2c_master_bus_handle_t board_i2c_bus(void)      { return s_i2c_bus; }
spi_device_handle_t     board_display_spi(void) { return s_disp; }
spi_device_handle_t     board_flash_spi(void)   { return s_flash; }