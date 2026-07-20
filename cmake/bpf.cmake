# xsprof BPF CO-RE module (optional, never required for host build).
# The loader is always compiled (it refuses on host); actual BPF object
# compilation requires clang + bpftool + BTF and is VM-lab-only.
set(XSPROF_BPF_SOURCES src/bpf/loader.cpp)

# BPF loader test sources (added to xsprof_tests by root CMakeLists.txt).
set(XSPROF_BPF_TEST_SOURCES tests/bpf_loader_tests.cpp)

# BPF object compilation (VM-lab-only, never runs on host CI).
# When XSPROF_BPF_AVAILABLE is ON (set in root CMakeLists.txt), we could
# add custom commands to compile .bpf.c -> .bpf.o here. For now the
# objects are pre-built or built in the VM lab.
if(XSPROF_BPF_AVAILABLE)
  message(STATUS "xsprof: BPF CO-RE objects can be built (clang+bpftool+BTF present)")
  # Future: add_custom_command to compile bpf/sched_monitor.bpf.c and
  # bpf/mem_monitor.bpf.c into .bpf.o + skeleton headers.
endif()
