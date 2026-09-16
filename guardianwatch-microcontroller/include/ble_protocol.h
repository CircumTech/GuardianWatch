#pragma once

#include <Arduino.h>
#include <NimBLEDevice.h>

class GuardianBLE {
public:
    bool begin();

    void update();

    bool isConnected() const;

    void notifyHeartRate(uint16_t bpm);
    void notifySpO2(uint8_t spo2);
    void notifyTemperature(float temperatureC);
    void notifyECG(int16_t ecgRaw);
    void notifyBattery(uint8_t percentage);

private:
    NimBLEServer* _server = nullptr;

    NimBLEService* _service = nullptr;

    NimBLECharacteristic* _hrCharacteristic = nullptr;
    NimBLECharacteristic* _spo2Characteristic = nullptr;
    NimBLECharacteristic* _tempCharacteristic = nullptr;
    NimBLECharacteristic* _ecgCharacteristic = nullptr;
    NimBLECharacteristic* _batteryCharacteristic = nullptr;

    bool _connected = false;

    class ServerCallbacks : public NimBLEServerCallbacks {
    public:
        explicit ServerCallbacks(GuardianBLE* owner)
            : _owner(owner) {}

        void onConnect(
            NimBLEServer* server,
            NimBLEConnInfo& connInfo
        ) override;

        void onDisconnect(
            NimBLEServer* server,
            NimBLEConnInfo& connInfo,
            int reason
        ) override;

    private:
        GuardianBLE* _owner;
    };

    ServerCallbacks* _callbacks = nullptr;
};
