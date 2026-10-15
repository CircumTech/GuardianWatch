#pragma once

#include <stdint.h>
#include "esp_err.h"

#define GC9A01_WIDTH   240
#define GC9A01_HEIGHT  240

/* Common RGB565 colors */
#define GC9A01_BLACK   0x0000
#define GC9A01_WHITE   0xFFFF
#define GC9A01_RED     0xF800
#define GC9A01_GREEN   0x07E0
#define GC9A01_BLUE    0x001F
#define GC9A01_YELLOW  0xFFE0
#define GC9A01_CYAN    0x07FF
#define GC9A01_MAGENTA 0xF81F
#define GC9A01_GRAY    0x7BEF

esp_err_t gc9a01_init(void);
esp_err_t gc9a01_set_backlight(uint8_t percent);   /* 0-100 */
esp_err_t gc9a01_fill(uint16_t color);
esp_err_t gc9a01_draw_pixel(int x, int y, uint16_t color);
esp_err_t gc9a01_draw_rect(int x, int y, int w, int h, uint16_t color);
esp_err_t gc9a01_draw_text(int x, int y, const char *text, uint16_t color, uint16_t bg);