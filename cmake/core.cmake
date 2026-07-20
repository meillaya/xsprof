# xsprof core module sources (json, event, privacy, safety, proc, viz, advisor).
# This file is included by the root CMakeLists.txt; parallel lanes never edit
# the root build file — they add their module's cmake/<name>.cmake instead.
set(XSPROF_CORE_SOURCES
  src/core/json.cpp
  src/core/event.cpp
  src/core/privacy.cpp
  src/safety/safety.cpp
  src/collectors/proc.cpp
  src/collectors/live_capture.cpp
  src/viz/chrome_trace.cpp
  src/advisor/advisor.cpp
  src/pipeline/pipeline.cpp
)
