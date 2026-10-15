#pragma once

#include "esp_err.h"

/* Initialize the UI subsystem (currently a no-op besides logging). */
esp_err_t ui_manager_init(void);

/* --- Screen selectors --- */

void ui_manager_show_boot(void);
void ui_manager_show_idle(void);
void ui_manager_show_connected(void);
void ui_manager_show_session(void);
void ui_manager_show_low_battery(void);
void ui_manager_show_fault(void);

/* --- Live values dashboard ---
 *
 * hr      : heart rate in bpm (0 if unavailable)
 * spo2    : SpO2 in percent  (0 if unavailable)
 * temp    : skin temperature in Celsius
 * battery : battery percent  (0-100)
 */
void ui_manager_update(float hr, float spo2, float temp, int battery);