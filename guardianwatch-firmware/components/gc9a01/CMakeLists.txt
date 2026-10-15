idf_component_register(SRCS "gc9a01.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support esp_driver_spi esp_driver_gpio esp_driver_ledc)