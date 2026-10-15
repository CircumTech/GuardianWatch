idf_component_register(SRCS "data_manager.c"
                       INCLUDE_DIRS "."
                       REQUIRES w25q64jv max30101 lis2dw12 nvs_flash esp_timer)