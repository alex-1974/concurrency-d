#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

constexpr std::size_t Warmups = 4;
constexpr std::size_t Samples = 16;

struct State {
  std::atomic<std::int64_t> top {0};
  std::atomic<std::int64_t> bottom {0};
};

std::uint64_t run(
  State& state,
  std::size_t iterations,
  std::uint64_t& checksum
) {
  state.top.store(
    0,
    std::memory_order_relaxed
  );

  state.bottom.store(
    static_cast<std::int64_t>(iterations) + 1,
    std::memory_order_relaxed
  );

  std::uint64_t local = 0;

  const auto begin =
    std::chrono::steady_clock::now();

  for(std::size_t i = 0; i < iterations; ++i) {
    auto b =
      state.bottom.load(
        std::memory_order_relaxed
      ) - 1;

    state.bottom.store(
      b,
      std::memory_order_relaxed
    );

    std::atomic_thread_fence(
      std::memory_order_seq_cst
    );

    const auto t =
      state.top.load(
        std::memory_order_relaxed
      );

    local +=
      static_cast<std::uint64_t>(b - t);
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

  State state;
  std::uint64_t checksum = 0;

  for(std::size_t i = 0; i < Warmups; ++i) {
    run(
      state,
      iterations,
      checksum
    );
  }

  std::uint64_t times[Samples];

  for(std::size_t i = 0; i < Samples; ++i) {
    times[i] =
      run(
        state,
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
    "C++ pop-protocol: %.3f ns/iteration checksum=%llu\n",
    median / iterations,
    static_cast<unsigned long long>(
      checksum
    )
  );
}
