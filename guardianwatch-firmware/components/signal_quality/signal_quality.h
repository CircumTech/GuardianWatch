#pragma once

#include <stdint.h>
#include <stdbool.h>

/* Bit flags describing why a window is or isn't trustworthy */
#define QUALITY_OK                (1u << 0)   /* no issues detected */
#define QUALITY_MOTION_ARTIFACT   (1u << 1)   /* too much motion */
#define QUALITY_LOW_CONTACT       (1u << 2)   /* sensor not on skin properly */
#define QUALITY_LEAD_OFF          (1u << 3)   /* ECG electrode detached */
#define QUALITY_SATURATED         (1u << 4)   /* ADC/LED saturated */
#define QUALITY_LOW_AMPLITUDE     (1u << 5)   /* signal too weak */

typedef struct {
    uint16_t flags;        /* OR of QUALITY_* bits */
    uint8_t  score;        /* 0 (bad) .. 100 (perfect) */
    float    motion_rms;   /* RMS of acceleration magnitude, in g */
} quality_report_t;

void signal_quality_init(void);

/* Evaluate a PPG window.
 *   red, ir      : latest raw counts from MAX30101 (18-bit)
 *   motion_rms   : accelerometer magnitude RMS over the window, in g
 *   temp_c       : skin temperature, used as a crude contact proxy. Pass 0
 *                  if you don't want the contact heuristic applied. */
quality_report_t signal_quality_evaluate_ppg(uint32_t red,
                                             uint32_t ir,
                                             float    motion_rms,
                                             float    temp_c);

/* Evaluate an ECG sample / window.
 *   lead_off  : output of ad8232_lead_off()
 *   sample_mv : latest ADC reading in millivolts (unused for now, kept
 *               for future amplitude sanity checks)
 *   motion_rms: accelerometer magnitude RMS over the window, in g */
quality_report_t signal_quality_evaluate_ecg(bool     lead_off,
                                             int16_t  sample_mv,
                                             float    motion_rms);