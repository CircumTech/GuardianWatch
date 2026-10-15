idf_component_register(SRCS "app_main.c"
                       INCLUDE_DIRS "."
                       REQUIRES board_support
                                power_manager
                                max30101
                                max30205
                                ad8232_ads1115
                                lis2dw12
                                gc9a01
                                w25q64jv
                                max17048
                                signal_quality
                                signal_processing
                                data_manager
                                ble_manager
                                ui_manager
                                security_manager
                                nvs_flash
                                esp_timer)