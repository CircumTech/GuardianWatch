#include "driver/adc.h"

#define ECG_ADC_CHANNEL ADC_CHANNEL_0

void ecg_init()
{
    adc1_config_width(ADC_WIDTH_BIT_12);

    adc1_config_channel_atten(ECG_ADC_CHANNEL,
                              ADC_ATTEN_DB_11);
}

int ecg_read()
{
    return adc1_get_raw(ECG_ADC_CHANNEL);
}