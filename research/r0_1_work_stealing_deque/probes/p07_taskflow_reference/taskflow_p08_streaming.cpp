#include <taskflow/core/wsq.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <pthread.h>
#include <sched.h>
#include <thread>
#include <vector>

namespace {

constexpr std::size_t LogSize = 12;
constexpr std::size_t Capacity = std::size_t{1} << LogSize;

using Queue =
  tf::BoundedWSQ<std::size_t, LogSize>;

struct RunResult {
  std::uint64_t elapsed_ns;
  std::uint64_t checksum;
  std::size_t push_retries;
  std::size_t steal_retries;
};

struct Stats {
  double median_ns;
  double p10_ns;
  double p90_ns;
};

void pin_current_thread(std::size_t cpu) {
  cpu_set_t mask;
  CPU_ZERO(&mask);
  CPU_SET(cpu, &mask);

  const int rc =
    pthread_setaffinity_np(
      pthread_self(),
      sizeof(mask),
      &mask
    );

  if(rc != 0) {
    std::fprintf(
      stderr,
      "pthread_setaffinity_np failed: %d\n",
      rc
    );
    std::abort();
  }

  const int actual = sched_getcpu();

  if(
    actual < 0 ||
    static_cast<std::size_t>(actual) != cpu
  ) {
    std::fprintf(
      stderr,
      "affinity verification failed: wanted=%zu actual=%d\n",
      cpu,
      actual
    );
    std::abort();
  }
}

RunResult run_concurrent(
  std::size_t items,
  std::size_t owner_cpu,
  std::size_t thief_cpu
) {
  Queue queue;

  std::atomic<bool> start{false};

  std::uint64_t thief_checksum = 0;
  std::size_t thief_count = 0;
  std::size_t thief_retries = 0;

  std::thread thief([
    &
  ] {
    pin_current_thread(thief_cpu);

    while(!start.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }

    std::uint64_t local_checksum = 0;
    std::size_t local_count = 0;
    std::size_t local_retries = 0;

    while(local_count < items) {
      const auto result =
        queue.steal();

      if(result) {
        local_checksum +=
          static_cast<std::uint64_t>(*result);

        ++local_count;
      }
      else {
        ++local_retries;

        if((local_retries & 255u) == 0) {
          std::this_thread::yield();
        }
      }
    }

    thief_checksum =
      local_checksum;

    thief_count =
      local_count;

    thief_retries =
      local_retries;
  });

  pin_current_thread(owner_cpu);

  std::size_t push_retries = 0;

  start.store(
    true,
    std::memory_order_release
  );

  const auto begin =
    std::chrono::steady_clock::now();

  for(std::size_t i = 0; i < items; ++i) {
    const auto value = i + 1;

    while(!queue.try_push(value)) {
      ++push_retries;

      if((push_retries & 255u) == 0) {
        std::this_thread::yield();
      }
    }
  }

  thief.join();

  const auto end =
    std::chrono::steady_clock::now();

  const auto elapsed =
    static_cast<std::uint64_t>(
      std::chrono::duration_cast<
        std::chrono::nanoseconds
      >(end - begin).count()
    );

  const std::uint64_t expected =
    static_cast<std::uint64_t>(items) *
    static_cast<std::uint64_t>(items + 1) /
    2;

  if(thief_count != items) {
    std::fprintf(
      stderr,
      "count mismatch: %zu != %zu\n",
      thief_count,
      items
    );
    std::abort();
  }

  if(thief_checksum != expected) {
    std::fprintf(
      stderr,
      "checksum mismatch\n"
    );
    std::abort();
  }

  return {
    elapsed,
    thief_checksum,
    push_retries,
    thief_retries
  };
}

Stats calculate_stats(
  std::vector<std::uint64_t> times,
  std::size_t items
) {
  std::sort(
    times.begin(),
    times.end()
  );

  const auto n = times.size();

  const double median =
    (n & 1u)
      ? static_cast<double>(
          times[n / 2]
        )
      : (
          static_cast<double>(
            times[n / 2 - 1]
          ) +
          static_cast<double>(
            times[n / 2]
          )
        ) / 2.0;

  const auto p10 =
    (n - 1) * 10 / 100;

  const auto p90 =
    (n - 1) * 90 / 100;

  return {
    median / items,
    static_cast<double>(times[p10]) /
      items,
    static_cast<double>(times[p90]) /
      items
  };
}

void benchmark(
  std::size_t items,
  std::size_t warmups,
  std::size_t samples,
  std::size_t owner_cpu,
  std::size_t thief_cpu
) {
  for(std::size_t i = 0; i < warmups; ++i) {
    run_concurrent(
      items,
      owner_cpu,
      thief_cpu
    );
  }

  std::vector<std::uint64_t>
    times(samples);

  std::uint64_t aggregate_checksum = 0;
  std::size_t aggregate_push_retries = 0;
  std::size_t aggregate_steal_retries = 0;

  for(std::size_t i = 0; i < samples; ++i) {
    const auto result =
      run_concurrent(
        items,
        owner_cpu,
        thief_cpu
      );

    times[i] =
      result.elapsed_ns;

    aggregate_checksum +=
      result.checksum;

    aggregate_push_retries +=
      result.push_retries;

    aggregate_steal_retries +=
      result.steal_retries;
  }

  const auto stats =
    calculate_stats(
      std::move(times),
      items
    );

  std::printf(
    "taskflow median=%8.3f ns/item p10/p90=%8.3f/%8.3f\n",
    stats.median_ns,
    stats.p10_ns,
    stats.p90_ns
  );

  std::printf(
    "taskflow retries push=%zu steal=%zu\n",
    aggregate_push_retries,
    aggregate_steal_retries
  );

  std::printf(
    "checksum=%llu\n",
    static_cast<unsigned long long>(
      aggregate_checksum
    )
  );
}

} // namespace

int main(int argc, char** argv) {
  std::size_t items = 4'000'000;
  std::size_t warmups = 4;
  std::size_t samples = 15;
  std::size_t owner_cpu = 2;
  std::size_t thief_cpu = 3;

  if(argc > 1) {
    items =
      static_cast<std::size_t>(
        std::strtoull(
          argv[1],
          nullptr,
          10
        )
      );
  }

  if(argc > 2) {
    warmups =
      static_cast<std::size_t>(
        std::strtoull(
          argv[2],
          nullptr,
          10
        )
      );
  }

  if(argc > 3) {
    samples =
      static_cast<std::size_t>(
        std::strtoull(
          argv[3],
          nullptr,
          10
        )
      );
  }

  if(argc > 4) {
    owner_cpu =
      static_cast<std::size_t>(
        std::strtoull(
          argv[4],
          nullptr,
          10
        )
      );
  }

  if(argc > 5) {
    thief_cpu =
      static_cast<std::size_t>(
        std::strtoull(
          argv[5],
          nullptr,
          10
        )
      );
  }

  if(items == 0 || samples < 5) {
    return 2;
  }

  std::printf(
    "R0.1 P08 Taskflow streaming parity\n"
  );

  std::printf(
    "items=%zu capacity=%zu warmups=%zu samples=%zu\n",
    items,
    Capacity,
    warmups,
    samples
  );

  std::printf(
    "ownerCpu=%zu thiefCpu=%zu\n",
    owner_cpu,
    thief_cpu
  );

  benchmark(
    items,
    warmups,
    samples,
    owner_cpu,
    thief_cpu
  );

  std::printf(
    "R0.1 P08 Taskflow PASS\n"
  );

  return 0;
}
