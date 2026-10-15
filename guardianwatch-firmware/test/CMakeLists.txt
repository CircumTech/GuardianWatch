idf_component_register(SRCS "test_main.c"
                       INCLUDE_DIRS "."
                       REQUIRES unity board_support max30101 max30205 lis2dw12
                                max17048 gc9a01 w25q64jv signal_quality
                                signal_processing data_manager security_manager)
