#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C"
std::int64_t cpp_pop_protocol_step(
  std::atomic<std::int64_t>*,
  std::atomic<std::int64_t>*
);

constexpr std::size_t Warmups = 4;
constexpr std::size_t Samples = 16;

std::uint64_t run(
  std::atomic<std::int64_t>& top,
  std::atomic<std::int64_t>& bottom,
  std::size_t iterations,
  std::uint64_t& checksum
) {
  top.store(
    0,
    std::memory_order_relaxed
  );

  bottom.store(
    static_cast<std::int64_t>(
      iterations
    ) + 1,
    std::memory_order_relaxed
  );

  std::uint64_t local = 0;

  const auto begin =
    std::chrono::steady_clock::now();

  for(std::size_t i = 0; i < iterations; ++i) {
    local += static_cast<std::uint64_t>(
      cpp_pop_protocol_step(
        &top,
        &bottom
      )
    );
  }

  const auto end =
    std::chrono::steady_clock::now();

  checksum += local;

  return static_cast<std::uint64_t>(
    std::chrono::duration_cast<
      std::chrono::nanoseconds
    >(end - begin).count()
  );
}

int main(int argc, char** argv) {
  std::size_t iterations = 20'000'000;

  if(argc > 1) {
    iterations =
      static_cast<std::size_t>(
        std::strtoull(
          argv[1],
          nullptr,
          10
        )
      );
  }

  std::atomic<std::int64_t> top {0};
  std::atomic<std::int64_t> bottom {0};

  std::uint64_t checksum = 0;

  for(std::size_t i = 0; i < Warmups; ++i) {
    run(
      top,
      bottom,
      iterations,
      checksum
    );
  }

  std::uint64_t times[Samples];

  for(std::size_t i = 0; i < Samples; ++i) {
    times[i] =
      run(
        top,
        bottom,
        iterations,
        checksum
      );
  }

  std::sort(
    times,
    times + Samples
  );

  const double median = (
    static_cast<double>(
      times[Samples / 2 - 1]
    ) +
    static_cast<double>(
      times[Samples / 2]
    )
  ) / 2.0;

  std::printf(
    "C++ separate pop-protocol: %.3f ns/iteration checksum=%llu\n",
    median / iterations,
    static_cast<unsigned long long>(
      checksum
    )
  );
}
