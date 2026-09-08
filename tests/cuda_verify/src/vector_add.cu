#include "cuda_verify/vector_add.hpp"

#include <cuda_runtime.h>

#include <cmath>
#include <sstream>
#include <vector>

namespace cuda_verify
{

namespace
{
__global__ void vector_add_kernel(const float * a, const float * b, float * c, std::size_t n)
{
  const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) {
    c[i] = a[i] + b[i];
  }
}
}  // namespace

std::string describe_versions()
{
  std::ostringstream os;
  os << "compiled_with_cuda=" << (CUDART_VERSION / 1000) << "."
     << (CUDART_VERSION % 1000) / 10;

  int runtime_version = 0;
  int driver_version = 0;
  if (cudaRuntimeGetVersion(&runtime_version) == cudaSuccess) {
    os << " runtime=" << runtime_version / 1000 << "." << (runtime_version % 1000) / 10;
  }
  if (cudaDriverGetVersion(&driver_version) == cudaSuccess) {
    os << " driver=" << driver_version / 1000 << "." << (driver_version % 1000) / 10;
  }
  return os.str();
}

std::string describe_devices()
{
  int count = 0;
  const cudaError_t err = cudaGetDeviceCount(&count);
  if (err != cudaSuccess) {
    return std::string("cudaGetDeviceCount failed: ") + cudaGetErrorString(err);
  }

  std::ostringstream os;
  os << "devices=" << count;
  for (int i = 0; i < count; ++i) {
    cudaDeviceProp prop{};
    if (cudaGetDeviceProperties(&prop, i) != cudaSuccess) {
      continue;
    }
    os << "\n  [" << i << "] " << prop.name
       << " sm_" << prop.major << prop.minor
       << " SMs=" << prop.multiProcessorCount
       << " mem=" << (prop.totalGlobalMem >> 20) << "MiB"
       << " integrated=" << (prop.integrated ? "yes" : "no");
  }
  return os.str();
}

bool run_vector_add(std::size_t n, std::string & error)
{
  std::vector<float> h_a(n), h_b(n), h_c(n, 0.0F);
  for (std::size_t i = 0; i < n; ++i) {
    h_a[i] = static_cast<float>(i);
    h_b[i] = static_cast<float>(2 * i);
  }

  float * d_a = nullptr;
  float * d_b = nullptr;
  float * d_c = nullptr;
  const std::size_t bytes = n * sizeof(float);

  auto cleanup = [&]() {
      cudaFree(d_a);
      cudaFree(d_b);
      cudaFree(d_c);
    };

  auto check = [&](cudaError_t e, const char * what) {
      if (e != cudaSuccess) {
        error = std::string(what) + ": " + cudaGetErrorString(e);
        cleanup();
        return false;
      }
      return true;
    };

  if (!check(cudaMalloc(&d_a, bytes), "cudaMalloc a")) {return false;}
  if (!check(cudaMalloc(&d_b, bytes), "cudaMalloc b")) {return false;}
  if (!check(cudaMalloc(&d_c, bytes), "cudaMalloc c")) {return false;}
  if (!check(cudaMemcpy(d_a, h_a.data(), bytes, cudaMemcpyHostToDevice), "H2D a")) {return false;}
  if (!check(cudaMemcpy(d_b, h_b.data(), bytes, cudaMemcpyHostToDevice), "H2D b")) {return false;}

  const int threads = 256;
  const int blocks = static_cast<int>((n + threads - 1) / threads);
  vector_add_kernel<<<blocks, threads>>>(d_a, d_b, d_c, n);

  if (!check(cudaGetLastError(), "kernel launch")) {return false;}
  if (!check(cudaDeviceSynchronize(), "kernel execution")) {return false;}
  if (!check(cudaMemcpy(h_c.data(), d_c, bytes, cudaMemcpyDeviceToHost), "D2H c")) {return false;}

  cleanup();

  for (std::size_t i = 0; i < n; ++i) {
    const float expected = static_cast<float>(3 * i);
    if (std::fabs(h_c[i] - expected) > 1e-3F) {
      error = "incorrect result at index " + std::to_string(i);
      return false;
    }
  }
  return true;
}

}  // namespace cuda_verify
