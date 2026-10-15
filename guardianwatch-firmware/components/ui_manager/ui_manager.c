#include "ui_manager.h"
#include "gc9a01.h"
#include "power_manager.h"
#include "esp_log.h"
#include <stdio.h>

static const char *TAG = "ui";

/* Palette */
#define COL_BG       GC9A01_BLACK
#define COL_FG       GC9A01_WHITE
#define COL_ACCENT   GC9A01_GREEN
#define COL_WARN     GC9A01_RED
#define COL_DIM      GC9A01_GRAY

/* Layout */
#define CENTER_X     120
#define TITLE_Y      100
#define SUBTITLE_Y   125

/* Backlight presets (%) */
#define BL_BOOT       30
#define BL_IDLE       20
#define BL_CONNECTED  30
#define BL_SESSION    50
#define BL_WARN       50

/* ------------------------------------------------------------------ */

esp_err_t ui_manager_init(void)
{
    ESP_LOGI(TAG, "UI init");
    return ESP_OK;
}

/* ------------------------------------------------------------------ */
/* Status screens                                                      */
/* ------------------------------------------------------------------ */

void ui_manager_show_boot(void)
{
    gc9a01_fill(COL_BG);
    /* "GUARDIAN" is 8 chars ?? 6 px = 48 px wide */
    gc9a01_draw_text(CENTER_X - 24, TITLE_Y,    "GUARDIAN", COL_FG,     COL_BG);
    gc9a01_draw_text(CENTER_X - 15, SUBTITLE_Y, "WATCH",    COL_ACCENT, COL_BG);
    gc9a01_set_backlight(BL_BOOT);
}

void ui_manager_show_idle(void)
{
    gc9a01_fill(COL_BG);
    gc9a01_draw_text(CENTER_X - 12, TITLE_Y, "IDLE", COL_DIM, COL_BG);
    gc9a01_set_backlight(BL_IDLE);
}

void ui_manager_show_connected(void)
{
    gc9a01_fill(COL_BG);
    gc9a01_draw_text(CENTER_X - 27, TITLE_Y, "CONNECTED", COL_ACCENT, COL_BG);
    gc9a01_set_backlight(BL_CONNECTED);
}

void ui_manager_show_session(void)
{
    gc9a01_fill(COL_BG);
    gc9a01_draw_text(CENTER_X - 21, TITLE_Y, "SESSION", COL_FG, COL_BG);
    gc9a01_set_backlight(BL_SESSION);
}

void ui_manager_show_low_battery(void)
{
    gc9a01_fill(COL_BG);
    gc9a01_draw_text(CENTER_X - 33, TITLE_Y, "LOW BATTERY", COL_WARN, COL_BG);
    gc9a01_set_backlight(BL_WARN);
}

void ui_manager_show_fault(void)
{
    gc9a01_fill(COL_BG);
    gc9a01_draw_text(CENTER_X - 15, TITLE_Y, "FAULT", COL_WARN, COL_BG);
    gc9a01_set_backlight(BL_WARN);
}

/* ------------------------------------------------------------------ */
/* Live values dashboard                                               */
/* ------------------------------------------------------------------ */

void ui_manager_update(float hr, float spo2, float temp, int battery)
{
    char line[24];

    /* Clear screen each update; a proper implementation would only
     * redraw changed rows to avoid flicker, but for bring-up this is
     * fine and keeps the code obvious. */
    gc9a01_fill(COL_BG);

    /* Column layout: labels on the left, values on the right */
    int label_x = 40;
    int value_x = 130;

    /* Row 1: Heart rate */
    gc9a01_draw_text(label_x, 60, "HR", COL_DIM, COL_BG);
    if (hr > 0.5f) {
        snprintf(line, sizeof(line), "%d", (int)hr);
    } else {
        snprintf(line, sizeof(line), "--");
    }
    gc9a01_draw_text(value_x, 60, line, COL_FG, COL_BG);

    /* Row 2: SpO2 */
    gc9a01_draw_text(label_x, 85, "SpO2", COL_DIM, COL_BG);
    if (spo2 > 0.5f) {
        snprintf(line, sizeof(line), "%d", (int)spo2);
    } else {
        snprintf(line, sizeof(line), "--");
    }
    gc9a01_draw_text(value_x, 85, line, COL_FG, COL_BG);

    /* Row 3: Temperature */
    gc9a01_draw_text(label_x, 110, "TEMP", COL_DIM, COL_BG);
    if (temp > 0.5f) {
        snprintf(line, sizeof(line), "%.1f", temp);
    } else {
        snprintf(line, sizeof(line), "--");
    }
    gc9a01_draw_text(value_x, 110, line, COL_FG, COL_BG);

    /* Row 4: Battery */
    gc9a01_draw_text(label_x, 135, "BAT", COL_DIM, COL_BG);
    if (battery >= 0) {
        snprintf(line, sizeof(line), "%d%%", battery);
        /* Warn color when low */
        gc9a01_draw_text(value_x, 135, line,
                         (battery <= 20) ? COL_WARN : COL_ACCENT, COL_BG);
    } else {
        gc9a01_draw_text(value_x, 135, "--", COL_FG, COL_BG);
    }
}