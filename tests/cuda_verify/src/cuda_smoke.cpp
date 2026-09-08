// Автономная проверка CUDA. Используется в scripts/verify-image.sh и в CI.
// Код возврата: 0 — GPU работает, 2 — GPU недоступен (нормально для кросс-
// сборки на x86-раннере без GPU), 1 — GPU есть, но результат неверный.
#include "cuda_verify/vector_add.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

int main(int argc, char ** argv)
{
  const std::size_t n = (argc > 1) ? std::strtoul(argv[1], nullptr, 10) : (1U << 20);

  std::cout << "[cuda_verify] " << cuda_verify::describe_versions() << std::endl;
  const std::string devices = cuda_verify::describe_devices();
  std::cout << "[cuda_verify] " << devices << std::endl;

  if (devices.rfind("devices=0", 0) == 0 || devices.rfind("cudaGetDeviceCount failed", 0) == 0) {
    std::cout << "[cuda_verify] SKIP: GPU недоступен в этом окружении" << std::endl;
    return 2;
  }

  std::string error;
  if (!cuda_verify::run_vector_add(n, error)) {
    std::cerr << "[cuda_verify] FAIL: " << error << std::endl;
    return 1;
  }

  std::cout << "[cuda_verify] OK: vector_add на " << n << " элементов выполнен на GPU"
            << std::endl;
  return 0;
}
