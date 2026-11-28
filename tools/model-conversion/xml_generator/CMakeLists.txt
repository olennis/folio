cmake_minimum_required(VERSION 3.10)
project(xml_generator CXX)
set(CMAKE_CXX_STANDARD 14)
# DLIB_SOURCE: 내려받은 dlib 소스의 dlib 폴더. convert.sh가 넘긴다.
add_subdirectory(${DLIB_SOURCE} dlib_build)
add_executable(xml_generator main.cpp)
target_link_libraries(xml_generator dlib::dlib)
