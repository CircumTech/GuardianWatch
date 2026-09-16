#pragma once

#include <Arduino.h>
#include <Wire.h>

class MAX30101 {
public:
    bool begin(
        TwoWire& wire = Wire,
        uint8_t address = 0x57
    );

    bool available();

    bool readSample(
        uint32_t& red,
        uint32_t& ir
    );

    void clearFIFO();

private:
    TwoWire* _wire = nullptr;
    uint8_t _address = 0x57;

    bool writeRegister(
        uint8_t reg,
        uint8_t value
    );

    bool readRegister(
        uint8_t reg,
        uint8_t& value
    );

    bool readRegisters(
        uint8_t reg,
        uint8_t* data,
        size_t length
    );

    bool reset();

    uint8_t _lastWritePointer = 0;
    uint8_t _lastReadPointer = 0;
};
