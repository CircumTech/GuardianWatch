idf_component_register(SRCS "power_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support max17048 esp_driver_gpio esp_timer nvs_flash)