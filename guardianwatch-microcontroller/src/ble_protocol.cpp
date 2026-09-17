#include "ble_protocol.h"
#include "config.h"

#include <cstring>

void GuardianBLE::ServerCallbacks::onConnect(
    NimBLEServer* server,
    NimBLEConnInfo& connInfo
) {
    (void)server;
    (void)connInfo;

    _owner->_connected = true;

    Serial.println(
        "[BLE] Client connected."
    );
}

void GuardianBLE::ServerCallbacks::onDisconnect(
    NimBLEServer* server,
    NimBLEConnInfo& connInfo,
    int reason
) {
    (void)connInfo;

    _owner->_connected = false;

    Serial.printf(
        "[BLE] Client disconnected. Reason: %d\n",
        reason
    );

    // Resume advertising automatically.
    if (server != nullptr) {
        NimBLEDevice::startAdvertising();
    }
}

bool GuardianBLE::begin() {
    Serial.println(
        "[BLE] Initializing..."
    );

    NimBLEDevice::init(
        DEVICE_NAME
    );

    NimBLEDevice::setPower(
        3
    );

    _server = NimBLEDevice::createServer();

    if (_server == nullptr) {
        Serial.println(
            "[BLE] Failed to create server."
        );

        return false;
    }

    _callbacks = new ServerCallbacks(
        this
    );

    _server->setCallbacks(
        _callbacks
    );

    _service =
        _server->createService(
            BLE_SERVICE_UUID
        );

    if (_service == nullptr) {
        Serial.println(
            "[BLE] Failed to create service."
        );

        return false;
    }

    // --------------------------------------------------------
    // Heart rate
    // --------------------------------------------------------

    _hrCharacteristic =
        _service->createCharacteristic(
            BLE_HR_UUID,
            NIMBLE_PROPERTY::NOTIFY |
            NIMBLE_PROPERTY::READ
        );

    // --------------------------------------------------------
    // SpO2
    // --------------------------------------------------------

    _spo2Characteristic =
        _service->createCharacteristic(
            BLE_SPO2_UUID,
            NIMBLE_PROPERTY::NOTIFY |
            NIMBLE_PROPERTY::READ
        );

    // --------------------------------------------------------
    // Temperature
    // --------------------------------------------------------

    _tempCharacteristic =
        _service->createCharacteristic(
            BLE_TEMP_UUID,
            NIMBLE_PROPERTY::NOTIFY |
            NIMBLE_PROPERTY::READ
        );

    // --------------------------------------------------------
    // ECG
    // --------------------------------------------------------

    _ecgCharacteristic =
        _service->createCharacteristic(
            BLE_ECG_UUID,
            NIMBLE_PROPERTY::NOTIFY
        );

    // --------------------------------------------------------
    // Battery
    // --------------------------------------------------------

    _batteryCharacteristic =
        _service->createCharacteristic(
            BLE_BATTERY_UUID,
            NIMBLE_PROPERTY::NOTIFY |
            NIMBLE_PROPERTY::READ
        );

    _service->start();

    NimBLEAdvertising* advertising =
        NimBLEDevice::getAdvertising();

    advertising->addServiceUUID(
        BLE_SERVICE_UUID
    );

    advertising->setName(
        DEVICE_NAME
    );

    advertising->enableScanResponse(
        true
    );

    NimBLEDevice::startAdvertising();

    Serial.println(
        "[BLE] Advertising started."
    );

    return true;
}

void GuardianBLE::update() {
    // Reserved for future connection/security management.
}

bool GuardianBLE::isConnected() const {
    return _connected;
}

void GuardianBLE::notifyHeartRate(
    uint16_t bpm
) {
    if (!_connected ||
        _hrCharacteristic == nullptr) {
        return;
    }

    // Flutter expects:
    // 2 bytes, big-endian.
    uint8_t payload[2];

    payload[0] =
        static_cast<uint8_t>(
            (bpm >> 8) & 0xFF
        );

    payload[1] =
        static_cast<uint8_t>(
            bpm & 0xFF
        );

    _hrCharacteristic->setValue(
        payload,
        sizeof(payload)
    );

    _hrCharacteristic->notify();
}

void GuardianBLE::notifySpO2(
    uint8_t spo2
) {
    if (!_connected ||
        _spo2Characteristic == nullptr) {
        return;
    }

    _spo2Characteristic->setValue(
        &spo2,
        sizeof(spo2)
    );

    _spo2Characteristic->notify();
}

void GuardianBLE::notifyTemperature(
    float temperatureC
) {
    if (!_connected ||
        _tempCharacteristic == nullptr) {
        return;
    }

    // Flutter expects Float32 little-endian.
    uint8_t payload[sizeof(float)];

    static_assert(
        sizeof(float) == 4,
        "Guardian Watch requires 32-bit float."
    );

    memcpy(
        payload,
        &temperatureC,
        sizeof(float)
    );

    _tempCharacteristic->setValue(
        payload,
        sizeof(payload)
    );

    _tempCharacteristic->notify();
}

void GuardianBLE::notifyECG(
    int16_t ecgRaw
) {
    if (!_connected ||
        _ecgCharacteristic == nullptr) {
        return;
    }

    // Flutter:
    //
    // raw = signed 16-bit
    // ecgMv = raw * 0.0024
    //
    // Send little-endian int16.

    uint8_t payload[2];

    payload[0] =
        static_cast<uint8_t>(
            ecgRaw & 0xFF
        );

    payload[1] =
        static_cast<uint8_t>(
            (ecgRaw >> 8) & 0xFF
        );

    _ecgCharacteristic->setValue(
        payload,
        sizeof(payload)
    );

    _ecgCharacteristic->notify();
}

void GuardianBLE::notifyBattery(
    uint8_t percentage
) {
    if (!_connected ||
        _batteryCharacteristic == nullptr) {
        return;
    }

    _batteryCharacteristic->setValue(
        &percentage,
        sizeof(percentage)
    );

    _batteryCharacteristic->notify();
}
