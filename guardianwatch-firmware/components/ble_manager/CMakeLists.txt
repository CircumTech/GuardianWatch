idf_component_register(SRCS "ble_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES bt nvs_flash data_manager security_manager power_manager esp_timer)
