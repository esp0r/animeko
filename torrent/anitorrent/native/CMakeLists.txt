cmake_minimum_required(VERSION 3.24)
project(anitorrent_c LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include(FetchContent)

FetchContent_Declare(anitorrent_source
    GIT_REPOSITORY https://github.com/open-ani/anitorrent.git
    GIT_TAG 5375cf5db748ad8d9c72cf2b0a21e9b311dfdfed
    SOURCE_SUBDIR unused)
FetchContent_MakeAvailable(anitorrent_source)
set(ani_cpp "${anitorrent_source_SOURCE_DIR}/anitorrent-native/cpp")
# The pinned Anitorrent source includes the same Boost headers used on Android.
set(Boost_INCLUDE_DIR "${ani_cpp}/libs/boost" CACHE PATH "Boost headers" FORCE)
set(Boost_NO_BOOST_CMAKE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Static libraries" FORCE)
set(build_tests OFF CACHE BOOL "Dependency tests" FORCE)
set(build_examples OFF CACHE BOOL "Dependency examples" FORCE)
set(python-bindings OFF CACHE BOOL "Python bindings" FORCE)
set(OPENSSL_USE_STATIC_LIBS TRUE)
add_compile_definitions(TORRENT_ABI_VERSION=3 TORRENT_HAVE_MMAP=0)
FetchContent_Declare(libtorrent
    GIT_REPOSITORY https://github.com/arvidn/libtorrent.git
    GIT_TAG 74bc93a37a5e31c78f0aa02037a68fb9ac5deb41)
FetchContent_MakeAvailable(libtorrent)

add_library(anitorrent_c STATIC
    anitorrent_c.cpp
    "${ani_cpp}/src/events.cpp"
    "${ani_cpp}/src/torrent_info_t.cpp"
    "${ani_cpp}/src/torrent_add_info_t.cpp"
    "${ani_cpp}/src/session_t.cpp"
    "${ani_cpp}/src/torrent_handle_t.cpp"
    "${ani_cpp}/src/global_lock.cpp"
    "${ani_cpp}/src/plugin/peer_filter_plugin.cpp"
    "${ani_cpp}/src/peer_filter.cpp")
target_include_directories(anitorrent_c PUBLIC include PRIVATE "${ani_cpp}/include")
target_link_libraries(anitorrent_c PUBLIC torrent-rasterbar)
install(TARGETS anitorrent_c ARCHIVE DESTINATION lib)
install(FILES include/anitorrent_c.h DESTINATION include)
