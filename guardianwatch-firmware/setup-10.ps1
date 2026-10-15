# =====================================================================
#  Guardian Watch Firmware - Step 10
#  Creates:
#    components/signal_quality/   (PPG/ECG quality classification)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 10: Signal Quality ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/signal_quality/CMakeLists.txt ---
W "components\signal_quality\CMakeLists.txt" @'
idf_component_register(SRCS "signal_quality.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_timer)
'@

Write-Host "  + components\signal_quality\CMakeLists.txt" -ForegroundColor Green

# --- components/signal_quality/signal_quality.h ---
W "components\signal_quality\signal_quality.h" @'
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
'@

Write-Host "  + components\signal_quality\signal_quality.h" -ForegroundColor Green

# --- components/signal_quality/signal_quality.c ---
W "components\signal_quality\signal_quality.c" @'
#include "signal_quality.h"

/* ------------------------------------------------------------------
 * Thresholds
 *
 * These are engineering starting points. They should be tuned against
 * real recordings on real users and locked in the V&V plan.
 * ------------------------------------------------------------------ */
#define MOTION_THRESHOLD      0.15f    /* g RMS */
#define SATURATION_HIGH       260000u  /* 18-bit MAX30101 counts */
#define SATURATION_LOW        100u
#define LOW_CONTACT_TEMP_C    20.0f    /* plausible lower bound of wrist skin temp */
#define LOW_CONTACT_TEMP_MAX  42.0f    /* plausible upper bound */

/* Deductions applied to the score for each flagged issue */
#define SCORE_MOTION          -40
#define SCORE_SATURATED       -30
#define SCORE_LOW_CONTACT     -20
#define SCORE_LOW_AMPLITUDE   -25
#define SCORE_LEAD_OFF        -60

/* ------------------------------------------------------------------ */

void signal_quality_init(void)
{
    /* Reserved for future calibration / hysteresis state */
}

/* ------------------------------------------------------------------ */

quality_report_t signal_quality_evaluate_ppg(uint32_t red,
                                             uint32_t ir,
                                             float    motion_rms,
                                             float    temp_c)
{
    quality_report_t r = { .flags = 0, .score = 100, .motion_rms = motion_rms };

    /* Saturation on either channel is a hard failure of the optical path */
    if (red >= SATURATION_HIGH || ir >= SATURATION_HIGH ||
        red <= SATURATION_LOW  || ir <= SATURATION_LOW) {
        r.flags |= QUALITY_SATURATED;
    }

    /* Motion artifact */
    if (motion_rms > MOTION_THRESHOLD) {
        r.flags |= QUALITY_MOTION_ARTIFACT;
    }

    /* Crude contact check via skin temperature. A wrist without a
     * properly seated sensor reads close to ambient. */
    if (temp_c > 0.0f) {
        if (temp_c < LOW_CONTACT_TEMP_C || temp_c > LOW_CONTACT_TEMP_MAX) {
            r.flags |= QUALITY_LOW_CONTACT;
        }
    }

    /* If nothing is flagged, mark as OK */
    if (r.flags == 0) r.flags = QUALITY_OK;

    /* Score: start at 100, subtract for each problem */
    int score = 100;
    if (r.flags & QUALITY_MOTION_ARTIFACT) score += SCORE_MOTION;
    if (r.flags & QUALITY_SATURATED)       score += SCORE_SATURATED;
    if (r.flags & QUALITY_LOW_CONTACT)     score += SCORE_LOW_CONTACT;

    r.score = (score < 0)   ? 0   :
              (score > 100) ? 100 :
                              (uint8_t)score;
    return r;
}

/* ------------------------------------------------------------------ */

quality_report_t signal_quality_evaluate_ecg(bool     lead_off,
                                             int16_t  sample_mv,
                                             float    motion_rms)
{
    quality_report_t r = { .flags = 0, .score = 100, .motion_rms = motion_rms };

    (void)sample_mv;   /* reserved for future amplitude sanity checks */

    if (lead_off) {
        r.flags |= QUALITY_LEAD_OFF;
    }

    if (motion_rms > MOTION_THRESHOLD) {
        r.flags |= QUALITY_MOTION_ARTIFACT;
    }

    if (r.flags == 0) r.flags = QUALITY_OK;

    int score = 100;
    if (r.flags & QUALITY_LEAD_OFF)        score += SCORE_LEAD_OFF;
    if (r.flags & QUALITY_MOTION_ARTIFACT) score += SCORE_MOTION;

    r.score = (score < 0)   ? 0   :
              (score > 100) ? 100 :
                              (uint8_t)score;
    return r;
}
'@

Write-Host "  + components\signal_quality\signal_quality.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 10 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\signal_quality\CMakeLists.txt"
Write-Host "  - components\signal_quality\signal_quality.h"
Write-Host "  - components\signal_quality\signal_quality.c"
Write-Host ""