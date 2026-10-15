#pragma once

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_err.h"

/* ---------- I2C bus (all sensors) ---------- */
#define BOARD_I2C_PORT          0
#define BOARD_I2C_SDA           GPIO_NUM_4
#define BOARD_I2C_SCL           GPIO_NUM_5
#define BOARD_I2C_FREQ_HZ       400000

/* ---------- SPI bus (display + flash) ---------- */
#define BOARD_SPI_HOST          SPI2_HOST
#define BOARD_SPI_MOSI          GPIO_NUM_11
#define BOARD_SPI_SCK           GPIO_NUM_12
#define BOARD_SPI_MISO          GPIO_NUM_13

/* Display (GC9A01) */
#define BOARD_DISP_CS           GPIO_NUM_14
#define BOARD_DISP_DC           GPIO_NUM_15
#define BOARD_DISP_RST          GPIO_NUM_16
#define BOARD_DISP_BL           GPIO_NUM_17
#define BOARD_DISP_SPI_HZ       (40 * 1000 * 1000)

/* Flash (W25Q64JV) */
#define BOARD_FLASH_CS          GPIO_NUM_18
#define BOARD_FLASH_SPI_HZ      (20 * 1000 * 1000)

/* ---------- Sensor interrupts ---------- */
#define BOARD_MAX30101_INT      GPIO_NUM_6
#define BOARD_MAX30205_ALERT    GPIO_NUM_7
#define BOARD_LIS2DW12_INT1     GPIO_NUM_10
#define BOARD_ADS1115_ALERT     GPIO_NUM_3

/* ---------- ECG lead-off detection ---------- */
#define BOARD_AD8232_LOD_NEG    GPIO_NUM_1
#define BOARD_AD8232_LOD_POS    GPIO_NUM_2

/* ---------- Misc ---------- */
#define BOARD_BUZZER            GPIO_NUM_19
#define BOARD_BTN_POWER         GPIO_NUM_20
#define BOARD_UART_TX           GPIO_NUM_21
#define BOARD_UART_RX           GPIO_NUM_22

/* ---------- Public API ---------- */
esp_err_t board_init(void);

i2c_master_bus_handle_t board_i2c_bus(void);
spi_device_handle_t     board_display_spi(void);
spi_device_handle_t     board_flash_spi(void);