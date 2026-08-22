cmake_minimum_required(VERSION 3.20)
project(edge_asic LANGUAGES NONE)
include(CTest)

find_program(EDGE_ASIC_VERILATOR verilator)
if(EDGE_ASIC_VERILATOR)
  set(edge_asic_power_obj
    "${CMAKE_CURRENT_BINARY_DIR}/edge_asic_power_ctrl")
  set(edge_asic_power_exe
    "${edge_asic_power_obj}/Vedge_asic_power_ctrl_tb")
  add_custom_command(
    OUTPUT "${edge_asic_power_exe}"
    COMMAND "${EDGE_ASIC_VERILATOR}" --binary --timing --sv
            --top-module edge_asic_power_ctrl_tb
            --Mdir "${edge_asic_power_obj}"
            "${CMAKE_CURRENT_LIST_DIR}/rtl/control/edge_asic_power_ctrl.v"
            "${CMAKE_CURRENT_LIST_DIR}/tests/edge_asic_power_ctrl_tb.v"
    DEPENDS
      "${CMAKE_CURRENT_LIST_DIR}/rtl/control/edge_asic_power_ctrl.v"
      "${CMAKE_CURRENT_LIST_DIR}/tests/edge_asic_power_ctrl_tb.v"
    VERBATIM)
  add_custom_target(edge_asic_power_ctrl_verilator
    DEPENDS "${edge_asic_power_exe}")
  add_test(NAME build_edge_asic_power_ctrl_verilator
    COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}"
            --target edge_asic_power_ctrl_verilator)
  set_tests_properties(build_edge_asic_power_ctrl_verilator PROPERTIES
    FIXTURES_SETUP edge_asic_power_ctrl_fixture
    LABELS "build;edge-asic;control;verilator")
  add_test(NAME edge_asic_power_ctrl COMMAND "${edge_asic_power_exe}")
  set_tests_properties(edge_asic_power_ctrl PROPERTIES
    FIXTURES_REQUIRED edge_asic_power_ctrl_fixture
    LABELS "edge-asic;control;rtl;verilator")

  set(edge_asic_owner_obj
    "${CMAKE_CURRENT_BINARY_DIR}/edge_asic_accel_owner")
  set(edge_asic_owner_exe
    "${edge_asic_owner_obj}/Vedge_asic_accel_owner_tb")
  add_custom_command(
    OUTPUT "${edge_asic_owner_exe}"
    COMMAND "${EDGE_ASIC_VERILATOR}" --binary --timing --sv
            --top-module edge_asic_accel_owner_tb
            --Mdir "${edge_asic_owner_obj}"
            "${CMAKE_CURRENT_LIST_DIR}/rtl/control/edge_asic_accel_owner.v"
            "${CMAKE_CURRENT_LIST_DIR}/tests/edge_asic_accel_owner_tb.v"
    DEPENDS
      "${CMAKE_CURRENT_LIST_DIR}/rtl/control/edge_asic_accel_owner.v"
      "${CMAKE_CURRENT_LIST_DIR}/tests/edge_asic_accel_owner_tb.v"
    VERBATIM)
  add_custom_target(edge_asic_accel_owner_verilator
    DEPENDS "${edge_asic_owner_exe}")
  add_test(NAME build_edge_asic_accel_owner_verilator
    COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}"
            --target edge_asic_accel_owner_verilator)
  set_tests_properties(build_edge_asic_accel_owner_verilator PROPERTIES
    FIXTURES_SETUP edge_asic_accel_owner_fixture
    LABELS "build;edge-asic;control;verilator")
  add_test(NAME edge_asic_accel_owner COMMAND "${edge_asic_owner_exe}")
  set_tests_properties(edge_asic_accel_owner PROPERTIES
    FIXTURES_REQUIRED edge_asic_accel_owner_fixture
    LABELS "edge-asic;control;rtl;verilator")

  foreach(edge_asic_dsp_mode IN ITEMS 0 1)
    set(edge_asic_mul_obj
      "${CMAKE_CURRENT_BINARY_DIR}/edge_bf16_sig_mul_${edge_asic_dsp_mode}")
    set(edge_asic_mul_exe
      "${edge_asic_mul_obj}/Vedge_bf16_sig_mul_tb")
    add_custom_command(
      OUTPUT "${edge_asic_mul_exe}"
      COMMAND "${EDGE_ASIC_VERILATOR}" --binary --timing -Wno-fatal
              --top-module edge_bf16_sig_mul_tb
              -GFPGA_DSP_MUL=${edge_asic_dsp_mode}
              --Mdir "${edge_asic_mul_obj}"
              "${CMAKE_CURRENT_LIST_DIR}/rtl/tensor/edge_bf16_sig_mul.v"
              "${CMAKE_CURRENT_LIST_DIR}/tests/edge_bf16_sig_mul_tb.v"
      DEPENDS
        "${CMAKE_CURRENT_LIST_DIR}/rtl/tensor/edge_bf16_sig_mul.v"
        "${CMAKE_CURRENT_LIST_DIR}/tests/edge_bf16_sig_mul_tb.v"
      VERBATIM)
    add_custom_target(edge_bf16_sig_mul_${edge_asic_dsp_mode}_verilator
      DEPENDS "${edge_asic_mul_exe}")
    add_test(
      NAME build_edge_bf16_sig_mul_${edge_asic_dsp_mode}_verilator
      COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}"
              --target edge_bf16_sig_mul_${edge_asic_dsp_mode}_verilator)
    set_tests_properties(
      build_edge_bf16_sig_mul_${edge_asic_dsp_mode}_verilator PROPERTIES
      FIXTURES_SETUP edge_bf16_sig_mul_${edge_asic_dsp_mode}_fixture
      LABELS "build;edge-asic;tensor;verilator")
    add_test(
      NAME edge_bf16_sig_mul_${edge_asic_dsp_mode}
      COMMAND "${edge_asic_mul_exe}")
    set_tests_properties(edge_bf16_sig_mul_${edge_asic_dsp_mode}
      PROPERTIES
      FIXTURES_REQUIRED edge_bf16_sig_mul_${edge_asic_dsp_mode}_fixture
      LABELS "edge-asic;tensor;rtl;verilator")
  endforeach()
endif()
