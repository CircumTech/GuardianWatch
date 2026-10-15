idf_component_register(SRCS "max30205.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)