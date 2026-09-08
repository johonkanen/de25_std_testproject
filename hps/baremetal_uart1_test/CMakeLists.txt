cmake_minimum_required(VERSION 3.5...3.28)

include(FetchContent)
set(BUILD_TESTS OFF)

FetchContent_Declare(
    esw_bare
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/../baremetal-drivers
)
FetchContent_MakeAvailable(esw_bare)

set(ALTERAMETAL_LINKER_SCRIPT "${esw_bare_SOURCE_DIR}/build/aarch64/core0_ocram.ld")

project(hps_uart1_test C ASM)

add_executable(hps_uart1_test.elf)
generate_bin_file(hps_uart1_test.elf)

target_sources(hps_uart1_test.elf PRIVATE hps_uart1_test.c clkmgr_bringup.c)
target_link_libraries(hps_uart1_test.elf PRIVATE alterametal)
target_link_options(hps_uart1_test.elf PRIVATE -T${ALTERAMETAL_LINKER_SCRIPT})
