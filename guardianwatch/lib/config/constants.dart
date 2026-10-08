// ─── lib/config/constants.dart ───────────────────────────────────────────────

/// Application-wide constants and environment configuration.
class AppConstants {
  AppConstants._();

  // ── App ──────────────────────────────────────────────────────────────────

  static const String appName = 'Guardian Watch';
  static const String appVersion = '1.0.0';

  // ── Environment / API ────────────────────────────────────────────────────
  //
  //   flutter run \
  //     --dart-define=API_BASE_URL=https://your-fastapi-url.com \
  //     --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxxx.apps.googleusercontent.com
  //
  // NOTE: apiBaseUrl MUST point to the FastAPI backend, NOT Firebase.
  //       Firebase Auth is handled by the Firebase SDK directly.

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://guardian-watch-api.onrender.com',
  );

  static const Duration apiTimeout = Duration(seconds: 30);
  static const Duration apiLongTimeout = Duration(seconds: 90); // ECG upload

  // ── Google Authentication ────────────────────────────────────────────────

  static const String googleClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
    defaultValue:
        '121147775704-9q0f0i9v2bnjk7me0ahhrb5sop25k872.apps.googleusercontent.com',
  );

  /// OAuth server client ID — REQUIRED for FastAPI to verify Firebase
  /// ID tokens minted from a Google sign-in. NOT a client secret.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );

  // ── In-App Purchase ──────────────────────────────────────────────────────

  static const String premiumMonthlyId = 'guardianwrist_premium_monthly';
  static const String premiumAnnualId = 'guardianwrist_premium_annual';

  static const Set<String> premiumProductIds = {
    premiumMonthlyId,
    premiumAnnualId,
  };

  // ── SharedPreferences Keys ───────────────────────────────────────────────

  static const String keyJwt = 'gw_jwt';
  static const String keyUserEmail = 'gw_user_email';
  static const String keyHealthOptIn = 'gw_health_opt_in';
  static const String keyAlertHrHigh = 'gw_alert_hr_high';
  static const String keyAlertSpo2Low = 'gw_alert_spo2_low';
  static const String keyThemeMode = 'gw_theme_mode';

  static const String keyDeviceId = 'gw_device_id';
  static const String keyDeviceName = 'gw_device_name';
  static const String keyDeviceVerified = 'gw_device_verified';
  static const String keyDeviceHwRev = 'gw_device_hw_rev';
  static const String keyDeviceFwRev = 'gw_device_fw_rev';

  static const String keyOnboardingCompleted = 'gw_onboarding_completed';

  static const String keyPremiumActive = 'gw_premium_active';
  static const String keyPremiumProduct = 'gw_premium_product';
  static const String keyPremiumExpiry = 'gw_premium_expiry';
  static const String keyPremiumVerified = 'gw_premium_verified_at';

  static const String keyLastSyncTimestamp = 'gw_last_sync_ts';
  static const String keySyncQueue = 'gw_sync_queue';

  // ── Health Alert Defaults (NOT medical diagnostic thresholds) ────────────

  static const int defaultHrHigh = 120;
  static const int defaultSpo2Low = 92;

  // ── BLE / Device Limits ──────────────────────────────────────────────────

  static const Duration bleConnectionTimeout = Duration(seconds: 15);
  static const Duration bleReconnectDelay = Duration(seconds: 5);
  static const int maxBleReconnectAttempts = 5;
  static const Duration bleScanTimeout = Duration(seconds: 20);

  static const String guardianDeviceNamePrefix = 'Guardian';
  static const String guardianBleServiceUuid = BleConstants.serviceUuid;

  // ── Data / Sync Defaults ─────────────────────────────────────────────────

  static const int historyPageSize = 20;
  static const int maxApiBatchSize = 100;
  static const Duration localHealthRetention = Duration(days: 30);
  static const Duration backgroundSyncInterval = Duration(seconds: 30);

  // ── ECG ──────────────────────────────────────────────────────────────────

  /// ECG sample rate (SPS). MUST match final ESP32 firmware.
  static const double ecgSampleRate = 250.0;

  /// Max samples retained by the live processing layer.
  static const int maxEcgWorkingSamples = 7500;

  // NOTE: ecgMillivoltsPerCount lives in BleConstants only.

  // ── Device Provisioning / Secure Pairing ─────────────────────────────────

  static const Duration deviceAuthTimeout = Duration(seconds: 10);
  static const int deviceAuthNonceBytes = 16;
  static const String deviceSecretKey = 'gw_device_secret'; // secure storage
  static const String devicePublicKeyKey = 'gw_device_pubkey';

  // ── Sync Engine ──────────────────────────────────────────────────────────

  static const int syncBatchSize = 50;
  static const int syncMaxRetries = 5;
  static const Duration syncBackoffBase = Duration(seconds: 2);
  static const int syncMaxBackoffSeconds = 300;

  // ─────────────────────────────────────────────────────────────────────────
  // Background Service
  // ─────────────────────────────────────────────────────────────────────────

  static const int bgForegroundNotificationId = 9901;
  static const Duration bgHeartbeatInterval = Duration(minutes: 1);
  static const Duration bgAlertCooldown = Duration(minutes: 5);
  static const Duration bgServiceStartTimeout = Duration(seconds: 10);

  // ─────────────────────────────────────────────────────────────────────────
  // Additional Alert Thresholds
  // ─────────────────────────────────────────────────────────────────────────

  static const double defaultTempHigh = 38.0; // °C
  static const int defaultBatteryLow = 20; // %
  static const int defaultBatteryCritical = 10; // %

  // Hysteresis — how far back inside the safe range before we clear an alert
  static const int hrAlertClearOffset = 5; // bpm
  static const int spo2AlertClearOffset = 2; // %
  static const double tempAlertClearOffset = 0.3; // °C
  static const int batteryAlertClearOffset = 5; // %

  // ─────────────────────────────────────────────────────────────────────────
  // Background Service SharedPreferences Keys
  // ─────────────────────────────────────────────────────────────────────────

  static const String keyAlertTempHigh = 'gw_alert_temp_high';
  static const String keyAlertBatteryLow = 'gw_alert_battery_low';
  static const String keyAlertBatteryCritical = 'gw_alert_battery_critical';

  static const String keyBgLastHighHrAlert = 'gw_bg_last_high_hr_alert';
  static const String keyBgLastLowSpo2Alert = 'gw_bg_last_low_spo2_alert';
  static const String keyBgLastHighTempAlert = 'gw_bg_last_high_temp_alert';
  static const String keyBgLastLowBatteryAlert = 'gw_bg_last_low_battery_alert';
  static const String keyBgLastCritBatteryAlert =
      'gw_bg_last_crit_battery_alert';

  static const String keyBgHighHrActive = 'gw_bg_high_hr_active';
  static const String keyBgLowSpo2Active = 'gw_bg_low_spo2_active';
  static const String keyBgHighTempActive = 'gw_bg_high_temp_active';
  static const String keyBgLowBatteryActive = 'gw_bg_low_battery_active';

  static const String keyHealthLastExportAt = 'gw_health_last_export_at';

  // Notification channel ID used by the foreground service.

  static const String bgForegroundChannelId = 'guardian_watch_monitoring';

  // ─────────────────────────────────────────────────────────────────────────
  // Connectivity
  // ─────────────────────────────────────────────────────────────────────────

  static const Duration connectivityCheckInterval = Duration(seconds: 20);

  static const Duration connectivityCheckTimeout = Duration(seconds: 5);

  // Under the SharedPreferences Keys section:
  static const String keyCloudSyncEnabled = 'gw_cloud_sync_enabled';

  static const String keyRetentionDays = 'gw_retention_days';
}

// ─── BLE Configuration ──────────────────────────────────────────────────────

class BleConstants {
  BleConstants._();

  // ── Protocol ─────────────────────────────────────────────────────────────

  /// BLE packet protocol version. Increment on breaking format change.
  static const int bleProtocolVersion = 1;

  /// Preferred MTU. Telemetry packets exceed 23-byte default and require
  /// MTU negotiation. ESP32-C3 supports up to 247.
  static const int targetMtu = 247;
  static const int minMtu = 64;

  // ── Main Guardian Watch GATT Service ─────────────────────────────────────

  static const String serviceUuid = '3D0A8D59-C6C6-4163-A4B7-680079B25C90';

  // ── Device Service (identity + secure pairing) ───────────────────────────

  static const String deviceIdCharUuid = '8E4A0C10-1111-4A01-9C11-000000000001';
  static const String authChallengeCharUuid =
      '8E4A0C10-1111-4A01-9C11-000000000002';
  static const String authResponseCharUuid =
      '8E4A0C10-1111-4A01-9C11-000000000003';

  // ── Status Service ───────────────────────────────────────────────────────

  static const String batteryCharUuid = 'F459EED5-5062-473F-B061-9B962A31BC88';
  static const String firmwareVersionCharUuid =
      'B1000001-0001-4000-8000-000000000001';
  static const String hardwareRevisionCharUuid =
      'B1000002-0001-4000-8000-000000000002';
  static const String faultStatusCharUuid =
      'B1000003-0001-4000-8000-000000000003';

  // ── Sync Service ─────────────────────────────────────────────────────────

  static const String syncMetaCharUuid = 'C1000001-0001-4000-8000-000000000001';
  static const String syncOffsetCharUuid =
      'C1000002-0001-4000-8000-000000000002';

  // ── Control Service ──────────────────────────────────────────────────────

  static const String controlCharUuid = 'D1000001-0001-4000-8000-000000000001';

  // ── Telemetry / PPG / ECG characteristics ────────────────────────────────

  static const String hrCharUuid = '5E6DC24D-F02B-46C8-A8BF-92ADD6170EA4';
  static const String spo2CharUuid = 'C862F7BE-CBBA-424E-B2C3-157C2791691E';
  static const String tempCharUuid = 'EB6A288D-9DBD-4BAD-82F2-96E7A1063DB2';
  static const String ecgCharUuid = 'A779185C-2A88-4102-A72A-9B9FA85F59ED';
  static const String ppgCharUuid = 'A1000001-0001-4000-8000-000000000001';

  // ── Legacy simple packet sizes (early firmware compatibility) ────────────

  static const int heartRatePacketBytes = 2;
  static const int temperaturePacketBytes = 4;
  static const int minimumEcgPacketBytes = 2;
  static const int batteryPacketBytes = 1;

  static const double ecgMillivoltsPerCount = 0.0024;

  // ── Quality Flags (bitmask stored in TelemetryPacket.flags) ──────────────

  static const int qualityFlagContactOk = 1 << 0;
  static const int qualityFlagMotionLow = 1 << 1;
  static const int qualityFlagLeadOff = 1 << 2;
  static const int qualityFlagCalibrated = 1 << 3;
  static const int qualityFlagCharging = 1 << 4;
  static const int qualityFlagFault = 1 << 5;

  // ── Quality Thresholds ───────────────────────────────────────────────────

  static const double motionRmsHighThreshold = 0.15; // g
  static const int ppgQualityMinScore = 60; // 0–100
  static const double ecgLeadOffThreshold = 0.9;

  // ── Control Service Command IDs ──────────────────────────────────────────

  static const int cmdStartEcg = 0x01;
  static const int cmdStopEcg = 0x02;
  static const int cmdStartSync = 0x03;
  static const int cmdStopSync = 0x04;
  static const int cmdRequestStatus = 0x05;
  static const int cmdSetLedBrightness = 0x10;
  static const int cmdFactoryReset = 0xFF;
}

// ─── Telemetry Packet Layout ─────────────────────────────────────────────────
//
//   offset  size  field
//   ------  ----  ----------------------
//   0       1     protocol_version  uint8
//   1       8     device_id         bytes[8]
//   9       4     sequence          uint32
//   13      8     timestamp_ms      uint64
//   21      2     flags             uint16
//   23      2     hr_bpm_x10        uint16
//   25      2     spo2_x10          uint16
//   27      2     temp_c_x100       uint16
//   29      2     motion_rms_x1000  uint16
//   31      1     quality_score     uint8
//   32      2     crc16             uint16
//   ------  ----  ----------------------
//   total   34

class TelemetryPacket {
  TelemetryPacket._();

  static const int versionOffset = 0;
  static const int deviceIdOffset = 1;
  static const int sequenceOffset = 9;
  static const int timestampOffset = 13;
  static const int flagsOffset = 21;
  static const int hrOffset = 23;
  static const int spo2Offset = 25;
  static const int tempOffset = 27;
  static const int motionOffset = 29;
  static const int qualityOffset = 31;
  static const int crcOffset = 32;
  static const int totalBytes = 34;
}
