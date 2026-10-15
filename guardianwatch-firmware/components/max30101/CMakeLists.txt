idf_component_register(SRCS "max30101.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c esp_driver_gpio)