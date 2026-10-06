#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>

constexpr std::size_t Warmups = 4;
constexpr std::size_t Samples = 16;

std::uint64_t run(std::size_t iterations) {
  const auto begin = std::chrono::steady_clock::now();

  for(std::size_t i = 0; i < iterations; ++i) {
    std::atomic_thread_fence(std::memory_order_seq_cst);
  }

  const auto end = std::chrono::steady_clock::now();

  return static_cast<std::uint64_t>(
    std::chrono::duration_cast<std::chrono::nanoseconds>(
      end - begin
    ).count()
  );
}

int main(int argc, char** argv) {
  std::size_t iterations = 20'000'000;

  if(argc > 1) {
    iterations = static_cast<std::size_t>(
      std::strtoull(argv[1], nullptr, 10)
    );
  }

  for(std::size_t i = 0; i < Warmups; ++i) {
    run(iterations);
  }

  std::uint64_t times[Samples];

  for(std::size_t i = 0; i < Samples; ++i) {
    times[i] = run(iterations);
  }

  std::sort(times, times + Samples);

  const double median = (
    static_cast<double>(times[Samples / 2 - 1]) +
    static_cast<double>(times[Samples / 2])
  ) / 2.0;

  std::printf(
    "C++ atomic_thread_fence(seq_cst): %.3f ns/fence\n",
    median / iterations
  );
}
