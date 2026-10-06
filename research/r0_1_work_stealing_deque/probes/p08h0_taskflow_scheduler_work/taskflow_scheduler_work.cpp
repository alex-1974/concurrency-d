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

constexpr std::size_t LogSize = 20;
constexpr std::size_t Capacity =
  std::size_t{1} << LogSize;

constexpr std::size_t MaxThieves = 8;

constexpr std::size_t ThiefCpus[MaxThieves] = {
  3, 4, 1, 5, 0, 9, 10, 7
};

using Queue =
  tf::BoundedWSQ<std::size_t, LogSize>;

struct RunResult {
  std::uint64_t elapsed_ns;

  std::uint64_t value_checksum;
  std::uint64_t work_checksum;

  std::size_t owner_popped;
  std::size_t stolen;
  std::size_t steal_retries;
};

struct Stats {
  double median_ns;
  double p10_ns;
  double p90_ns;
};

void pin_current_thread(
  std::size_t cpu
) {
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

  const int actual =
    sched_getcpu();

  if(
    actual < 0 ||
    static_cast<std::size_t>(actual) != cpu
  ) {
    std::fprintf(
      stderr,
      "affinity mismatch wanted=%zu actual=%d\n",
      cpu,
      actual
    );
    std::abort();
  }
}

std::uint64_t perform_work(
  std::size_t value,
  std::size_t rounds
) {
  std::uint64_t x =
    static_cast<std::uint64_t>(value) +
    0x9e3779b97f4a7c15ULL;

  for(
    std::size_t i = 0;
    i < rounds;
    ++i
  ) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;

    x *=
      0x2545f4914f6cdd1dULL;

    x +=
      static_cast<std::uint64_t>(i) +
      0x9e3779b97f4a7c15ULL;
  }

  return x;
}

std::uint64_t expected_work_checksum(
  std::size_t items,
  std::size_t rounds
) {
  std::uint64_t result = 0;

  for(
    std::size_t value = 1;
    value <= items;
    ++value
  ) {
    result +=
      perform_work(
        value,
        rounds
      );
  }

  return result;
}

RunResult run_drain(
  std::size_t items,
  std::size_t thief_count,
  std::size_t owner_cpu,
  std::size_t work_rounds,
  std::uint64_t expected_work
) {
  Queue queue;

  for(
    std::size_t i = 0;
    i < items;
    ++i
  ) {
    if(!queue.try_push(i + 1)) {
      std::fprintf(
        stderr,
        "prefill failed\n"
      );
      std::abort();
    }
  }

  std::atomic<bool> start{false};
  std::atomic<std::size_t> ready{0};

  std::uint64_t thief_value_checksums[MaxThieves]{};
  std::uint64_t thief_work_checksums[MaxThieves]{};

  std::size_t thief_counts[MaxThieves]{};
  std::size_t thief_retries[MaxThieves]{};

  std::vector<std::thread> thieves;
  thieves.reserve(thief_count);

  for(
    std::size_t index = 0;
    index < thief_count;
    ++index
  ) {
    thieves.emplace_back([
      &,
      index
    ] {
      pin_current_thread(
        ThiefCpus[index]
      );

      ready.fetch_add(
        1,
        std::memory_order_release
      );

      while(
        !start.load(
          std::memory_order_acquire)
      ) {
        std::this_thread::yield();
      }

      std::uint64_t value_checksum = 0;
      std::uint64_t work_checksum = 0;

      std::size_t count = 0;
      std::size_t retries = 0;

      for(;;) {
        const auto result =
          queue.steal();

        if(result) {
          const auto value =
            *result;

          value_checksum +=
            static_cast<std::uint64_t>(
              value
            );

          work_checksum +=
            perform_work(
              value,
              work_rounds
            );

          ++count;
          continue;
        }

        ++retries;

        if(queue.empty()) {
          break;
        }

        if(
          (retries & 255u) == 0
        ) {
          std::this_thread::yield();
        }
      }

      thief_value_checksums[index] =
        value_checksum;

      thief_work_checksums[index] =
        work_checksum;

      thief_counts[index] =
        count;

      thief_retries[index] =
        retries;
    });
  }

  pin_current_thread(
    owner_cpu
  );

  while(
    ready.load(
      std::memory_order_acquire) !=
    thief_count
  ) {
    std::this_thread::yield();
  }

  std::uint64_t owner_value_checksum = 0;
  std::uint64_t owner_work_checksum = 0;

  std::size_t owner_count = 0;

  const auto begin =
    std::chrono::steady_clock::now();

  start.store(
    true,
    std::memory_order_release
  );

  for(;;) {
    const auto result =
      queue.pop();

    if(result) {
      const auto value =
        *result;

      owner_value_checksum +=
        static_cast<std::uint64_t>(
          value
        );

      owner_work_checksum +=
        perform_work(
          value,
          work_rounds
        );

      ++owner_count;
      continue;
    }

    if(queue.empty()) {
      break;
    }
  }

  for(auto& thief : thieves) {
    thief.join();
  }

  const auto end =
    std::chrono::steady_clock::now();

  RunResult result{};

  result.elapsed_ns =
    static_cast<std::uint64_t>(
      std::chrono::duration_cast<
        std::chrono::nanoseconds
      >(end - begin).count()
    );

  result.value_checksum =
    owner_value_checksum;

  result.work_checksum =
    owner_work_checksum;

  result.owner_popped =
    owner_count;

  for(
    std::size_t i = 0;
    i < thief_count;
    ++i
  ) {
    result.value_checksum +=
      thief_value_checksums[i];

    result.work_checksum +=
      thief_work_checksums[i];

    result.stolen +=
      thief_counts[i];

    result.steal_retries +=
      thief_retries[i];
  }

  const auto returned =
    result.owner_popped +
    result.stolen;

  const std::uint64_t expected_value =
    static_cast<std::uint64_t>(items) *
    static_cast<std::uint64_t>(items + 1) /
    2;

  if(returned != items) {
    std::fprintf(
      stderr,
      "returned count mismatch\n"
    );
    std::abort();
  }

  if(
    result.value_checksum !=
    expected_value
  ) {
    std::fprintf(
      stderr,
      "value checksum mismatch\n"
    );
    std::abort();
  }

  if(
    result.work_checksum !=
    expected_work
  ) {
    std::fprintf(
      stderr,
      "work checksum mismatch\n"
    );
    std::abort();
  }

  if(!queue.empty()) {
    std::fprintf(
      stderr,
      "queue not empty\n"
    );
    std::abort();
  }

  return result;
}

Stats calculate_stats(
  std::vector<std::uint64_t> times,
  std::size_t items
) {
  std::sort(
    times.begin(),
    times.end()
  );

  const auto n =
    times.size();

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
    static_cast<double>(
      times[p10]
    ) / items,
    static_cast<double>(
      times[p90]
    ) / items
  };
}

void benchmark(
  std::size_t items,
  std::size_t thief_count,
  std::size_t owner_cpu,
  std::size_t work_rounds,
  std::size_t warmups,
  std::size_t samples
) {
  const auto expected_work =
    expected_work_checksum(
      items,
      work_rounds
    );

  for(
    std::size_t i = 0;
    i < warmups;
    ++i
  ) {
    run_drain(
      items,
      thief_count,
      owner_cpu,
      work_rounds,
      expected_work
    );
  }

  std::vector<std::uint64_t>
    times(samples);

  std::uint64_t aggregate_value_checksum = 0;
  std::uint64_t aggregate_work_checksum = 0;

  std::size_t aggregate_owner = 0;
  std::size_t aggregate_stolen = 0;
  std::size_t aggregate_retries = 0;

  for(
    std::size_t i = 0;
    i < samples;
    ++i
  ) {
    const auto result =
      run_drain(
        items,
        thief_count,
        owner_cpu,
        work_rounds,
        expected_work
      );

    times[i] =
      result.elapsed_ns;

    aggregate_value_checksum +=
      result.value_checksum;

    aggregate_work_checksum +=
      result.work_checksum;

    aggregate_owner +=
      result.owner_popped;

    aggregate_stolen +=
      result.stolen;

    aggregate_retries +=
      result.steal_retries;
  }

  const auto stats =
    calculate_stats(
      std::move(times),
      items
    );

  const auto total =
    aggregate_owner +
    aggregate_stolen;

  const double owner_share =
    total != 0
      ? 100.0 *
          static_cast<double>(
            aggregate_owner
          ) /
          static_cast<double>(
            total
          )
      : 0.0;

  std::printf(
    "taskflow    work=%3zu median=%8.3f ns/item "
    "p10/p90=%8.3f/%8.3f\n",
    work_rounds,
    stats.median_ns,
    stats.p10_ns,
    stats.p90_ns
  );

  std::printf(
    "            owner=%zu stolen=%zu ownerShare=%.3f%%\n",
    aggregate_owner,
    aggregate_stolen,
    owner_share
  );

  std::printf(
    "            stealRetries=%zu\n",
    aggregate_retries
  );

  std::printf(
    "            valueChecksum=%llu workChecksum=%llu\n",
    static_cast<unsigned long long>(
      aggregate_value_checksum
    ),
    static_cast<unsigned long long>(
      aggregate_work_checksum
    )
  );
}

} // namespace

int main(
  int argc,
  char** argv
) {
  std::size_t items =
    Capacity;

  std::size_t thief_count = 4;
  std::size_t warmups = 4;
  std::size_t samples = 15;
  std::size_t owner_cpu = 2;

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
    thief_count =
      static_cast<std::size_t>(
        std::strtoull(
          argv[2],
          nullptr,
          10
        )
      );
  }

  if(argc > 3) {
    warmups =
      static_cast<std::size_t>(
        std::strtoull(
          argv[3],
          nullptr,
          10
        )
      );
  }

  if(argc > 4) {
    samples =
      static_cast<std::size_t>(
        std::strtoull(
          argv[4],
          nullptr,
          10
        )
      );
  }

  if(argc > 5) {
    owner_cpu =
      static_cast<std::size_t>(
        std::strtoull(
          argv[5],
          nullptr,
          10
        )
      );
  }

  if(
    items == 0 ||
    items > Capacity ||
    thief_count == 0 ||
    thief_count > MaxThieves ||
    samples < 5
  ) {
    return 2;
  }

  std::printf(
    "R0.1 P08h0 Taskflow scheduler-like drain\n"
  );

  std::printf(
    "items=%zu thieves=%zu warmups=%zu samples=%zu\n",
    items,
    thief_count,
    warmups,
    samples
  );

  for(
    const auto work_rounds :
    {0u, 16u, 64u}
  ) {
    benchmark(
      items,
      thief_count,
      owner_cpu,
      work_rounds,
      warmups,
      samples
    );
  }

  std::printf(
    "R0.1 P08h0 PASS\n"
  );

  return 0;
}
