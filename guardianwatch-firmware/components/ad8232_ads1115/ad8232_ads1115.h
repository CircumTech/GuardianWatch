#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Bring up the ADS1115 on the shared I2C bus.
 * AD8232 itself is a pure analog front end ??? no I2C. Its power is
 * gated by the caller via ad8232_power(). */
esp_err_t ad8232_ads1115_init(void);

/* Power the AD8232 analog front end on/off.
 * Only used during ECG sessions to save battery. */
esp_err_t ad8232_power(bool on);

/* Lead-off detection: returns true if either electrode is disconnected.
 * Reads the LOD+ / LOD- pins driven by the AD8232. */
bool ad8232_lead_off(void);

/* Start/stop continuous conversion on the ADS1115. */
esp_err_t ads1115_start_continuous(void);
esp_err_t ads1115_stop(void);

/* Read the latest conversion result in millivolts (differential, ??4.096 V). */
esp_err_t ads1115_read_sample(int16_t *millivolts);