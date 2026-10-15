idf_component_register(SRCS "lis2dw12.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_i2c)