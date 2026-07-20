# xsprof daemon module — foreground stdio JSONL + local UDS JSON-RPC + replay.
# Mirrors the archived Zig daemon contract (daemon-event/v1, operator-action/v1).
set(XSPROF_DAEMON_SOURCES src/daemon/daemon.cpp)

# Daemon test sources (added to xsprof_tests by root CMakeLists.txt).
set(XSPROF_DAEMON_TEST_SOURCES tests/daemon_tests.cpp)
