#pragma once

#include <Arduino.h>
#include <Wire.h>

class TMP117 {
public:
    bool begin(
        TwoWire& wire = Wire,
        uint8_t address = 0x48
    );

    bool readTemperature(
        float& temperatureC
    );

private:
    TwoWire* _wire = nullptr;
    uint8_t _address = 0x48;

    bool read16(
        uint8_t reg,
        uint16_t& value
    );

    bool write16(
        uint8_t reg,
        uint16_t value
    );
};
