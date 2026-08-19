// ─── lib/config/constants.dart ───────────────────────────────────────────────

class AppConstants {
  // Cloud Run base URL – replace with your actual deployed URL (no trailing slash)
  static const String apiBaseUrl =
      'https://guardianwrist-api-xxxxxxxx-uc.a.run.app'; // TODO: update

  // BLE service & characteristic UUIDs (match your firmware)
  static const String bleServiceUuid = '3D0A8D59-C6C6-4163-A4B7-680079B25C90';
  static const String hrCharUuid = '5E6DC24D-F02B-46C8-A8BF-92ADD6170EA4';
  static const String spo2CharUuid = 'C862F7BE-CBBA-424E-B2C3-157C2791691E';
  static const String tempCharUuid = 'EB6A288D-9DBD-4BAD-82F2-96E7A1063DB2';
  static const String ecgCharUuid = 'A779185C-2A88-4102-A72A-9B9FA85F59ED';
  static const String batteryCharUuid = 'F459EED5-5062-473F-B061-9B962A31BC88';

  // IAP product IDs (Apple App Store & Google Play)
  static const String premiumMonthlyId = 'guardianwrist_premium_monthly';
  static const String premiumAnnualId = 'guardianwrist_premium_annual';

  // SharedPreferences keys
  static const String keyJwt = 'gw_jwt';
  static const String keyUserEmail = 'gw_user_email';
  static const String keyHealthOptIn = 'gw_health_opt_in';
  static const String keyAlertHrHigh = 'gw_alert_hr_high';
  static const String keyAlertSpo2Low = 'gw_alert_spo2_low';

  // Alert thresholds (defaults)
  static const int defaultHrHigh = 120;
  static const int defaultSpo2Low = 92;

  // OAuth – only client ID is needed for mobile Google Sign-In
  // The client secret has been REMOVED for security.
  static const String googleClientId =
      "121147775704-9q0f0i9v2bnjk7me0ahhrb5sop25k872.apps.googleusercontent.com";
}
