#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

/* Initialize the security subsystem.
 * Loads the device secret from NVS. If not present, falls back to a
 * well-known development secret and logs a warning. Production units
 * must be provisioned before shipping. */
esp_err_t security_manager_init(void);

/* Compute the authentication response to a challenge nonce.
 *
 *   response = HMAC-SHA256(device_secret, nonce)
 *
 * out must be at least 32 bytes; out_len receives 32 on success. */
esp_err_t security_compute_response(const uint8_t *nonce,
                                    size_t         nonce_len,
                                    uint8_t       *out,
                                    size_t        *out_len);

/* Returns true if the device has a real provisioned secret (not the
 * development fallback). */
bool security_is_provisioned(void);

/* ------------------------------------------------------------------
 * Provisioning API (used by factory_mode over UART).
 * These write to NVS and commit immediately.
 * ------------------------------------------------------------------ */

esp_err_t security_set_device_secret(const uint8_t secret[32]);