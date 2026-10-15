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