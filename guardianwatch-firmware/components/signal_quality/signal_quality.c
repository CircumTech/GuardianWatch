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