idf_component_register(SRCS "security_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES nvs_flash mbedtls esp_timer)