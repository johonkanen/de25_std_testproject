cmake_minimum_required(VERSION 3.5...3.28)

include(FetchContent)
set(BUILD_TESTS OFF)

FetchContent_Declare(
    esw_bare
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/../baremetal-drivers
)
FetchContent_MakeAvailable(esw_bare)

set(ALTERAMETAL_LINKER_SCRIPT "${esw_bare_SOURCE_DIR}/build/aarch64/core0_ocram.ld")

project(hps_lwh2f_regs C ASM)

add_executable(hps_lwh2f_regs.elf)
generate_bin_file(hps_lwh2f_regs.elf)

target_sources(hps_lwh2f_regs.elf PRIVATE hps_lwh2f_regs.c clkmgr_bringup.c vectors.S)
target_link_libraries(hps_lwh2f_regs.elf PRIVATE alterametal)
target_link_options(hps_lwh2f_regs.elf PRIVATE -T${ALTERAMETAL_LINKER_SCRIPT})
