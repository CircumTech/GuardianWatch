#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <Preferences.h>
#include <TFT_eSPI.h>
#include <Wire.h>
#include <MAX30105.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <esp_sleep.h>

// ===== Pin Definitions =====
#define ECG_PIN        34   // AD8232 analog output
#define BATTERY_PIN    35   // Voltage divider
#define BUTTON_PIN     0    // Power button (GPIO0, boot button on many boards)
#define ONE_WIRE_BUS  4    // DS18B20 data pin

// ===== BLE Service & Characteristics =====
#define SERVICE_UUID           "3D0A8D59-C6C6-4163-A4B7-680079B25C90"
#define HR_CHAR_UUID           "5E6DC24D-F02B-46C8-A8BF-92ADD6170EA4"
#define SPO2_CHAR_UUID         "C862F7BE-CBBA-424E-B2C3-157C2791691E"
#define TEMP_CHAR_UUID         "EB6A288D-9DBD-4BAD-82F2-96E7A1063DB2"
#define ECG_CHAR_UUID          "A779185C-2A88-4102-A72A-9B9FA85F59ED"
#define BATTERY_CHAR_UUID      "F459EED5-5062-473F-B061-9B962A31BC88"
#define DEVICE_ID_CHAR_UUID    "12345678-1234-1234-1234-123456789ABC"  // Custom

// ===== Global Objects =====
TFT_eSPI tft = TFT_eSPI();
MAX30105 particleSensor;
OneWire oneWire(ONE_WIRE_BUS);
DallasTemperature tempSensor(&oneWire);
Preferences preferences;

BLEServer* pServer = nullptr;
BLECharacteristic* pHRChar = nullptr;
BLECharacteristic* pSpo2Char = nullptr;
BLECharacteristic* pTempChar = nullptr;
BLECharacteristic* pEcgChar = nullptr;
BLECharacteristic* pBatteryChar = nullptr;
BLECharacteristic* pDeviceIdChar = nullptr;

// ===== Device ID Storage =====
String deviceId = "";
const char* PREF_NAMESPACE = "gw";
const char* PREF_KEY_DEVICE_ID = "device_id";

// ===== Sensor Variables =====
int heartRate = 0;
int spo2 = 0;
float temperature = 0.0;
float batteryVoltage = 0.0;
int batteryPercent = 0;

// ===== Timing =====
unsigned long lastSensorRead = 0;
const unsigned long SENSOR_INTERVAL = 1000;  // 1 second

// ===== Function Prototypes =====
void initBLE();
void initDisplay();
void initSensors();
void readSensors();
void updateDisplay();
void handleButton();
void setDeviceID(String id);
String generateDeviceID();

// ===== Setup =====
void setup() {
  Serial.begin(115200);
  
  // Initialize display
  initDisplay();
  
  // Load or generate device ID from Preferences
  preferences.begin(PREF_NAMESPACE, false);
  deviceId = preferences.getString(PREF_KEY_DEVICE_ID, "");
  if (deviceId.isEmpty()) {
    deviceId = generateDeviceID();
    preferences.putString(PREF_KEY_DEVICE_ID, deviceId);
  }
  preferences.end();
  
  // Initialize sensors
  initSensors();
  
  // Initialize BLE
  initBLE();
  
  // Button interrupt (long press detection)
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN), handleButton, FALLING);
  
  // Read sensors immediately for display
  readSensors();
  updateDisplay();
}

// ===== Loop =====
void loop() {
  // Read sensors periodically
  if (millis() - lastSensorRead >= SENSOR_INTERVAL) {
    lastSensorRead = millis();
    readSensors();
    updateDisplay();
    
    // Update BLE characteristics
    if (pHRChar) pHRChar->setValue(heartRate);
    if (pSpo2Char) pSpo2Char->setValue(spo2);
    if (pTempChar) pTempChar->setValue(temperature);
    if (pBatteryChar) pBatteryChar->setValue(batteryPercent);
    // ECG updates are sent continuously (see below)
  }
  
  // Read ECG in a non-blocking way (every 10ms)
  static unsigned long lastEcgRead = 0;
  if (millis() - lastEcgRead >= 10) {
    lastEcgRead = millis();
    int ecgValue = analogRead(ECG_PIN);
    // Convert to millivolts (0-3.3V mapped to 0-4095)
    float ecgMv = (ecgValue / 4095.0) * 3300.0;
    // Send as two-byte integer (or float) – here we send raw int
    if (pEcgChar) {
      uint8_t data[2];
      data[0] = (ecgValue >> 8) & 0xFF;
      data[1] = ecgValue & 0xFF;
      pEcgChar->setValue(data, 2);
      pEcgChar->notify();
    }
  }
  
  // Small delay to prevent watchdog
  delay(1);
}

// ===== BLE Initialization =====
void initBLE() {
  BLEDevice::init("GuardianWrist");
  pServer = BLEDevice::createServer();
  BLEService* pService = pServer->createService(BLEUUID(SERVICE_UUID));
  
  // Heart Rate Characteristic (notify)
  pHRChar = pService->createCharacteristic(
    HR_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pHRChar->addDescriptor(new BLE2902());
  
  // SpO2 Characteristic (notify)
  pSpo2Char = pService->createCharacteristic(
    SPO2_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pSpo2Char->addDescriptor(new BLE2902());
  
  // Temperature Characteristic (notify)
  pTempChar = pService->createCharacteristic(
    TEMP_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pTempChar->addDescriptor(new BLE2902());
  
  // ECG Characteristic (notify) – sends raw 12-bit ADC values
  pEcgChar = pService->createCharacteristic(
    ECG_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pEcgChar->addDescriptor(new BLE2902());
  
  // Battery Characteristic (read)
  pBatteryChar = pService->createCharacteristic(
    BATTERY_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  
  // Device ID Characteristic (read/write)
  pDeviceIdChar = pService->createCharacteristic(
    DEVICE_ID_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  pDeviceIdChar->setValue(deviceId.c_str());
  
  // Start service
  pService->start();
  
  // Advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  
  Serial.println("BLE started, advertising...");
}

// ===== Display Initialization =====
void initDisplay() {
  tft.init();
  tft.setRotation(1);
  tft.fillScreen(TFT_BLACK);
  tft.setTextSize(1);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
}

// ===== Sensors Initialization =====
void initSensors() {
  // MAX30102
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found");
  } else {
    particleSensor.setup(0x1F, 8, 2, 100, 411, 4096); // typical config
    particleSensor.enableDIETEMPRDY();
  }
  
  // DS18B20
  tempSensor.begin();
  
  // ADC for battery (attenuation)
  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);  // 0-3.3V
}

// ===== Read Sensors =====
void readSensors() {
  // Read HR and SpO₂ from MAX30102
  particleSensor.check();
  if (particleSensor.available()) {
    // This library provides IR and Red values; we need to compute HR/SpO2.
    // For simplicity, we simulate with placeholder values.
    // In a real implementation, use the MAX30105 library's beat detection.
    // We'll just generate random values for demo.
    heartRate = 60 + random(0, 41);   // 60-100 bpm
    spo2 = 95 + random(0, 5);         // 95-99%
  }
  
  // Read temperature from DS18B20
  tempSensor.requestTemperatures();
  temperature = tempSensor.getTempCByIndex(0);
  if (temperature == DEVICE_DISCONNECTED_C) {
    temperature = 0.0;
  }
  
  // Read battery voltage
  int raw = analogRead(BATTERY_PIN);
  float voltage = raw * (3.3 / 4095.0) * 2.0; // voltage divider factor 2
  batteryVoltage = voltage;
  // Map 3.0V to 0%, 4.2V to 100% (typical LiPo)
  batteryPercent = constrain(map(voltage * 100, 300, 420, 0, 100), 0, 100);
}

// ===== Update Display (graphical dashboard) =====
void updateDisplay() {
  tft.fillScreen(TFT_BLACK);
  
  // Header
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.setTextSize(2);
  tft.setCursor(10, 10);
  tft.print("GuardianWrist");
  
  tft.setTextSize(1);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.setCursor(10, 40);
  tft.print("ID: " + deviceId.substring(0, 8));
  
  // Metrics
  tft.setTextSize(2);
  tft.setTextColor(TFT_RED, TFT_BLACK);
  tft.setCursor(10, 70);
  tft.print("HR: " + String(heartRate) + " bpm");
  
  tft.setTextColor(TFT_BLUE, TFT_BLACK);
  tft.setCursor(10, 100);
  tft.print("SpO2: " + String(spo2) + "%");
  
  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.setCursor(10, 130);
  tft.print("Temp: " + String(temperature, 1) + " C");
  
  // Battery
  tft.setTextColor(TFT_GREEN, TFT_BLACK);
  tft.setCursor(10, 160);
  tft.print("Battery: " + String(batteryPercent) + "%");
  
  // ECG (simulated small graph)
  // We'll just print a placeholder
  tft.setTextColor(TFT_MAGENTA, TFT_BLACK);
  tft.setCursor(10, 190);
  tft.print("ECG: Live");
  
  // Footer
  tft.setTextSize(1);
  tft.setTextColor(TFT_GREY, TFT_BLACK);
  tft.setCursor(10, 220);
  tft.print("Long press button to reset ID");
}

// ===== Button Long Press Handler =====
volatile unsigned long buttonPressTime = 0;
bool buttonPressed = false;

void handleButton() {
  unsigned long current = millis();
  if (!buttonPressed) {
    buttonPressTime = current;
    buttonPressed = true;
  } else {
    // Check if long press (> 3 seconds)
    if (current - buttonPressTime > 3000) {
      resetDeviceID();
      buttonPressed = false;
    }
  }
}

void resetDeviceID() {
  // Generate new ID
  String newId = generateDeviceID();
  preferences.begin(PREF_NAMESPACE, false);
  preferences.putString(PREF_KEY_DEVICE_ID, newId);
  preferences.end();
  deviceId = newId;
  if (pDeviceIdChar) {
    pDeviceIdChar->setValue(deviceId.c_str());
  }
  // Restart BLE advertising to propagate new ID?
  // BLEDevice::startAdvertising(); // optional
  updateDisplay();
  Serial.println("Device ID reset to: " + deviceId);
}

String generateDeviceID() {
  // Generate a random 16-byte hex string (UUID-like)
  String id = "";
  for (int i = 0; i < 16; i++) {
    id += String(random(0, 16), HEX);
    if (i == 3 || i == 5 || i == 7 || i == 9) id += "-";
  }
  return id;
}