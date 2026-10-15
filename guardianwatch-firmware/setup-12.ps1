# =====================================================================
#  Guardian Watch Firmware - Step 12
#  Creates:
#    components/signal_processing/  (HR, SpO2, motion RMS, telemetry fill)
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "=== Step 12: Signal Processing ===" -ForegroundColor Cyan
Write-Host ""

function W($path, $content) {
    Set-Content -Path (Join-Path $root $path) -Value $content -Encoding ASCII -NoNewline
}

# --- components/signal_processing/CMakeLists.txt ---
W "components\signal_processing\CMakeLists.txt" @'
idf_component_register(SRCS "signal_processing.c"
                       INCLUDE_DIRS "."
                       REQUIRES signal_quality max30101 lis2dw12 data_manager esp_timer)
'@

Write-Host "  + components\signal_processing\CMakeLists.txt" -ForegroundColor Green

# --- components/signal_processing/signal_processing.h ---
W "components\signal_processing\signal_processing.h" @'
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
'@

Write-Host "  + components\signal_processing\signal_processing.h" -ForegroundColor Green

# --- components/signal_processing/signal_processing.c ---
W "components\signal_processing\signal_processing.c" @'
#include "signal_processing.h"
#include "signal_quality.h"
#include "esp_log.h"
#include "esp_timer.h"
#include <math.h>
#include <string.h>

static const char *TAG = "sigproc";

/* ------------------------------------------------------------------
 * Rolling buffers
 * ------------------------------------------------------------------ */
#define PPG_WIN_SIZE   256     /* ~5 s at 50 Hz */
#define MOT_WIN_SIZE    64     /* ~1.3 s at 50 Hz */

static uint32_t s_red[PPG_WIN_SIZE];
static uint32_t s_ir [PPG_WIN_SIZE];
static int      s_ppg_idx   = 0;
static int      s_ppg_count = 0;

static float    s_motion[MOT_WIN_SIZE];
static int      s_mot_idx   = 0;
static int      s_mot_count = 0;

/* ------------------------------------------------------------------
 * Latest computed values
 * ------------------------------------------------------------------ */
static float    s_hr_bpm        = 0.0f;
static float    s_spo2          = 0.0f;
static float    s_temp_c        = 0.0f;
static float    s_motion_rms    = 0.0f;
static uint8_t  s_quality_score = 0;
static uint16_t s_quality_flags = 0;

/* ------------------------------------------------------------------
 * Peak detection tuning
 * ------------------------------------------------------------------ */
#define HR_MIN_BPM      30.0f
#define HR_MAX_BPM      220.0f
#define PPG_SAMPLE_HZ   50.0f

/* SpO2 placeholder calibration. MUST be replaced with a validated
 * curve before any customer-facing number is shown. */
#define SPO2_CAL_A      110.0f
#define SPO2_CAL_B     (-25.0f)
#define SPO2_MIN        70.0f
#define SPO2_MAX       100.0f

/* ------------------------------------------------------------------ */

esp_err_t signal_processing_init(void)
{
    memset(s_red,    0, sizeof(s_red));
    memset(s_ir,     0, sizeof(s_ir));
    memset(s_motion, 0, sizeof(s_motion));
    s_ppg_idx = s_ppg_count = 0;
    s_mot_idx = s_mot_count = 0;
    ESP_LOGI(TAG, "Signal processing init");
    return ESP_OK;
}

/* ------------------------------------------------------------------ */

void signal_processing_push_ppg(const max30101_sample_t *s)
{
    if (!s) return;
    s_red[s_ppg_idx] = s->red;
    s_ir [s_ppg_idx] = s->ir;
    s_ppg_idx = (s_ppg_idx + 1) % PPG_WIN_SIZE;
    if (s_ppg_count < PPG_WIN_SIZE) s_ppg_count++;
}

void signal_processing_push_motion(const lis2dw12_sample_t *s)
{
    if (!s) return;
    /* Magnitude of acceleration minus gravity (~1 g at rest) */
    float mag = sqrtf(s->ax * s->ax + s->ay * s->ay + s->az * s->az) - 1.0f;
    s_motion[s_mot_idx] = mag;
    s_mot_idx = (s_mot_idx + 1) % MOT_WIN_SIZE;
    if (s_mot_count < MOT_WIN_SIZE) s_mot_count++;
}

void signal_processing_push_temp(float t)
{
    s_temp_c = t;
}

/* ------------------------------------------------------------------
 * Motion RMS — magnitude RMS of the last MOT_WIN_SIZE samples
 * ------------------------------------------------------------------ */
static float compute_motion_rms(void)
{
    if (s_mot_count == 0) return 0.0f;
    float sum = 0.0f;
    for (int i = 0; i < s_mot_count; i++) {
        sum += s_motion[i] * s_motion[i];
    }
    return sqrtf(sum / (float)s_mot_count);
}

/* ------------------------------------------------------------------
 * Heart rate estimation via simple peak detection on the IR channel.
 *
 * This is a baseline detector for bring-up. Production will replace it
 * with an adaptive threshold + IBI plausibility gate, verified against
 * an annotated reference dataset.
 * ------------------------------------------------------------------ */
static float estimate_hr(void)
{
    if (s_ppg_count < PPG_WIN_SIZE) return 0.0f;

    /* Detrend: subtract mean of the IR channel */
    float mean = 0.0f;
    for (int i = 0; i < PPG_WIN_SIZE; i++) mean += (float)s_ir[i];
    mean /= (float)PPG_WIN_SIZE;

    /* Count local maxima above the mean */
    int peaks      = 0;
    int first_peak = 0;
    int last_peak  = 0;

    for (int i = 1; i < PPG_WIN_SIZE - 1; i++) {
        float prev = (float)s_ir[i - 1] - mean;
        float cur  = (float)s_ir[i]     - mean;
        float next = (float)s_ir[i + 1] - mean;

        if (cur > prev && cur > next && cur > 0.0f) {
            if (peaks == 0) first_peak = i;
            last_peak = i;
            peaks++;
        }
    }

    if (peaks < 2) return 0.0f;

    float duration_s = (float)(last_peak - first_peak) / PPG_SAMPLE_HZ;
    if (duration_s <= 0.0f) return 0.0f;

    float hr_bpm = 60.0f * (float)(peaks - 1) / duration_s;
    if (hr_bpm < HR_MIN_BPM || hr_bpm > HR_MAX_BPM) return 0.0f;

    return hr_bpm;
}

/* ------------------------------------------------------------------
 * SpO2 estimation via ratio-of-ratios:
 *   R = (AC_red / DC_red) / (AC_ir / DC_ir)
 *   SpO2 = A * R + B   (placeholder — replace with validated curve)
 * ------------------------------------------------------------------ */
static float estimate_spo2(void)
{
    if (s_ppg_count < PPG_WIN_SIZE) return 0.0f;

    /* DC = mean of each channel */
    float red_dc = 0.0f, ir_dc = 0.0f;
    for (int i = 0; i < PPG_WIN_SIZE; i++) {
        red_dc += (float)s_red[i];
        ir_dc  += (float)s_ir[i];
    }
    red_dc /= (float)PPG_WIN_SIZE;
    ir_dc  /= (float)PPG_WIN_SIZE;

    /* AC = mean absolute deviation from DC */
    float red_ac = 0.0f, ir_ac = 0.0f;
    for (int i = 0; i < PPG_WIN_SIZE; i++) {
        red_ac += fabsf((float)s_red[i] - red_dc);
        ir_ac  += fabsf((float)s_ir[i]  - ir_dc);
    }
    red_ac /= (float)PPG_WIN_SIZE;
    ir_ac  /= (float)PPG_WIN_SIZE;

    /* Guard against divide-by-zero */
    if (red_dc < 1.0f || ir_dc < 1.0f || ir_ac < 1.0f) return 0.0f;

    float R = (red_ac / red_dc) / (ir_ac / ir_dc);
    float spo2 = SPO2_CAL_A + SPO2_CAL_B * R;

    if (spo2 < SPO2_MIN) spo2 = SPO2_MIN;
    if (spo2 > SPO2_MAX) spo2 = SPO2_MAX;
    return spo2;
}

/* ------------------------------------------------------------------
 * Tick — recompute everything once per second
 * ------------------------------------------------------------------ */
void signal_processing_tick(void)
{
    s_motion_rms = compute_motion_rms();

    /* Quality is evaluated on the current PPG window */
    uint32_t latest_red = s_red[s_ppg_idx];
    uint32_t latest_ir  = s_ir [s_ppg_idx];

    quality_report_t q = signal_quality_evaluate_ppg(latest_red,
                                                     latest_ir,
                                                     s_motion_rms,
                                                     s_temp_c);
    s_quality_flags = q.flags;
    s_quality_score = q.score;

    s_hr_bpm = estimate_hr();
    s_spo2   = estimate_spo2();
}

/* ------------------------------------------------------------------
 * Fill in the telemetry packet
 * ------------------------------------------------------------------ */
esp_err_t signal_processing_get_telemetry(telemetry_packet_t *out)
{
    if (!out) return ESP_ERR_INVALID_ARG;

    memset(out, 0, sizeof(*out));

    out->protocol_version = 0x01;
    data_manager_get_device_id(out->device_id);
    out->sequence         = data_manager_next_sequence();
    out->timestamp_ms     = (uint64_t)(esp_timer_get_time() / 1000);

    out->flags            = s_quality_flags;
    out->hr_bpm_x10       = (uint16_t)(s_hr_bpm * 10.0f);
    out->spo2_x10         = (uint16_t)(s_spo2   * 10.0f);
    out->temp_c_x100      = (uint16_t)(s_temp_c * 100.0f);
    out->motion_rms_x1000 = (uint16_t)(s_motion_rms * 1000.0f);
    out->quality_score    = s_quality_score;
    /* CRC is filled in by data_manager_push_telemetry() — leave zero here */
    out->crc16 = 0;

    return ESP_OK;
}
'@

Write-Host "  + components\signal_processing\signal_processing.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 12 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "  - components\signal_processing\CMakeLists.txt"
Write-Host "  - components\signal_processing\signal_processing.h"
Write-Host "  - components\signal_processing\signal_processing.c"
Write-Host ""