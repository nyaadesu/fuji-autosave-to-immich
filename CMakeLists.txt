cmake_minimum_required(VERSION 3.15)
project(fuji-autosave-receiver C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# The receiver supplies libpict's log/panic hooks itself
set(PTP_DEFAULT_LOGGING OFF CACHE BOOL "" FORCE)
set(PTP_INCLUDE_BIND OFF CACHE BOOL "" FORCE)

if(NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libfuji/libpict/CMakeLists.txt)
    message(FATAL_ERROR "libfuji submodules missing; run scripts/fetch-deps.sh")
endif()
add_subdirectory(third_party/libfuji EXCLUDE_FROM_ALL)

add_executable(fuji-autosave-receiver
    src/main.c
    src/seen.c
)
target_compile_definitions(fuji-autosave-receiver PRIVATE _GNU_SOURCE)
target_compile_options(fuji-autosave-receiver PRIVATE -Wall -Wextra -Wshadow)
target_link_libraries(fuji-autosave-receiver PRIVATE fuji)

install(TARGETS fuji-autosave-receiver RUNTIME DESTINATION bin)
install(PROGRAMS scripts/immich-hook DESTINATION lib/fuji-autosave)
