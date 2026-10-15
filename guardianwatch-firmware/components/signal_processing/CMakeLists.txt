idf_component_register(SRCS "signal_processing.c"
                       INCLUDE_DIRS "."
                       REQUIRES signal_quality max30101 lis2dw12 data_manager esp_timer)