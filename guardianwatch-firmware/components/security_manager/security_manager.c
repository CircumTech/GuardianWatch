#include "security_manager.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "mbedtls/md.h"
#include <string.h>

static const char *TAG = "security";

/* NVS namespace / key */
#define NVS_NAMESPACE     "gw"
#define NVS_KEY_SECRET    "device_secret"

#define SECRET_LEN        32

/* Development fallback secret. Used only when the device hasn't been
 * provisioned. All dev boards share this ??? production MUST overwrite. */
static const uint8_t DEV_SECRET[SECRET_LEN] = {
    0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A,
    0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A,
    0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A,
    0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A,
};

static uint8_t s_secret[SECRET_LEN];
static bool    s_provisioned = false;

/* ------------------------------------------------------------------ */

esp_err_t security_manager_init(void)
{
    memset(s_secret, 0, sizeof(s_secret));
    s_provisioned = false;

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);

    if (err == ESP_ERR_NVS_NOT_FOUND) {
        /* Namespace doesn't exist yet ??? dev fallback */
        ESP_LOGW(TAG, "NVS namespace missing ??? using dev secret");
        memcpy(s_secret, DEV_SECRET, SECRET_LEN);
        return ESP_OK;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        memcpy(s_secret, DEV_SECRET, SECRET_LEN);
        return ESP_OK;   /* keep booting; auth will fail closed */
    }

    size_t len = SECRET_LEN;
    err = nvs_get_blob(nvs, NVS_KEY_SECRET, s_secret, &len);
    nvs_close(nvs);

    if (err == ESP_OK && len == SECRET_LEN) {
        s_provisioned = true;
        ESP_LOGI(TAG, "Device secret loaded (provisioned)");
    } else {
        ESP_LOGW(TAG, "Not provisioned ??? using dev secret");
        memcpy(s_secret, DEV_SECRET, SECRET_LEN);
    }
    return ESP_OK;
}

/* ------------------------------------------------------------------ */

esp_err_t security_compute_response(const uint8_t *nonce,
                                    size_t         nonce_len,
                                    uint8_t       *out,
                                    size_t        *out_len)
{
    if (!nonce || !out || !out_len || nonce_len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!md) {
        ESP_LOGE(TAG, "SHA256 not available");
        return ESP_FAIL;
    }

    int rc = mbedtls_md_hmac(md,
                             s_secret, SECRET_LEN,
                             nonce,    nonce_len,
                             out);
    if (rc != 0) {
        ESP_LOGE(TAG, "mbedtls_md_hmac failed: -0x%04X", -rc);
        return ESP_FAIL;
    }

    *out_len = 32;
    return ESP_OK;
}

/* ------------------------------------------------------------------ */

bool security_is_provisioned(void)
{
    return s_provisioned;
}

/* ------------------------------------------------------------------ */

esp_err_t security_set_device_secret(const uint8_t secret[32])
{
    if (!secret) return ESP_ERR_INVALID_ARG;

    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs),
                        TAG, "nvs_open");

    esp_err_t err = nvs_set_blob(nvs, NVS_KEY_SECRET, secret, SECRET_LEN);
    if (err == ESP_OK) err = nvs_commit(nvs);
    nvs_close(nvs);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to store secret: %s", esp_err_to_name(err));
        return err;
    }

    memcpy(s_secret, secret, SECRET_LEN);
    s_provisioned = true;
    ESP_LOGI(TAG, "Device secret provisioned");
    return ESP_OK;
}