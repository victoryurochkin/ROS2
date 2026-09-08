cmake_minimum_required(VERSION 3.18)
project(cuda_verify LANGUAGES CXX)

# ---------------------------------------------------------------------------
# Пакет существует ради одной цели: доказать, что в собранном образе
# CUDA действительно работоспособна, а не просто «лежит рядом».
#   * enable_language(CUDA) -> сборка падает, если nvcc нерабочий;
#   * CMAKE_CUDA_ARCHITECTURES -> в .so зашивается код под нужную SM;
#   * cuda_smoke -> рантайм-проверка на реальном GPU.
# ---------------------------------------------------------------------------

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  if(DEFINED ENV{CMAKE_CUDA_ARCHITECTURES})
    set(CMAKE_CUDA_ARCHITECTURES $ENV{CMAKE_CUDA_ARCHITECTURES})
  else()
    set(CMAKE_CUDA_ARCHITECTURES 87)
  endif()
endif()
message(STATUS "cuda_verify: CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES}")

enable_language(CUDA)
find_package(CUDAToolkit REQUIRED)

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

# --- CUDA-ядро в отдельной библиотеке --------------------------------------
add_library(cuda_verify_kernels SHARED src/vector_add.cu)
target_include_directories(cuda_verify_kernels PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
set_target_properties(cuda_verify_kernels PROPERTIES
  CUDA_SEPARABLE_COMPILATION ON
  POSITION_INDEPENDENT_CODE ON)
target_link_libraries(cuda_verify_kernels PUBLIC CUDA::cudart)

# --- CLI-утилита: работает без ROS, используется в CI ----------------------
add_executable(cuda_smoke src/cuda_smoke.cpp)
target_link_libraries(cuda_smoke cuda_verify_kernels)

# --- ROS 2 нода: публикует параметры GPU в топик ---------------------------
add_executable(cuda_info_node src/cuda_info_node.cpp)
target_link_libraries(cuda_info_node cuda_verify_kernels)
ament_target_dependencies(cuda_info_node rclcpp std_msgs)

install(TARGETS cuda_verify_kernels
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin)
install(TARGETS cuda_smoke cuda_info_node
  DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY include/ DESTINATION include)

ament_package()
