# =====================================================================
#  Guardian Watch Firmware - Step 15
#  Creates:
#    components/ble_manager/ble_manager.c  (full GATT server)
#  Assumes ble_manager.h and CMakeLists.txt already exist from step 2.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = "C:\Users\Circum\Documents\Projects\GuardianWatch\guardianwatch-firmware"

if (-not (Test-Path $root)) {
    Write-Host "ERROR: Project root not found: $root" -ForegroundColor Red
    Write-Host "Run setup-1.ps1 first." -ForegroundColor Yellow
    exit 1
}

$hdr = Join-Path $root "components\ble_manager\ble_manager.h"
if (-not (Test-Path $hdr)) {
    Write-Host "ERROR: ble_manager.h missing. Run setup-2e.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Step 15: BLE Manager (full GATT) ===" -ForegroundColor Cyan
Write-Host ""

$target = Join-Path $root "components\ble_manager\ble_manager.c"

$content = @'
/*
 * Guardian Watch BLE Manager — complete GATT server.
 *
 * Services:
 *   Device    : Device ID (Read), Challenge (Write), Response (Indicate)
 *   Telemetry : Vitals packet (Notify)
 *   PPG       : Raw PPG blocks (Notify)
 *   ECG       : Raw ECG blocks (Notify)
 *   Sync      : Record metadata (Read/Write)
 *   Status    : Standard Battery Service (0x180F)
 *   Control   : Session commands + auth confirm (Write)
 *
 * Security:
 *   - Challenge/response HMAC-SHA256 via security_manager
 *   - Trusted notifications gated on s_authed
 *   - LESC bonding requested at connect
 */

#include "ble_manager.h"
#include "security_manager.h"
#include "data_manager.h"
#include "power_manager.h"

#include "esp_log.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatt_defs.h"
#include "esp_timer.h"

#include <string.h>

static const char *TAG = "ble";

/* ------------------------------------------------------------------
 * UUIDs
 *
 * Custom 128-bit UUIDs share base 0000xxxx-0000-1000-8000-00805F9B34FB.
 * The "xxxx" is encoded little-endian in the first two bytes.
 * ------------------------------------------------------------------ */

#define UUID_SVC_DEVICE   0x00A0
#define UUID_SVC_TELEM    0x00A1
#define UUID_SVC_PPG      0x00A2
#define UUID_SVC_ECG      0x00A3
#define UUID_SVC_SYNC     0x00A4
#define UUID_SVC_STATUS   0x00A5
#define UUID_SVC_CONTROL  0x00A6

#define UUID_CHR_DEV_ID   0x00B0
#define UUID_CHR_CHALL    0x00B1
#define UUID_CHR_RESP     0x00B2
#define UUID_CHR_VITALS   0x00B3
#define UUID_CHR_PPG      0x00B4
#define UUID_CHR_ECG      0x00B5
#define UUID_CHR_SYNC     0x00B6
#define UUID_CHR_CTRL     0x00B8

#define UUID_SVC_BATTERY        0x180F
#define UUID_CHR_BATTERY_LEVEL  0x2A19
#define UUID_DESC_CCCD          0x2902

#define GW_UUID128(x) { \
    0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80, \
    0x00, 0x10, 0x00, 0x00, \
    (uint8_t)((x) & 0xFF), (uint8_t)(((x) >> 8) & 0xFF), \
    0x00, 0x00 }

#define GW_UUID16(x) { (uint8_t)((x) & 0xFF), (uint8_t)(((x) >> 8) & 0xFF) }

static const uint8_t s_svc_device_uuid[16]  = GW_UUID128(UUID_SVC_DEVICE);
static const uint8_t s_svc_telem_uuid[16]   = GW_UUID128(UUID_SVC_TELEM);
static const uint8_t s_svc_ppg_uuid[16]     = GW_UUID128(UUID_SVC_PPG);
static const uint8_t s_svc_ecg_uuid[16]     = GW_UUID128(UUID_SVC_ECG);
static const uint8_t s_svc_sync_uuid[16]    = GW_UUID128(UUID_SVC_SYNC);
static const uint8_t s_svc_status_uuid[16]  = GW_UUID128(UUID_SVC_STATUS);
static const uint8_t s_svc_control_uuid[16] = GW_UUID128(UUID_SVC_CONTROL);
static const uint8_t s_svc_battery_uuid[2]  = GW_UUID16(UUID_SVC_BATTERY);

static const uint8_t s_chr_dev_id_uuid[16]  = GW_UUID128(UUID_CHR_DEV_ID);
static const uint8_t s_chr_chall_uuid[16]   = GW_UUID128(UUID_CHR_CHALL);
static const uint8_t s_chr_resp_uuid[16]    = GW_UUID128(UUID_CHR_RESP);
static const uint8_t s_chr_vitals_uuid[16]  = GW_UUID128(UUID_CHR_VITALS);
static const uint8_t s_chr_ppg_uuid[16]     = GW_UUID128(UUID_CHR_PPG);
static const uint8_t s_chr_ecg_uuid[16]     = GW_UUID128(UUID_CHR_ECG);
static const uint8_t s_chr_sync_uuid[16]    = GW_UUID128(UUID_CHR_SYNC);
static const uint8_t s_chr_ctrl_uuid[16]    = GW_UUID128(UUID_CHR_CTRL);
static const uint8_t s_chr_batt_lvl_uuid[2] = GW_UUID16(UUID_CHR_BATTERY_LEVEL);
static const uint8_t s_desc_cccd_uuid[2]    = GW_UUID16(UUID_DESC_CCCD);

/* ------------------------------------------------------------------
 * Attribute table indices
 * ------------------------------------------------------------------ */
enum {
    IDX_SVC_DEVICE = 0,
    IDX_CHAR_DEV_ID,
    IDX_CHAR_DEV_ID_VAL,
    IDX_CHAR_CHALL,
    IDX_CHAR_CHALL_VAL,
    IDX_CHAR_RESP,
    IDX_CHAR_RESP_VAL,
    IDX_CHAR_RESP_CFG,

    IDX_SVC_TELEM,
    IDX_CHAR_VITALS,
    IDX_CHAR_VITALS_VAL,
    IDX_CHAR_VITALS_CFG,

    IDX_SVC_PPG,
    IDX_CHAR_PPG,
    IDX_CHAR_PPG_VAL,
    IDX_CHAR_PPG_CFG,

    IDX_SVC_ECG,
    IDX_CHAR_ECG,
    IDX_CHAR_ECG_VAL,
    IDX_CHAR_ECG_CFG,

    IDX_SVC_SYNC,
    IDX_CHAR_SYNC,
    IDX_CHAR_SYNC_VAL,

    IDX_SVC_STATUS,
    IDX_CHAR_BATT_LVL,
    IDX_CHAR_BATT_LVL_VAL,
    IDX_CHAR_BATT_LVL_CFG,

    IDX_SVC_CONTROL,
    IDX_CHAR_CTRL,
    IDX_CHAR_CTRL_VAL,

    IDX_NB,
};

/* Static storage for read attributes */
static uint8_t s_dev_id_value[8] = {0};
static uint8_t s_resp_value[32]  = {0};
static uint8_t s_sync_value[16]  = {0};
static uint8_t s_batt_value[1]   = {100};

/* ------------------------------------------------------------------
 * GATT attribute table
 * ------------------------------------------------------------------ */
static const esp_gatts_attr_db_t s_gatt_db[IDX_NB] = {

    /* ---------- Device Service ---------- */
    [IDX_SVC_DEVICE] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_device_uuid), sizeof(s_svc_device_uuid),
         (uint8_t *)s_svc_device_uuid}
    },
    [IDX_CHAR_DEV_ID] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_READ}}
    },
    [IDX_CHAR_DEV_ID_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_dev_id_uuid,
         ESP_GATT_PERM_READ, sizeof(s_dev_id_value), sizeof(s_dev_id_value),
         s_dev_id_value}
    },
    [IDX_CHAR_CHALL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_WRITE}}
    },
    [IDX_CHAR_CHALL_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_chall_uuid,
         ESP_GATT_PERM_WRITE, 16, 0, NULL}
    },
    [IDX_CHAR_RESP] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_INDICATE}}
    },
    [IDX_CHAR_RESP_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_resp_uuid,
         ESP_GATT_PERM_READ, sizeof(s_resp_value), 0, s_resp_value}
    },
    [IDX_CHAR_RESP_CFG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_desc_cccd_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2,
         (uint8_t *)&(uint16_t){0}}
    },

    /* ---------- Telemetry Service ---------- */
    [IDX_SVC_TELEM] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_telem_uuid), sizeof(s_svc_telem_uuid),
         (uint8_t *)s_svc_telem_uuid}
    },
    [IDX_CHAR_VITALS] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_NOTIFY}}
    },
    [IDX_CHAR_VITALS_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_vitals_uuid,
         ESP_GATT_PERM_READ, sizeof(telemetry_packet_t), 0, NULL}
    },
    [IDX_CHAR_VITALS_CFG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_desc_cccd_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2,
         (uint8_t *)&(uint16_t){0}}
    },

    /* ---------- PPG Service ---------- */
    [IDX_SVC_PPG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_ppg_uuid), sizeof(s_svc_ppg_uuid),
         (uint8_t *)s_svc_ppg_uuid}
    },
    [IDX_CHAR_PPG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_NOTIFY}}
    },
    [IDX_CHAR_PPG_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_ppg_uuid,
         ESP_GATT_PERM_READ, 128, 0, NULL}
    },
    [IDX_CHAR_PPG_CFG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_desc_cccd_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2,
         (uint8_t *)&(uint16_t){0}}
    },

    /* ---------- ECG Service ---------- */
    [IDX_SVC_ECG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_ecg_uuid), sizeof(s_svc_ecg_uuid),
         (uint8_t *)s_svc_ecg_uuid}
    },
    [IDX_CHAR_ECG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_NOTIFY}}
    },
    [IDX_CHAR_ECG_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_ecg_uuid,
         ESP_GATT_PERM_READ, 512, 0, NULL}
    },
    [IDX_CHAR_ECG_CFG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_desc_cccd_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2,
         (uint8_t *)&(uint16_t){0}}
    },

    /* ---------- Sync Service ---------- */
    [IDX_SVC_SYNC] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_sync_uuid), sizeof(s_svc_sync_uuid),
         (uint8_t *)s_svc_sync_uuid}
    },
    [IDX_CHAR_SYNC] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_WRITE}}
    },
    [IDX_CHAR_SYNC_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_sync_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, sizeof(s_sync_value),
         sizeof(s_sync_value), s_sync_value}
    },

    /* ---------- Status Service ---------- */
    [IDX_SVC_STATUS] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_battery_uuid), sizeof(s_svc_battery_uuid),
         (uint8_t *)s_svc_battery_uuid}
    },
    [IDX_CHAR_BATT_LVL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY}}
    },
    [IDX_CHAR_BATT_LVL_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_chr_batt_lvl_uuid,
         ESP_GATT_PERM_READ, 1, 1, s_batt_value}
    },
    [IDX_CHAR_BATT_LVL_CFG] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)s_desc_cccd_uuid,
         ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2,
         (uint8_t *)&(uint16_t){0}}
    },

    /* ---------- Control Service ---------- */
    [IDX_SVC_CONTROL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_PRI_SERVICE},
         ESP_GATT_PERM_READ, sizeof(s_svc_control_uuid), sizeof(s_svc_control_uuid),
         (uint8_t *)s_svc_control_uuid}
    },
    [IDX_CHAR_CTRL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_16, (uint8_t *)&(uint16_t){ESP_GATT_UUID_CHAR_DECLARE},
         ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
         (uint8_t *)&(uint8_t){ESP_GATT_CHAR_PROP_BIT_WRITE}}
    },
    [IDX_CHAR_CTRL_VAL] = {
        {ESP_GATT_AUTO_RSP},
        {ESP_UUID_LEN_128, (uint8_t *)s_chr_ctrl_uuid,
         ESP_GATT_PERM_WRITE, 64, 0, NULL}
    },
};

/* ------------------------------------------------------------------
 * Module state
 * ------------------------------------------------------------------ */
static uint16_t       s_handles[IDX_NB] = {0};
static esp_gatt_if_t  s_gatts_if = 0;
static uint16_t       s_conn_id  = 0;
static bool           s_connected = false;
static bool           s_authed    = false;
static ble_event_cb_t s_cb        = NULL;

static bool s_notify_vitals  = false;
static bool s_notify_ppg     = false;
static bool s_notify_ecg     = false;
static bool s_notify_batt    = false;

static uint8_t s_nonce[16] = {0};

/* Advertising payload */
static uint8_t adv_service_uuid[16] = {
    0xFB,0x34,0x9B,0x5F,0x80,0x00,0x00,0x80,
    0x00,0x10,0x00,0x00,0xA0,0x00,0x00,0x00,
};

static esp_ble_adv_params_t adv_params = {
    .adv_int_min       = 0x100,
    .adv_int_max       = 0x100,
    .adv_type          = ADV_TYPE_IND,
    .own_addr_type     = BLE_ADDR_TYPE_PUBLIC,
    .channel_map       = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

/* ------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------ */

static void load_device_id(void)
{
    data_manager_get_device_id(s_dev_id_value);
}

static void send_read_response(esp_gatt_if_t iface,
                               esp_ble_gatts_cb_param_t *param,
                               const uint8_t *val,
                               uint16_t len)
{
    esp_gatt_rsp_t rsp;
    memset(&rsp, 0, sizeof(rsp));
    rsp.attr_value.handle = param->read.handle;
    if (val && len) {
        if (len > sizeof(rsp.attr_value.value)) len = sizeof(rsp.attr_value.value);
        memcpy(rsp.attr_value.value, val, len);
        rsp.attr_value.len = len;
    }
    esp_ble_gatts_send_response(iface, param->read.conn_id,
                                param->read.trans_id, ESP_GATT_OK, &rsp);
}

/* ------------------------------------------------------------------
 * GAP event handler
 * ------------------------------------------------------------------ */
static void gap_event_handler(esp_gap_ble_cb_event_t event,
                              esp_ble_gap_cb_param_t *param)
{
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
        esp_ble_gap_start_advertising(&adv_params);
        break;

    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(TAG, "Adv start failed: 0x%02X", param->adv_start_cmpl.status);
        } else {
            ESP_LOGI(TAG, "Advertising started");
        }
        break;

    case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
        ESP_LOGI(TAG, "Advertising stopped");
        break;

    case ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT:
        ESP_LOGI(TAG, "Conn params updated: int=%d latency=%d timeout=%d",
                 param->update_conn_params.conn_int,
                 param->update_conn_params.latency,
                 param->update_conn_params.timeout);
        break;

    case ESP_GAP_BLE_SEC_REQ_EVT:
        esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true);
        break;

    case ESP_GAP_BLE_AUTH_CMPL_EVT:
        if (param->ble_security.auth_cmpl.success) {
            ESP_LOGI(TAG, "SMP auth OK (bonded=%d)",
                     param->ble_security.auth_cmpl.bonded);
        } else {
            ESP_LOGW(TAG, "SMP auth failed: 0x%02X",
                     param->ble_security.auth_cmpl.fail_reason);
        }
        break;

    default:
        break;
    }
}

/* ------------------------------------------------------------------
 * GATT read handler
 * ------------------------------------------------------------------ */
static void handle_read(esp_gatt_if_t iface, esp_ble_gatts_cb_param_t *param)
{
    uint16_t h = param->read.handle;

    if (h == s_handles[IDX_CHAR_DEV_ID_VAL]) {
        load_device_id();
        esp_ble_gatts_set_attr_value(h, sizeof(s_dev_id_value), s_dev_id_value);
        send_read_response(iface, param, s_dev_id_value, sizeof(s_dev_id_value));
        return;
    }

    if (h == s_handles[IDX_CHAR_RESP_VAL]) {
        send_read_response(iface, param, s_resp_value, sizeof(s_resp_value));
        return;
    }

    if (h == s_handles[IDX_CHAR_SYNC_VAL]) {
        send_read_response(iface, param, s_sync_value, sizeof(s_sync_value));
        return;
    }

    if (h == s_handles[IDX_CHAR_BATT_LVL_VAL]) {
        float soc = power_manager_soc();
        if (soc < 0.0f)   soc = 0.0f;
        if (soc > 100.0f) soc = 100.0f;
        s_batt_value[0] = (uint8_t)soc;
        esp_ble_gatts_set_attr_value(h, 1, s_batt_value);
        send_read_response(iface, param, s_batt_value, 1);
        return;
    }

    /* Unknown handle — reply with empty value */
    send_read_response(iface, param, NULL, 0);
}

/* ------------------------------------------------------------------
 * GATT write handler
 * ------------------------------------------------------------------ */
static void handle_write(esp_gatt_if_t iface, esp_ble_gatts_cb_param_t *param)
{
    uint16_t h = param->write.handle;
    uint16_t len = param->write.len;
    const uint8_t *val = param->write.value;

    /* --- Challenge: app writes 16-byte nonce --- */
    if (h == s_handles[IDX_CHAR_CHALL_VAL]) {
        if (len < 16) {
            ESP_LOGW(TAG, "Challenge too short (%d bytes)", len);
            esp_ble_gatts_send_response(iface, param->write.conn_id,
                                        param->write.trans_id,
                                        ESP_GATT_INVALID_ATTR_LEN, NULL);
            return;
        }
        memcpy(s_nonce, val, 16);
        ESP_LOGI(TAG, "Challenge received");

        size_t out_len = 0;
        if (security_compute_response(s_nonce, 16, s_resp_value, &out_len) != ESP_OK
            || out_len != 32) {
            ESP_LOGE(TAG, "HMAC failed");
            esp_ble_gatts_send_response(iface, param->write.conn_id,
                                        param->write.trans_id,
                                        ESP_GATT_FAILURE, NULL);
            return;
        }

        esp_ble_gatts_set_attr_value(s_handles[IDX_CHAR_RESP_VAL],
                                     sizeof(s_resp_value), s_resp_value);

        /* Send indication with the response if the client subscribed */
        if (s_handles[IDX_CHAR_RESP_CFG]) {
            esp_ble_gatts_send_indicate(iface, param->write.conn_id,
                                        s_handles[IDX_CHAR_RESP_VAL],
                                        sizeof(s_resp_value),
                                        s_resp_value, false);
        }
        ESP_LOGI(TAG, "Challenge response sent");
        return;
    }

    /* --- Control: session commands + auth confirm --- */
    if (h == s_handles[IDX_CHAR_CTRL_VAL]) {
        if (len < 1) return;
        uint8_t cmd = val[0];
        ESP_LOGI(TAG, "Control cmd 0x%02X", cmd);

        switch (cmd) {
        case 0x01:  /* AUTH_CONFIRM: app echoes back the response bytes */
            if (len >= 33 && memcmp(s_resp_value, val + 1, 32) == 0) {
                s_authed = true;
                ESP_LOGI(TAG, "Client authenticated");
                if (s_cb) s_cb(BLE_EVT_AUTH_OK, NULL);
            } else {
                ESP_LOGW(TAG, "Auth confirm mismatch");
                if (s_cb) s_cb(BLE_EVT_AUTH_FAIL, NULL);
            }
            break;

        case 0x10:
            ESP_LOGI(TAG, "Session start requested");
            break;

        case 0x11:
            ESP_LOGI(TAG, "Session stop requested");
            break;

        default:
            ESP_LOGW(TAG, "Unknown control cmd 0x%02X", cmd);
            break;
        }
        return;
    }

    /* --- Sync metadata --- */
    if (h == s_handles[IDX_CHAR_SYNC_VAL]) {
        if (len > sizeof(s_sync_value)) len = sizeof(s_sync_value);
        memcpy(s_sync_value, val, len);
        ESP_LOGI(TAG, "Sync write (%d bytes)", len);
        return;
    }

    /* --- CCCD writes --- */
    if (h == s_handles[IDX_CHAR_RESP_CFG]     ||
        h == s_handles[IDX_CHAR_VITALS_CFG]   ||
        h == s_handles[IDX_CHAR_PPG_CFG]      ||
        h == s_handles[IDX_CHAR_ECG_CFG]      ||
        h == s_handles[IDX_CHAR_BATT_LVL_CFG]) {

        if (len != 2) return;
        uint16_t cccd = (uint16_t)val[0] | ((uint16_t)val[1] << 8);
        bool enable = (cccd & 0x0001) != 0;

        if (h == s_handles[IDX_CHAR_VITALS_CFG])   s_notify_vitals = enable;
        if (h == s_handles[IDX_CHAR_PPG_CFG])      s_notify_ppg    = enable;
        if (h == s_handles[IDX_CHAR_ECG_CFG])      s_notify_ecg    = enable;
        if (h == s_handles[IDX_CHAR_BATT_LVL_CFG]) s_notify_batt   = enable;

        ESP_LOGI(TAG, "CCCD 0x%04X -> %s", h, enable ? "ON" : "OFF");
    }
}

/* ------------------------------------------------------------------
 * GATTS event handler
 * ------------------------------------------------------------------ */
static void gatts_event_handler(esp_gatts_cb_event_t event,
                                esp_gatt_if_t iface,
                                esp_ble_gatts_cb_param_t *param)
{
    switch (event) {

    case ESP_GATTS_REG_EVT:
        ESP_LOGI(TAG, "GATTS registered (app_id=%d, if=%d)",
                 param->reg.app_id, iface);
        s_gatts_if = iface;
        esp_ble_gap_set_device_name("Guardian Watch");
        esp_ble_gatts_create_attr_tab(s_gatt_db, iface, IDX_NB, 0);
        break;

    case ESP_GATTS_CREATE_ATTR_TAB_EVT:
        if (param->add_attr_tab.status != ESP_GATT_OK) {
            ESP_LOGE(TAG, "Attr table create failed: 0x%02X",
                     param->add_attr_tab.status);
            break;
        }
        if (param->add_attr_tab.num_handle != IDX_NB) {
            ESP_LOGE(TAG, "Attr table count mismatch: %d != %d",
                     param->add_attr_tab.num_handle, IDX_NB);
            break;
        }
        memcpy(s_handles, param->add_attr_tab.handles, sizeof(s_handles));
        ESP_LOGI(TAG, "Attr table created (%d handles)", IDX_NB);

        esp_ble_gatts_start_service(s_handles[IDX_SVC_DEVICE]);

        load_device_id();
        esp_ble_gatts_set_attr_value(s_handles[IDX_CHAR_DEV_ID_VAL],
                                     sizeof(s_dev_id_value), s_dev_id_value);

        {
            esp_ble_adv_data_t adv_data = {
                .set_scan_rsp = false,
                .include_name = true,
                .include_txpower = true,
                .min_interval = 0x20,
                .max_interval = 0x40,
                .appearance = 0x0340, /* wrist-worn */
                .service_uuid_len = 16,
                .p_service_uuid = adv_service_uuid,
            };
            esp_ble_gap_config_adv_data(&adv_data);
        }
        break;

    case ESP_GATTS_CONNECT_EVT:
        s_conn_id = param->connect.conn_id;
        s_connected = true;
        s_authed = false;
        s_notify_vitals = s_notify_ppg = s_notify_ecg = s_notify_batt = false;
        memset(s_nonce, 0, sizeof(s_nonce));
        memset(s_resp_value, 0, sizeof(s_resp_value));
        ESP_LOGI(TAG, "Client connected (conn_id=%d)", s_conn_id);

        esp_ble_set_encryption(param->connect.remote_bda,
                               ESP_BLE_SEC_ENCRYPT_MITM);

        if (s_cb) s_cb(BLE_EVT_CONNECTED, NULL);
        break;

    case ESP_GATTS_DISCONNECT_EVT:
        s_connected = false;
        s_authed = false;
        ESP_LOGI(TAG, "Client disconnected (reason=0x%02X)",
                 param->disconnect.reason);
        if (s_cb) s_cb(BLE_EVT_DISCONNECTED, NULL);
        ble_manager_start_advertising();
        break;

    case ESP_GATTS_READ_EVT:
        handle_read(iface, param);
        break;

    case ESP_GATTS_WRITE_EVT:
        handle_write(iface, param);
        break;

    case ESP_GATTS_MTU_EVT:
        ESP_LOGI(TAG, "MTU exchanged: %d", param->mtu.mtu);
        break;

    case ESP_GATTS_CONF_EVT:
        if (param->conf.status != ESP_GATT_OK) {
            ESP_LOGW(TAG, "Confirm error 0x%02X", param->conf.status);
        }
        break;

    case ESP_GATTS_START_EVT:
        ESP_LOGI(TAG, "Service started (handle=%d)",
                 param->start.service_handle);
        break;

    default:
        break;
    }
}

/* ------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------ */

esp_err_t ble_manager_init(ble_event_cb_t cb)
{
    s_cb = cb;

    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));

    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatts_event_handler));
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
    ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));

    esp_ble_gatt_set_local_mtu(247);

    /* Security parameters */
    esp_ble_io_cap_t iocap = ESP_IO_CAP_NONE;
    esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE,
                                   &iocap, sizeof(uint8_t));

    uint8_t key_size = 16;
    esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE,
                                   &key_size, sizeof(uint8_t));

    uint8_t auth_req = ESP_LE_AUTH_REQ_SC_BOND;
    esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE,
                                   &auth_req, sizeof(uint8_t));

    uint8_t init_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t rsp_key  = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY,
                                   &init_key, sizeof(uint8_t));
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY,
                                   &rsp_key, sizeof(uint8_t));

    ESP_LOGI(TAG, "BLE manager initialized");
    return ESP_OK;
}

esp_err_t ble_manager_start_advertising(void)
{
    if (s_connected) return ESP_ERR_INVALID_STATE;
    return esp_ble_gap_start_advertising(&adv_params);
}

esp_err_t ble_manager_stop_advertising(void)
{
    return esp_ble_gap_stop_advertising();
}

esp_err_t ble_manager_disconnect(void)
{
    if (!s_connected) return ESP_OK;
    return esp_ble_gatts_close(s_gatts_if, s_conn_id);
}

esp_err_t ble_manager_enable_trusted_services(void)
{
    ESP_LOGI(TAG, "Trusted services enabled (authed=%d)", s_authed);
    return ESP_OK;
}

esp_err_t ble_manager_notify_telemetry(const telemetry_packet_t *p)
{
    if (!s_connected || !s_authed) return ESP_ERR_INVALID_STATE;
    if (!s_notify_vitals)          return ESP_ERR_INVALID_STATE;
    return esp_ble_gatts_send_indicate(s_gatts_if, s_conn_id,
                                       s_handles[IDX_CHAR_VITALS_VAL],
                                       sizeof(*p), (uint8_t *)p, false);
}

esp_err_t ble_manager_notify_ppg(const uint8_t *data, size_t len)
{
    if (!s_connected || !s_authed) return ESP_ERR_INVALID_STATE;
    if (!s_notify_ppg)             return ESP_ERR_INVALID_STATE;
    return esp_ble_gatts_send_indicate(s_gatts_if, s_conn_id,
                                       s_handles[IDX_CHAR_PPG_VAL],
                                       len, (uint8_t *)data, false);
}

esp_err_t ble_manager_notify_ecg(const uint8_t *data, size_t len)
{
    if (!s_connected || !s_authed) return ESP_ERR_INVALID_STATE;
    if (!s_notify_ecg)             return ESP_ERR_INVALID_STATE;
    return esp_ble_gatts_send_indicate(s_gatts_if, s_conn_id,
                                       s_handles[IDX_CHAR_ECG_VAL],
                                       len, (uint8_t *)data, false);
}

esp_err_t ble_manager_notify_battery(uint8_t percent)
{
    if (!s_connected)   return ESP_ERR_INVALID_STATE;
    if (!s_notify_batt) return ESP_ERR_INVALID_STATE;
    s_batt_value[0] = percent;
    return esp_ble_gatts_send_indicate(s_gatts_if, s_conn_id,
                                       s_handles[IDX_CHAR_BATT_LVL_VAL],
                                       1, s_batt_value, false);
}

bool ble_manager_is_authed(void)    { return s_authed; }
bool ble_manager_is_connected(void) { return s_connected; }
'@

Set-Content -Path $target -Value $content -Encoding ASCII -NoNewline
Write-Host "  + components\ble_manager\ble_manager.c" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 15 complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "File created:"
Write-Host "  - components\ble_manager\ble_manager.c"
Write-Host ""
Write-Host "Next: build the firmware (idf.py build) to check for errors."
Write-Host ""