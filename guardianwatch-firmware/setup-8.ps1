# =====================================================================
#  Guardian Watch Firmware - Step 8
#  Creates:
#    components/w25q64jv/  (8 MB SPI NOR flash, low-level driver)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 8: W25Q64JV SPI flash ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/w25q64jv/CMakeLists.txt ---
W "components\w25q64jv\CMakeLists.txt" @'
idf_component_register(SRCS "w25q64jv.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_spi)
'@

Write-Host "  + components\w25q64jv\CMakeLists.txt" -ForegroundColor Green

# --- components/w25q64jv/w25q64jv.h ---
W "components\w25q64jv\w25q64jv.h" @'
#pragma once

#include <stdint.h>
#include <stddef.h>
#include "esp_err.h"

#define W25Q_PAGE_SIZE      256
#define W25Q_SECTOR_SIZE    4096
#define W25Q_BLOCK_SIZE     (64 * 1024)
#define W25Q_TOTAL_SIZE     (8 * 1024 * 1024)   /* 8 MB */

esp_err_t w25q64jv_init(void);

esp_err_t w25q64jv_read(uint32_t addr, void *buf, size_t len);
esp_err_t w25q64jv_page_program(uint32_t addr, const void *buf, size_t len);
esp_err_t w25q64jv_sector_erase(uint32_t addr);
esp_err_t w25q64jv_write(uint32_t addr, const void *buf, size_t len);
'@

Write-Host "  + components\w25q64jv\w25q64jv.h" -ForegroundColor Green

# --- components/w25q64jv/w25q64jv.c ---
W "components\w25q64jv\w25q64jv.c" @'
#include "w25q64jv.h"
#include "board.h"
#include "esp_log.h"
#include "driver/spi_master.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "w25q";

/* Command set */
#define CMD_WRITE_ENABLE    0x06
#define CMD_WRITE_DISABLE   0x04
#define CMD_READ_STATUS1    0x05
#define CMD_READ_DATA       0x03
#define CMD_PAGE_PROGRAM    0x02
#define CMD_SECTOR_ERASE    0x20
#define CMD_BLOCK_ERASE     0xD8
#define CMD_CHIP_ERASE      0xC7
#define CMD_JEDEC_ID        0x9F
#define CMD_RELEASE_PDOWN   0xAB

/* Expected JEDEC ID for W25Q64JV */
#define JEDEC_W25Q64JV      0xEF4017

/* Status register 1 bits */
#define SR1_BUSY            (1 << 0)
#define SR1_WEL             (1 << 1)

static spi_device_handle_t s_spi;

/* -------- Low-level helpers -------- */

static esp_err_t cmd_only(uint8_t cmd)
{
    spi_transaction_t t = {
        .length = 8,
        .tx_buffer = &cmd,
    };
    return spi_device_polling_transmit(s_spi, &t);
}

static esp_err_t wren(void)
{
    return cmd_only(CMD_WRITE_ENABLE);
}

static esp_err_t read_status(uint8_t *status)
{
    uint8_t tx[2] = {CMD_READ_STATUS1, 0x00};
    uint8_t rx[2] = {0};
    spi_transaction_t t = {
        .length = 16,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "status");
    *status = rx[1];
    return ESP_OK;
}

static esp_err_t wait_ready(uint32_t timeout_ms)
{
    TickType_t start = xTaskGetTickCount();
    uint8_t status = 0;
    do {
        ESP_RETURN_ON_ERROR(read_status(&status), TAG, "status");
        if (!(status & SR1_BUSY)) return ESP_OK;
        vTaskDelay(1);
    } while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(timeout_ms));

    ESP_LOGE(TAG, "Flash busy timeout");
    return ESP_ERR_TIMEOUT;
}

/* -------- Public API -------- */

esp_err_t w25q64jv_init(void)
{
    s_spi = board_flash_spi();

    /* Release from power-down (safe even if not in power-down) */
    cmd_only(CMD_RELEASE_PDOWN);
    vTaskDelay(pdMS_TO_TICKS(1));

    /* Read JEDEC ID: 1 cmd byte + 3 ID bytes = 4 bytes total */
    uint8_t tx[4] = {CMD_JEDEC_ID, 0, 0, 0};
    uint8_t rx[4] = {0};
    spi_transaction_t t = {
        .length = 32,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "jedec");

    uint32_t id = ((uint32_t)rx[1] << 16) | ((uint32_t)rx[2] << 8) | rx[3];
    ESP_LOGI(TAG, "JEDEC ID 0x%06lX", (unsigned long)id);
    if (id != JEDEC_W25Q64JV) {
        ESP_LOGW(TAG, "Unexpected JEDEC ID (expected 0x%06lX for W25Q64JV)",
                 (unsigned long)JEDEC_W25Q64JV);
        /* Continue anyway — some clones have identical command sets */
    }
    return ESP_OK;
}

esp_err_t w25q64jv_read(uint32_t addr, void *buf, size_t len)
{
    if (!buf || len == 0) return ESP_ERR_INVALID_ARG;

    /* Send command + 24-bit address in one 32-bit transaction,
     * then read the data in a second transaction (CS stays low
     * across polling transactions on the same device). */
    uint8_t cmd[4] = {
        CMD_READ_DATA,
        (uint8_t)(addr >> 16),
        (uint8_t)(addr >> 8),
        (uint8_t)(addr)
    };
    spi_transaction_t t = {
        .length = 32,
        .tx_buffer = cmd,
    };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");

    spi_transaction_t r = {
        .length = len * 8,
        .rx_buffer = buf,
    };
    return spi_device_polling_transmit(s_spi, &r);
}

esp_err_t w25q64jv_page_program(uint32_t addr, const void *buf, size_t len)
{
    if (!buf || len == 0) return ESP_ERR_INVALID_ARG;
    if (len > W25Q_PAGE_SIZE) return ESP_ERR_INVALID_ARG;
    /* Must not cross a page boundary */
    if ((addr / W25Q_PAGE_SIZE) != ((addr + len - 1) / W25Q_PAGE_SIZE))
        return ESP_ERR_INVALID_ARG;

    ESP_RETURN_ON_ERROR(wren(), TAG, "wren");

    uint8_t cmd[4] = {
        CMD_PAGE_PROGRAM,
        (uint8_t)(addr >> 16),
        (uint8_t)(addr >> 8),
        (uint8_t)(addr)
    };
    spi_transaction_t t = { .length = 32, .tx_buffer = cmd };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");

    spi_transaction_t d = { .length = len * 8, .tx_buffer = buf };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &d), TAG, "data");

    return wait_ready(200);
}

esp_err_t w25q64jv_sector_erase(uint32_t addr)
{
    /* Address must be 4 KB-aligned */
    if (addr % W25Q_SECTOR_SIZE != 0) return ESP_ERR_INVALID_ARG;

    ESP_RETURN_ON_ERROR(wren(), TAG, "wren");

    uint8_t cmd[4] = {
        CMD_SECTOR_ERASE,
        (uint8_t)(addr >> 16),
        (uint8_t)(addr >> 8),
        (uint8_t)(addr)
    };
    spi_transaction_t t = { .length = 32, .tx_buffer = cmd };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(s_spi, &t), TAG, "cmd");

    return wait_ready(1000);
}

esp_err_t w25q64jv_write(uint32_t addr, const void *buf, size_t len)
{
    if (!buf || len == 0) return ESP_ERR_INVALID_ARG;

    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        size_t chunk = W25Q_PAGE_SIZE - (addr % W25Q_PAGE_SIZE);
        if (chunk > len) chunk = len;

        ESP_RETURN_ON_ERROR(w25q64jv_page_program(addr, p, chunk), TAG, "page");
        addr += chunk;
        p    += chunk;
        len  -= chunk;
    }
    return ESP_OK;
}
'@

Write-Host "  + components\w25q64jv\w25q64jv.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 8 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\w25q64jv\CMakeLists.txt"
Write-Host "  - components\w25q64jv\w25q64jv.h"
Write-Host "  - components\w25q64jv\w25q64jv.c"
Write-Host ""