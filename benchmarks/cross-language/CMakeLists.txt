cmake_minimum_required(VERSION 3.20)
project(concurrency_taskflow_reference LANGUAGES CXX)

include(FetchContent)
set(TF_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(TF_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(TF_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(taskflow
    GIT_REPOSITORY https://github.com/taskflow/taskflow.git
    GIT_TAG 45366fe5bc4f2f8ec9aa590b40c504e296886865)
FetchContent_MakeAvailable(taskflow)

set(TBB_TEST OFF CACHE BOOL "" FORCE)
set(TBB_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_Declare(onetbb
    GIT_REPOSITORY https://github.com/uxlfoundation/oneTBB.git
    GIT_TAG 3046c8b0c29df995980003ea24f4d78c80ec0c8d)
FetchContent_MakeAvailable(onetbb)

add_executable(taskflow_reference taskflow.cpp)
target_link_libraries(taskflow_reference PRIVATE Taskflow)
target_compile_features(taskflow_reference PRIVATE cxx_std_20)
add_executable(onetbb_reference onetbb.cpp)
target_link_libraries(onetbb_reference PRIVATE TBB::tbb)
target_compile_features(onetbb_reference PRIVATE cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(taskflow_reference PRIVATE -O3 -DNDEBUG)
    target_compile_options(onetbb_reference PRIVATE -O3 -DNDEBUG)
endif()
