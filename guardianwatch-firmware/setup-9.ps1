# =====================================================================
#  Guardian Watch Firmware - Step 9
#  Creates:
#    components/gc9a01/   (240x240 circular TFT + 5x7 font)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 9: GC9A01 display ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/gc9a01/CMakeLists.txt ---
W "components\gc9a01\CMakeLists.txt" @'
idf_component_register(SRCS "gc9a01.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_spi esp_driver_gpio esp_driver_ledc)
'@

Write-Host "  + components\gc9a01\CMakeLists.txt" -ForegroundColor Green

# --- components/gc9a01/gc9a01.h ---
W "components\gc9a01\gc9a01.h" @'
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
'@

Write-Host "  + components\gc9a01\gc9a01.h" -ForegroundColor Green

# --- components/gc9a01/gc9a01.c ---
W "components\gc9a01\gc9a01.c" @'
#include "gc9a01.h"
#include "board.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include <string.h>

static const char *TAG = "gc9a01";

/* ---------- Command set (subset) ---------- */
#define CMD_SWRESET   0x01
#define CMD_SLPOUT    0x11
#define CMD_NORON     0x13
#define CMD_INVOFF    0x20
#define CMD_INVON     0x21
#define CMD_DISPON    0x29
#define CMD_CASET     0x2A
#define CMD_RASET     0x2B
#define CMD_RAMWR     0x2C
#define CMD_MADCTL    0x36
#define CMD_COLMOD    0x3A

static spi_device_handle_t s_spi;

/* ---------- Low-level I/O ---------- */

static inline void dc(int level) { gpio_set_level(BOARD_DISP_DC, level); }
static inline void rst(int level) { gpio_set_level(BOARD_DISP_RST, level); }

static void write_cmd(uint8_t cmd)
{
    dc(0);
    spi_transaction_t t = { .length = 8, .tx_buffer = &cmd };
    spi_device_polling_transmit(s_spi, &t);
}

static void write_data(const uint8_t *data, size_t len)
{
    if (!len) return;
    dc(1);
    spi_transaction_t t = { .length = len * 8, .tx_buffer = data };
    spi_device_polling_transmit(s_spi, &t);
}

static void write_data8(uint8_t v) { write_data(&v, 1); }

static void set_window(int x0, int y0, int x1, int y1)
{
    uint8_t caset[4] = { x0 >> 8, x0 & 0xFF, x1 >> 8, x1 & 0xFF };
    uint8_t raset[4] = { y0 >> 8, y0 & 0xFF, y1 >> 8, y1 & 0xFF };
    write_cmd(CMD_CASET); write_data(caset, 4);
    write_cmd(CMD_RASET); write_data(raset, 4);
    write_cmd(CMD_RAMWR);
}

/* ---------- Backlight PWM ---------- */

static esp_err_t backlight_init(void)
{
    ledc_timer_config_t t = {
        .speed_mode      = LEDC_LOW_SPEED_MODE,
        .timer_num       = LEDC_TIMER_0,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .freq_hz         = 5000,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ESP_RETURN_ON_ERROR(ledc_timer_config(&t), TAG, "timer");

    ledc_channel_config_t c = {
        .gpio_num   = BOARD_DISP_BL,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel    = LEDC_CHANNEL_0,
        .timer_sel  = LEDC_TIMER_0,
        .duty       = 0,
        .hpoint     = 0,
    };
    return ledc_channel_config(&c);
}

esp_err_t gc9a01_set_backlight(uint8_t percent)
{
    if (percent > 100) percent = 100;
    uint32_t duty = (255u * percent) / 100u;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, duty);
    return ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

/* ---------- Public API ---------- */

esp_err_t gc9a01_init(void)
{
    s_spi = board_display_spi();
    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "bl");

    /* Hardware reset */
    rst(1); vTaskDelay(pdMS_TO_TICKS(10));
    rst(0); vTaskDelay(pdMS_TO_TICKS(10));
    rst(1); vTaskDelay(pdMS_TO_TICKS(120));

    /* Software reset */
    write_cmd(CMD_SWRESET);
    vTaskDelay(pdMS_TO_TICKS(120));

    /* Sleep out */
    write_cmd(CMD_SLPOUT);
    vTaskDelay(pdMS_TO_TICKS(120));

    /* Memory access control: normal orientation, RGB */
    write_cmd(CMD_MADCTL); write_data8(0x00);

    /* Color mode: 16 bits/pixel (RGB565) */
    write_cmd(CMD_COLMOD); write_data8(0x55);

    /* Inversion on — required for most GC9A01 modules */
    write_cmd(CMD_INVON);

    /* Normal display mode on */
    write_cmd(CMD_NORON);
    vTaskDelay(pdMS_TO_TICKS(10));

    /* Display on */
    write_cmd(CMD_DISPON);
    vTaskDelay(pdMS_TO_TICKS(20));

    /* Clear screen and set a reasonable default backlight */
    gc9a01_fill(GC9A01_BLACK);
    gc9a01_set_backlight(30);

    ESP_LOGI(TAG, "GC9A01 initialized (%dx%d)", GC9A01_WIDTH, GC9A01_HEIGHT);
    return ESP_OK;
}

esp_err_t gc9a01_fill(uint16_t color)
{
    set_window(0, 0, GC9A01_WIDTH - 1, GC9A01_HEIGHT - 1);

    /* Build a full-width line buffer once and blast it row by row */
    static uint8_t line[GC9A01_WIDTH * 2];
    for (int i = 0; i < GC9A01_WIDTH; i++) {
        line[i * 2]     = (uint8_t)(color >> 8);
        line[i * 2 + 1] = (uint8_t)(color & 0xFF);
    }

    dc(1);
    for (int y = 0; y < GC9A01_HEIGHT; y++) {
        spi_transaction_t t = {
            .length = sizeof(line) * 8,
            .tx_buffer = line,
        };
        spi_device_polling_transmit(s_spi, &t);
    }
    return ESP_OK;
}

esp_err_t gc9a01_draw_pixel(int x, int y, uint16_t color)
{
    if (x < 0 || y < 0 || x >= GC9A01_WIDTH || y >= GC9A01_HEIGHT) return ESP_OK;
    set_window(x, y, x, y);
    uint8_t b[2] = { (uint8_t)(color >> 8), (uint8_t)(color & 0xFF) };
    write_data(b, 2);
    return ESP_OK;
}

esp_err_t gc9a01_draw_rect(int x, int y, int w, int h, uint16_t color)
{
    if (w <= 0 || h <= 0) return ESP_OK;
    if (x < 0 || y < 0) return ESP_ERR_INVALID_ARG;
    if (x + w > GC9A01_WIDTH || y + h > GC9A01_HEIGHT) return ESP_ERR_INVALID_ARG;

    set_window(x, y, x + w - 1, y + h - 1);

    static uint8_t line[GC9A01_WIDTH * 2];
    for (int i = 0; i < w; i++) {
        line[i * 2]     = (uint8_t)(color >> 8);
        line[i * 2 + 1] = (uint8_t)(color & 0xFF);
    }

    dc(1);
    for (int j = 0; j < h; j++) {
        spi_transaction_t t = {
            .length = (size_t)w * 16,
            .tx_buffer = line,
        };
        spi_device_polling_transmit(s_spi, &t);
    }
    return ESP_OK;
}

/* ---------- 5x7 font (ASCII 0x20 .. 0x7E) ----------
 * Each glyph is 5 bytes, one per column. Within each byte, bit 0 is the
 * top row and bit 6 is the bottom row (7 rows used). */
static const uint8_t FONT5X7[95][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x00,0x00,0x5F,0x00,0x00}, /* ! */
    {0x00,0x07,0x00,0x07,0x00}, /* " */
    {0x14,0x7F,0x14,0x7F,0x14}, /* # */
    {0x24,0x2A,0x7F,0x2A,0x12}, /* $ */
    {0x23,0x13,0x08,0x64,0x62}, /* % */
    {0x36,0x49,0x55,0x22,0x50}, /* & */
    {0x00,0x05,0x03,0x00,0x00}, /* ' */
    {0x00,0x1C,0x22,0x41,0x00}, /* ( */
    {0x00,0x41,0x22,0x1C,0x00}, /* ) */
    {0x08,0x2A,0x1C,0x2A,0x08}, /* * */
    {0x08,0x08,0x3E,0x08,0x08}, /* + */
    {0x00,0x50,0x30,0x00,0x00}, /* , */
    {0x08,0x08,0x08,0x08,0x08}, /* - */
    {0x00,0x60,0x60,0x00,0x00}, /* . */
    {0x20,0x10,0x08,0x04,0x02}, /* / */
    {0x3E,0x51,0x49,0x45,0x3E}, /* 0 */
    {0x00,0x42,0x7F,0x40,0x00}, /* 1 */
    {0x42,0x61,0x51,0x49,0x46}, /* 2 */
    {0x21,0x41,0x45,0x4B,0x31}, /* 3 */
    {0x18,0x14,0x12,0x7F,0x10}, /* 4 */
    {0x27,0x45,0x45,0x45,0x39}, /* 5 */
    {0x3C,0x4A,0x49,0x49,0x30}, /* 6 */
    {0x01,0x71,0x09,0x05,0x03}, /* 7 */
    {0x36,0x49,0x49,0x49,0x36}, /* 8 */
    {0x06,0x49,0x49,0x29,0x1E}, /* 9 */
    {0x00,0x36,0x36,0x00,0x00}, /* : */
    {0x00,0x56,0x36,0x00,0x00}, /* ; */
    {0x00,0x08,0x14,0x22,0x41}, /* < */
    {0x14,0x14,0x14,0x14,0x14}, /* = */
    {0x41,0x22,0x14,0x08,0x00}, /* > */
    {0x02,0x01,0x51,0x09,0x06}, /* ? */
    {0x32,0x49,0x79,0x41,0x3E}, /* @ */
    {0x7E,0x11,0x11,0x11,0x7E}, /* A */
    {0x7F,0x49,0x49,0x49,0x36}, /* B */
    {0x3E,0x41,0x41,0x41,0x22}, /* C */
    {0x7F,0x41,0x41,0x22,0x1C}, /* D */
    {0x7F,0x49,0x49,0x49,0x41}, /* E */
    {0x7F,0x09,0x09,0x09,0x01}, /* F */
    {0x3E,0x41,0x49,0x49,0x7A}, /* G */
    {0x7F,0x08,0x08,0x08,0x7F}, /* H */
    {0x00,0x41,0x7F,0x41,0x00}, /* I */
    {0x20,0x40,0x41,0x3F,0x01}, /* J */
    {0x7F,0x08,0x14,0x22,0x41}, /* K */
    {0x7F,0x40,0x40,0x40,0x40}, /* L */
    {0x7F,0x02,0x0C,0x02,0x7F}, /* M */
    {0x7F,0x04,0x08,0x10,0x7F}, /* N */
    {0x3E,0x41,0x41,0x41,0x3E}, /* O */
    {0x7F,0x09,0x09,0x09,0x06}, /* P */
    {0x3E,0x41,0x51,0x21,0x5E}, /* Q */
    {0x7F,0x09,0x19,0x29,0x46}, /* R */
    {0x46,0x49,0x49,0x49,0x31}, /* S */
    {0x01,0x01,0x7F,0x01,0x01}, /* T */
    {0x3F,0x40,0x40,0x40,0x3F}, /* U */
    {0x1F,0x20,0x40,0x20,0x1F}, /* V */
    {0x3F,0x40,0x38,0x40,0x3F}, /* W */
    {0x63,0x14,0x08,0x14,0x63}, /* X */
    {0x07,0x08,0x70,0x08,0x07}, /* Y */
    {0x61,0x51,0x49,0x45,0x43}, /* Z */
    {0x00,0x7F,0x41,0x41,0x00}, /* [ */
    {0x02,0x04,0x08,0x10,0x20}, /* \ */
    {0x00,0x41,0x41,0x7F,0x00}, /* ] */
    {0x04,0x02,0x01,0x02,0x04}, /* ^ */
    {0x40,0x40,0x40,0x40,0x40}, /* _ */
    {0x00,0x01,0x02,0x04,0x00}, /* ` */
    {0x20,0x54,0x54,0x54,0x78}, /* a */
    {0x7F,0x48,0x44,0x44,0x38}, /* b */
    {0x38,0x44,0x44,0x44,0x20}, /* c */
    {0x38,0x44,0x44,0x48,0x7F}, /* d */
    {0x38,0x54,0x54,0x54,0x18}, /* e */
    {0x08,0x7E,0x09,0x01,0x02}, /* f */
    {0x0C,0x52,0x52,0x52,0x3E}, /* g */
    {0x7F,0x08,0x04,0x04,0x78}, /* h */
    {0x00,0x44,0x7D,0x40,0x00}, /* i */
    {0x20,0x40,0x44,0x3D,0x00}, /* j */
    {0x7F,0x10,0x28,0x44,0x00}, /* k */
    {0x00,0x41,0x7F,0x40,0x00}, /* l */
    {0x7C,0x04,0x18,0x04,0x78}, /* m */
    {0x7C,0x08,0x04,0x04,0x78}, /* n */
    {0x38,0x44,0x44,0x44,0x38}, /* o */
    {0x7C,0x14,0x14,0x14,0x08}, /* p */
    {0x08,0x14,0x14,0x18,0x7C}, /* q */
    {0x7C,0x08,0x04,0x04,0x08}, /* r */
    {0x48,0x54,0x54,0x54,0x20}, /* s */
    {0x04,0x3F,0x44,0x40,0x20}, /* t */
    {0x3C,0x40,0x40,0x20,0x7C}, /* u */
    {0x1C,0x20,0x40,0x20,0x1C}, /* v */
    {0x3C,0x40,0x30,0x40,0x3C}, /* w */
    {0x44,0x28,0x10,0x28,0x44}, /* x */
    {0x0C,0x50,0x50,0x50,0x3C}, /* y */
    {0x44,0x64,0x54,0x4C,0x44}, /* z */
    {0x00,0x08,0x36,0x41,0x00}, /* { */
    {0x00,0x00,0x7F,0x00,0x00}, /* | */
    {0x00,0x41,0x36,0x08,0x00}, /* } */
    {0x08,0x08,0x2A,0x1C,0x08}, /* ~ */
};

esp_err_t gc9a01_draw_text(int x, int y, const char *text, uint16_t color, uint16_t bg)
{
    int cx = x;
    for (const char *p = text; *p; p++) {
        if (*p < 0x20 || *p > 0x7E) continue;
        const uint8_t *g = FONT5X7[*p - 0x20];

        /* Draw the 5x7 glyph column by column */
        for (int col = 0; col < 5; col++) {
            uint8_t bits = g[col];
            for (int row = 0; row < 7; row++) {
                uint16_t c = (bits & (1 << row)) ? color : bg;
                gc9a01_draw_pixel(cx + col, y + row, c);
            }
        }
        cx += 6;   /* 5 columns + 1 pixel gap */
    }
    return ESP_OK;
}
'@

Write-Host "  + components\gc9a01\gc9a01.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 9 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\gc9a01\CMakeLists.txt"
Write-Host "  - components\gc9a01\gc9a01.h"
Write-Host "  - components\gc9a01\gc9a01.c"
Write-Host ""