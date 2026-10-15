$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"
function W($path, $content) {
  Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

W "components\w25q64jv\CMakeLists.txt" @'
idf_component_register(SRCS "w25q64jv.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_spi)
'@

W "components\w25q64jv\w25q64jv.h" @'
#pragma once
#include <stdint.h>
#include "esp_err.h"
#define W25Q_PAGE_SIZE      256
#define W25Q_SECTOR_SIZE    4096
#define W25Q_TOTAL_SIZE     (8 * 1024 * 1024)
esp_err_t w25q64jv_init(void);
esp_err_t w25q64jv_read(uint32_t addr, void *buf, size_t len);
esp_err_t w25q64jv_page_program(uint32_t addr, const void *buf, size_t len);
esp_err_t w25q64jv_sector_erase(uint32_t addr);
esp_err_t w25q64jv_write(uint32_t addr, const void *buf, size_t len);
'@

W "components\w25q64jv\w25q64jv.c" @'
#include "w25q64jv.h"
#include "board.h"
#include "esp_log.h"
#include "driver/spi_master.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "w25q";
#define CMD_WRITE_ENABLE  0x06
#define CMD_READ_STATUS1  0x05
#define CMD_READ_DATA     0x03
#define CMD_PAGE_PROGRAM  0x02
#define CMD_SECTOR_ERASE  0x20
#define CMD_JEDEC_ID      0x9F

static spi_device_handle_t s_spi;

static esp_err_t wren(void) {
    uint8_t cmd = CMD_WRITE_ENABLE;
    spi_transaction_t t = { .length = 8, .tx_buffer = &cmd };
    return spi_device_polling_transmit(s_spi, &t);
}

static esp_err_t wait_ready(uint32_t timeout_ms)
{
    uint8_t tx[2] = {CMD_READ_STATUS1, 0};
    uint8_t rx[2] = {0};
    TickType_t start = xTaskGetTickCount();
    do {
        spi_transaction_t t = { .length = 16, .tx_buffer = tx, .rx_buffer = rx };
        spi_device_polling_transmit(s_spi, &t);
        if (!(rx[1] & 0x01)) return ESP_OK;
        vTaskDelay(1);
    } while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(timeout_ms));
    ESP_LOGE(TAG, "ready timeout");
    return ESP_ERR_TIMEOUT;
}

esp_err_t w25q64jv_init(void)
{
    s_spi = board_flash_spi();
    uint8_t tx[4] = {CMD_JEDEC_ID, 0, 0, 0};
    uint8_t rx[4] = {0};
    spi_transaction_t t = { .length = 32, .tx_buffer = tx, .rx_buffer = rx };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "jedec");
    uint32_t id = (rx[1] << 16) | (rx[2] << 8) | rx[3];
    ESP_LOGI(TAG, "JEDEC ID 0x%06lX", (unsigned long)id);
    return ESP_OK;
}

esp_err_t w25q64jv_read(uint32_t addr, void *buf, size_t len)
{
    uint8_t cmd[4] = {CMD_READ_DATA, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr};
    spi_transaction_t t = { .length = 32, .tx_buffer = cmd };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");
    spi_transaction_t r = { .length = len * 8, .rx_buffer = buf };
    return spi_device_polling_transmit(s_spi, &r);
}

esp_err_t w25q64jv_page_program(uint32_t addr, const void *buf, size_t len)
{
    if (len > W25Q_PAGE_SIZE) return ESP_ERR_INVALID_ARG;
    ESP_RETURN_ON_ERROR(wren(), TAG, "wren");
    uint8_t cmd[4] = {CMD_PAGE_PROGRAM, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr};
    spi_transaction_t t = { .length = 32, .tx_buffer = cmd };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");
    spi_transaction_t d = { .length = len * 8, .tx_buffer = buf };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &d), TAG, "data");
    return wait_ready(100);
}

esp_err_t w25q64jv_sector_erase(uint32_t addr)
{
    ESP_RETURN_ON_ERROR(wren(), TAG, "wren");
    uint8_t cmd[4] = {CMD_SECTOR_ERASE, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr};
    spi_transaction_t t = { .length = 32, .tx_buffer = cmd };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");
    return wait_ready(1000);
}

esp_err_t w25q64jv_write(uint32_t addr, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len) {
        size_t chunk = W25Q_PAGE_SIZE - (addr % W25Q_PAGE_SIZE);
        if (chunk > len) chunk = len;
        ESP_RETURN_ON_ERROR(w25q64jv_page_program(addr, p, chunk), TAG, "page");
        addr += chunk; p += chunk; len -= chunk;
    }
    return ESP_OK;
}
'@

Write-Host "setup-2c done." -ForegroundColor Green