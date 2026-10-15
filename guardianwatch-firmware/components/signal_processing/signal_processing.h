#pragma once

#include <stdint.h>
#include "esp_err.h"
#include "max30101.h"
#include "lis2dw12.h"
#include "data_manager.h"

esp_err_t signal_processing_init(void);

/* Called once per second by the processing task. Recomputes HR, SpO2,
 * motion RMS, and quality from the rolling buffers. */
void signal_processing_tick(void);

/* Push raw samples into the rolling buffers. Called from the sensor task. */
void signal_processing_push_ppg(const max30101_sample_t *s);
void signal_processing_push_motion(const lis2dw12_sample_t *s);
void signal_processing_push_temp(float t);

/* Fill in a telemetry packet with the latest computed values. */
esp_err_t signal_processing_get_telemetry(telemetry_packet_t *out);