#include "max30101.h"

namespace {

constexpr uint8_t REG_INTR_STATUS_1 = 0x00;
constexpr uint8_t REG_INTR_STATUS_2 = 0x01;

constexpr uint8_t REG_FIFO_WR_PTR = 0x04;
constexpr uint8_t REG_OVF_COUNTER  = 0x05;
constexpr uint8_t REG_FIFO_RD_PTR  = 0x06;

constexpr uint8_t REG_FIFO_DATA = 0x07;

constexpr uint8_t REG_FIFO_CONFIG = 0x08;
constexpr uint8_t REG_MODE_CONFIG = 0x09;
constexpr uint8_t REG_SPO2_CONFIG = 0x0A;

constexpr uint8_t REG_LED1_PA = 0x0C;
constexpr uint8_t REG_LED2_PA = 0x0D;

constexpr uint8_t REG_PART_ID = 0xFF;

}

bool MAX30101::writeRegister(
    uint8_t reg,
    uint8_t value
) {
    _wire->beginTransmission(
        _address
    );

    _wire->write(reg);
    _wire->write(value);

    return _wire->endTransmission() == 0;
}

bool MAX30101::readRegister(
    uint8_t reg,
    uint8_t& value
) {
    return readRegisters(
        reg,
        &value,
        1
    );
}

bool MAX30101::readRegisters(
    uint8_t reg,
    uint8_t* data,
    size_t length
) {
    if (_wire == nullptr ||
        data == nullptr ||
        length == 0) {
        return false;
    }

    _wire->beginTransmission(
        _address
    );

    _wire->write(reg);

    if (_wire->endTransmission(
            false
        ) != 0) {
        return false;
    }

    const uint8_t requested =
        static_cast<uint8_t>(
            min(
                length,
                static_cast<size_t>(32)
            )
        );

    const uint8_t received =
        _wire->requestFrom(
            _address,
            requested
        );

    if (received != requested) {
        return false;
    }

    for (uint8_t i = 0; i < received; ++i) {
        data[i] =
            _wire->read();
    }

    return true;
}

bool MAX30101::reset() {
    uint8_t mode = 0;

    if (!readRegister(
            REG_MODE_CONFIG,
            mode
        )) {
        return false;
    }

    mode |= 0x40;

    if (!writeRegister(
            REG_MODE_CONFIG,
            mode
        )) {
        return false;
    }

    delay(10);

    return true;
}

bool MAX30101::begin(
    TwoWire& wire,
    uint8_t address
) {
    _wire = &wire;
    _address = address;

    uint8_t partId = 0;

    if (!readRegister(
            REG_PART_ID,
            partId
        )) {
        Serial.println(
            "[MAX30101] Device not responding."
        );

        return false;
    }

    Serial.printf(
        "[MAX30101] Part ID: 0x%02X\n",
        partId
    );

    if (!reset()) {
        Serial.println(
            "[MAX30101] Reset failed."
        );

        return false;
    }

    // FIFO:
    // sample averaging = 4
    // rollover disabled
    // almost-full = 15
    if (!writeRegister(
            REG_FIFO_CONFIG,
            0x4F
        )) {
        return false;
    }

    // SpO2 mode.
    if (!writeRegister(
            REG_MODE_CONFIG,
            0x03
        )) {
        return false;
    }

    // 100 SPS, appropriate pulse-width configuration.
    if (!writeRegister(
            REG_SPO2_CONFIG,
            0x27
        )) {
        return false;
    }

    // LED currents.
    if (!writeRegister(
            REG_LED1_PA,
            0x24
        )) {
        return false;
    }

    if (!writeRegister(
            REG_LED2_PA,
            0x24
        )) {
        return false;
    }

    clearFIFO();

    Serial.println(
        "[MAX30101] Initialized."
    );

    return true;
}

void MAX30101::clearFIFO() {
    writeRegister(
        REG_FIFO_WR_PTR,
        0
    );

    writeRegister(
        REG_OVF_COUNTER,
        0
    );

    writeRegister(
        REG_FIFO_RD_PTR,
        0
    );

    _lastWritePointer = 0;
    _lastReadPointer = 0;
}

bool MAX30101::available() {
    uint8_t writePtr = 0;
    uint8_t readPtr = 0;

    if (!readRegister(
            REG_FIFO_WR_PTR,
            writePtr
        )) {
        return false;
    }

    if (!readRegister(
            REG_FIFO_RD_PTR,
            readPtr
        )) {
        return false;
    }

    return writePtr != readPtr;
}

bool MAX30101::readSample(
    uint32_t& red,
    uint32_t& ir
) {
    uint8_t data[6] = {};

    if (!readRegisters(
            REG_FIFO_DATA,
            data,
            sizeof(data)
        )) {
        return false;
    }

    red =
        (static_cast<uint32_t>(
             data[0]
         ) << 16) |
        (static_cast<uint32_t>(
             data[1]
         ) << 8) |
        static_cast<uint32_t>(
            data[2]
        );

    ir =
        (static_cast<uint32_t>(
             data[3]
         ) << 16) |
        (static_cast<uint32_t>(
             data[4]
         ) << 8) |
        static_cast<uint32_t>(
            data[5]
        );

    red &= 0x3FFFF;
    ir &= 0x3FFFF;

    return true;
}
