#include <Arduino.h>
#include <Wire.h>

#include "config.h"
#include "ble_protocol.h"
#include "max30101.h"
#include "tmp117.h"

// ============================================================
// Guardian Watch
// ESP32-C3 firmware
// ============================================================

GuardianBLE ble;
MAX30101 max30101;
TMP117 tmp117;

// ============================================================
// Runtime sensor state
// ============================================================

volatile bool ecgTimerFlag = false;

uint16_t currentHeartRate = 0;
uint8_t currentSpO2 = 0;
float currentTemperature = NAN;
uint8_t currentBattery = 0;

bool max30101Ready = false;
bool tmp117Ready = false;
bool bleReady = false;

// ============================================================
// Timing
// ============================================================

uint32_t lastHeartRateNotify = 0;
uint32_t lastSpO2Notify = 0;
uint32_t lastTemperatureNotify = 0;
uint32_t lastBatteryNotify = 0;

uint32_t lastPPGProcess = 0;

// ============================================================
// ECG timer
// ============================================================

hw_timer_t* ecgTimer = nullptr;

void IRAM_ATTR onECGTimer() {
    ecgTimerFlag = true;
}

// ============================================================
// ECG sampling
// ============================================================

void processECG() {
    if (!ecgTimerFlag) {
        return;
    }

    ecgTimerFlag = false;

    const int adc =
        analogRead(
            ECG_ADC_PIN
        );

    const float centered =
        static_cast<float>(adc) -
        2048.0f;

    // Convert ADC counts to the signed raw
    // representation expected by Flutter.
    //
    // Flutter later performs:
    //
    // ecgMv = raw * 0.0024
    //
    const int32_t rawValue =
        static_cast<int32_t>(
            centered
        );

    const int16_t raw =
        static_cast<int16_t>(
            constrain(
                rawValue,
                -32768,
                32767
            )
        );

    if (ble.isConnected()) {
        ble.notifyECG(
            raw
        );
    }
}

// ============================================================
// Battery
// ============================================================

uint8_t readBatteryPercentage() {
    const int raw =
        analogRead(
            BATTERY_ADC_PIN
        );

    const float adcVoltage =
        (
            static_cast<float>(raw) /
            ADC_MAX_VALUE
        ) *
        ADC_REFERENCE;

    const float batteryVoltage =
        adcVoltage *
        (
            (BATTERY_R1 + BATTERY_R2) /
            BATTERY_R2
        );

    // Generic single-cell Li-ion approximation.
    //
    // This is NOT a fuel gauge.
    // Replace with a calibrated battery model or
    // dedicated fuel-gauge IC for production.
    float percentage =
        (
            batteryVoltage - 3.20f
        ) /
        (
            4.20f - 3.20f
        ) *
        100.0f;

    percentage =
        constrain(
            percentage,
            0.0f,
            100.0f
        );

    return static_cast<uint8_t>(
        percentage
    );
}

// ============================================================
// Heart rate / SpO2 estimation
// ============================================================
//
// This is deliberately conservative.
// The MAX30101 provides raw optical data.
//
// Production-grade physiological estimation should use a
// validated PPG processing pipeline rather than treating a
// simple threshold as clinical measurement.
//
// The current implementation provides a basic engineering
// estimate so the complete hardware/BLE pipeline can be tested.
// ============================================================

uint16_t estimateHeartRate(
    uint32_t red,
    uint32_t ir
) {
    static uint32_t previousIR = 0;
    static uint32_t previousTimestamp = 0;

    if (previousIR == 0) {
        previousIR = ir;
        previousTimestamp = millis();

        return currentHeartRate;
    }

    const uint32_t now =
        millis();

    const int32_t delta =
        static_cast<int32_t>(
            ir
        ) -
        static_cast<int32_t>(
            previousIR
        );

    previousIR = ir;

    // Very conservative pulse-edge heuristic.
    if (delta > 1200) {
        const uint32_t interval =
            now -
            previousTimestamp;

        previousTimestamp = now;

        if (interval >= 300 &&
            interval <= 2000) {
            const uint16_t bpm =
                static_cast<uint16_t>(
                    60000UL / interval
                );

            if (bpm >= 30 &&
                bpm <= 220) {
                return bpm;
            }
        }
    }

    (void)red;

    return currentHeartRate;
}

uint8_t estimateSpO2(
    uint32_t red,
    uint32_t ir
) {
    if (ir == 0) {
        return currentSpO2;
    }

    // Ratio-of-ratios approximation.
    //
    // This is intentionally only an engineering estimate.
    // Calibration against a reference system is required
    // before any medical interpretation.

    const float ratio =
        static_cast<float>(red) /
        static_cast<float>(ir);

    float spo2 =
        110.0f -
        25.0f * ratio;

    spo2 =
        constrain(
            spo2,
            70.0f,
            100.0f
        );

    return static_cast<uint8_t>(
        spo2
    );
}

void processPPG() {
    if (!max30101Ready) {
        return;
    }

    if (!max30101.available()) {
        return;
    }

    uint32_t red = 0;
    uint32_t ir = 0;

    if (!max30101.readSample(
            red,
            ir
        )) {
        return;
    }

    const uint16_t estimatedHR =
        estimateHeartRate(
            red,
            ir
        );

    const uint8_t estimatedSpO2 =
        estimateSpO2(
            red,
            ir
        );

    if (estimatedHR >= 30 &&
        estimatedHR <= 220) {
        currentHeartRate =
            estimatedHR;
    }

    currentSpO2 =
        estimatedSpO2;
}

// ============================================================
// Temperature
// ============================================================

void processTemperature() {
    if (!tmp117Ready) {
        return;
    }

    float temperature = NAN;

    if (tmp117.readTemperature(
            temperature
        )) {
        if (temperature >= -20.0f &&
            temperature <= 50.0f) {
            currentTemperature =
                temperature;
        }
    }
}

// ============================================================
// BLE publishing
// ============================================================

void publishSensorValues() {
    if (!ble.isConnected()) {
        return;
    }

    const uint32_t now =
        millis();

    if (
        currentHeartRate >= 30 &&
        currentHeartRate <= 220 &&
        (
            now -
            lastHeartRateNotify
        ) >= HR_NOTIFY_INTERVAL_MS
    ) {
        ble.notifyHeartRate(
            currentHeartRate
        );

        lastHeartRateNotify =
            now;
    }

    if (
        currentSpO2 >= 70 &&
        currentSpO2 <= 100 &&
        (
            now -
            lastSpO2Notify
        ) >= SPO2_NOTIFY_INTERVAL_MS
    ) {
        ble.notifySpO2(
            currentSpO2
        );

        lastSpO2Notify =
            now;
    }

    if (
        !isnan(currentTemperature) &&
        (
            now -
            lastTemperatureNotify
        ) >= TEMP_NOTIFY_INTERVAL_MS
    ) {
        ble.notifyTemperature(
            currentTemperature
        );

        lastTemperatureNotify =
            now;
    }

    if (
        (
            now -
            lastBatteryNotify
        ) >= BATTERY_NOTIFY_INTERVAL_MS
    ) {
        currentBattery =
            readBatteryPercentage();

        ble.notifyBattery(
            currentBattery
        );

        lastBatteryNotify =
            now;
    }
}

// ============================================================
// Hardware initialization
// ============================================================

bool initializeSensors() {
    Serial.println(
        "[SYSTEM] Initializing I2C..."
    );

    Wire.begin(
        I2C_SDA_PIN,
        I2C_SCL_PIN
    );

    Wire.setClock(
        400000
    );

    // --------------------------------------------------------
    // MAX30101
    // --------------------------------------------------------

    max30101Ready =
        max30101.begin(
            Wire,
            MAX30101_I2C_ADDRESS
        );

    if (max30101Ready) {
        Serial.println(
            "[SYSTEM] MAX30101 OK"
        );
    } else {
        Serial.println(
            "[SYSTEM] MAX30101 FAILED"
        );
    }

    // --------------------------------------------------------
    // Temperature sensor
    // --------------------------------------------------------

    tmp117Ready =
        tmp117.begin(
            Wire,
            TMP117_I2C_ADDRESS
        );

    if (tmp117Ready) {
        Serial.println(
            "[SYSTEM] Temperature sensor OK"
        );
    } else {
        Serial.println(
            "[SYSTEM] Temperature sensor FAILED"
        );
    }

    // --------------------------------------------------------
    // ECG
    // --------------------------------------------------------

    analogReadResolution(
        12
    );

    pinMode(
        ECG_ADC_PIN,
        INPUT
    );

    // --------------------------------------------------------
    // Battery
    // --------------------------------------------------------

    pinMode(
        BATTERY_ADC_PIN,
        INPUT
    );

#if ECG_LO_PLUS_PIN >= 0
    pinMode(
        ECG_LO_PLUS_PIN,
        INPUT
    );
#endif

#if ECG_LO_MINUS_PIN >= 0
    pinMode(
        ECG_LO_MINUS_PIN,
        INPUT
    );
#endif

    // --------------------------------------------------------
    // Buzzer
    // --------------------------------------------------------

    pinMode(
        BUZZER_PIN,
        OUTPUT
    );

    digitalWrite(
        BUZZER_PIN,
        LOW
    );

    return true;
}

// ============================================================
// Setup
// ============================================================

void setup() {
    Serial.begin(
        115200
    );

    delay(500);

    Serial.println();
    Serial.println(
        "========================================"
    );
    Serial.println(
        "       GUARDIAN WATCH FIRMWARE"
    );
    Serial.println(
        "       ESP32-C3"
    );
    Serial.println(
        "========================================"
    );

    // --------------------------------------------------------
    // Hardware
    // --------------------------------------------------------

    initializeSensors();

    // --------------------------------------------------------
    // BLE
    // --------------------------------------------------------

    bleReady =
        ble.begin();

    if (!bleReady) {
        Serial.println(
            "[SYSTEM] BLE initialization FAILED."
        );
    } else {
        Serial.println(
            "[SYSTEM] BLE ready."
        );
    }

    // --------------------------------------------------------
    // ECG hardware timer
    // --------------------------------------------------------

    ecgTimer =
        timerBegin(
            1000000
        );

    if (ecgTimer != nullptr) {
        timerAttachInterrupt(
            ecgTimer,
            &onECGTimer
        );

        timerAlarm(
            ecgTimer,
            ECG_SAMPLE_PERIOD_US,
            true,
            0
        );

        Serial.printf(
            "[ECG] Sampling at %d Hz\n",
            ECG_SAMPLE_RATE
        );
    } else {
        Serial.println(
            "[ECG] Timer initialization failed."
        );
    }

    currentBattery =
        readBatteryPercentage();

    Serial.printf(
        "[BATTERY] %u%%\n",
        currentBattery
    );

    Serial.println(
        "[SYSTEM] Guardian Watch ready."
    );
}

// ============================================================
// Main loop
// ============================================================

void loop() {
    // ECG has the highest sampling priority.
    processECG();

    // PPG processing.
    processPPG();

    // Temperature.
    const uint32_t now =
        millis();

    if (
        now -
        lastPPGProcess >=
        100
    ) {
        lastPPGProcess =
            now;

        processTemperature();
    }

    // BLE data publication.
    publishSensorValues();

    ble.update();

    // Keep the loop responsive.
    delay(1);
}
