idf_component_register(SRCS "max17048.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)