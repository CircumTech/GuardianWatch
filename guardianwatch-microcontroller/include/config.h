#pragma once

#include <Arduino.h>

// ============================================================
// Guardian Watch hardware configuration
// ============================================================

// -------------------------
// I2C
// -------------------------

#define I2C_SDA_PIN 4
#define I2C_SCL_PIN 5

#define MAX30101_I2C_ADDRESS 0x57
#define TMP117_I2C_ADDRESS   0x48

// -------------------------
// AD8232 ECG
// -------------------------

#define ECG_ADC_PIN 0

// Optional AD8232 leads-off pins.
// Set to -1 when not connected.
#define ECG_LO_PLUS_PIN  -1
#define ECG_LO_MINUS_PIN -1

// -------------------------
// Battery measurement
// -------------------------

#define BATTERY_ADC_PIN 1

// Voltage divider:
//
// Battery ----- R1 ----- ADC ----- R2 ----- GND
//
// Change these to match your actual PCB.
#define BATTERY_R1 100000.0f
#define BATTERY_R2 100000.0f

// ADC reference assumptions.
#define ADC_MAX_VALUE 4095.0f
#define ADC_REFERENCE 3.3f

// -------------------------
// Buzzer
// -------------------------

#define BUZZER_PIN 8

// -------------------------
// ECG
// -------------------------

#define ECG_SAMPLE_RATE 250

// Timer period in microseconds.
#define ECG_SAMPLE_PERIOD_US \
    (1000000UL / ECG_SAMPLE_RATE)

// AD8232 / ADC -> millivolt conversion.
//
// THIS IS A CALIBRATION CONSTANT.
// It must be calibrated against your actual analog front-end.
#define ECG_MV_PER_ADC_COUNT 0.0024f

// -------------------------
// Sensor rates
// -------------------------

#define PPG_SAMPLE_RATE 100

// Send sensor data over BLE at these approximate rates.
#define HR_NOTIFY_INTERVAL_MS   1000
#define SPO2_NOTIFY_INTERVAL_MS 1000
#define TEMP_NOTIFY_INTERVAL_MS 2000
#define ECG_NOTIFY_INTERVAL_MS 4
#define BATTERY_NOTIFY_INTERVAL_MS 10000

// -------------------------
// Device identity
// -------------------------

#define DEVICE_NAME "GuardianWatch"

// -------------------------
// BLE UUIDs
// -------------------------

#define BLE_SERVICE_UUID \
    "3D0A8D59-C6C6-4163-A4B7-680079B25C90"

#define BLE_HR_UUID \
    "5E6DC24D-F02B-46C8-A8BF-92ADD6170EA4"

#define BLE_SPO2_UUID \
    "C862F7BE-CBBA-424E-B2C3-157C2791691E"

#define BLE_TEMP_UUID \
    "EB6A288D-9DBD-4BAD-82F2-96E7A1063DB2"

#define BLE_ECG_UUID \
    "A779185C-2A88-4102-A72A-9B9FA85F59ED"

#define BLE_BATTERY_UUID \
    "F459EED5-5062-473F-B061-9B962A31BC88"

// -------------------------
// Device states
// -------------------------

enum DeviceState : uint8_t {
    DEVICE_BOOTING = 0,
    DEVICE_READY   = 1,
    DEVICE_ERROR   = 2
};
