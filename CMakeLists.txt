cmake_minimum_required(VERSION 3.20)
project(xsprof
  VERSION 0.1.0
  DESCRIPTION "Linux Scheduler & Memory Profiler (C++ rewrite of zig-scheduler)"
  LANGUAGES CXX)

# ---- build posture -------------------------------------------------------
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(XSPROF_BUILD_TESTS "Build xsprof tests" ON)

add_compile_options(-Wall -Wextra -Wpedantic)

# ---- core library --------------------------------------------------------
add_library(xsprof_core STATIC
  src/core/json.cpp
  src/core/event.cpp
  src/core/privacy.cpp
  src/safety/safety.cpp
  src/collectors/proc.cpp
  src/viz/chrome_trace.cpp
  src/advisor/advisor.cpp
)
target_include_directories(xsprof_core PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ---- CLI -----------------------------------------------------------------
add_executable(xsprof src/cli/main.cpp)
target_link_libraries(xsprof PRIVATE xsprof_core)

# ---- BPF (CO-RE) optional, never required for the host build -------------
find_program(BPFTOOL_EXECUTABLE bpftool)
find_program(CLANG_EXECUTABLE clang)
if(BPFTOOL_EXECUTABLE AND CLANG_EXECUTABLE AND EXISTS "/sys/kernel/btf/vmlinux")
  set(XSPROF_BPF_AVAILABLE ON)
else()
  set(XSPROF_BPF_AVAILABLE OFF)
  message(STATUS "xsprof: BPF CO-RE build SKIP (bpftool/clang/BTF not all present)")
endif()

# ---- tests ---------------------------------------------------------------
if(XSPROF_BUILD_TESTS)
  enable_testing()
  find_package(Catch2 3 QUIET)
  add_executable(xsprof_tests
    tests/test_main.cpp
    tests/json_tests.cpp
    tests/privacy_tests.cpp
    tests/safety_tests.cpp
    tests/proc_tests.cpp
    tests/advisor_tests.cpp
    tests/viz_tests.cpp
  )
  target_include_directories(xsprof_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
  if(Catch2_FOUND)
    target_link_libraries(xsprof_tests PRIVATE xsprof_core Catch2::Catch2WithMain)
    include(Catch)
    catch_discover_tests(xsprof_tests)
  else()
    # Fallback: no Catch2 available -> build the self-contained suite instead.
    message(STATUS "xsprof: Catch2 not found; building self-contained selftest")
    target_sources(xsprof_tests PRIVATE tests/selftest.cpp)
    target_link_libraries(xsprof_tests PRIVATE xsprof_core)
    # selftest.cpp defines main(); drop the Catch2 entry unit in that case.
    set_source_files_properties(tests/test_main.cpp PROPERTIES HEADER_FILE_ONLY TRUE)
    add_test(NAME xsprof_tests COMMAND xsprof_tests)
  endif()
endif()

install(TARGETS xsprof RUNTIME DESTINATION bin)
