#include <taskflow/core/wsq.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr std::size_t LogSize = 18;
constexpr std::size_t Capacity = std::size_t{1} << LogSize;

using Queue = tf::BoundedWSQ<std::size_t, LogSize>;

enum class Workload {
  Push,
  PopMany,
  PushPopPair,
  EmptySteal,
  SuccessfulSteal
};

struct Stats {
  double median_ns;
  double p10_ns;
  double p90_ns;
};

volatile std::uint64_t observable_checksum = 0;

template <typename F>
std::uint64_t measure_ns(F&& fn) {
  const auto begin = std::chrono::steady_clock::now();
  fn();
  const auto end = std::chrono::steady_clock::now();

  return static_cast<std::uint64_t>(
    std::chrono::duration_cast<std::chrono::nanoseconds>(
      end - begin
    ).count()
  );
}

void drain(Queue& queue) {
  while(queue.pop()) {
  }
}

void prepare(Queue& queue, Workload workload) {
  drain(queue);

  switch(workload) {
    case Workload::Push:
    case Workload::EmptySteal:
      break;

    case Workload::PopMany:
    case Workload::SuccessfulSteal:
      for(std::size_t i = 0; i < Capacity; ++i) {
        if(!queue.try_push(i + 1)) {
          std::abort();
        }
      }
      break;

    case Workload::PushPopPair:
      if(!queue.try_push(1) || !queue.try_push(2)) {
        std::abort();
      }
      break;
  }
}

std::uint64_t timed_run(
  Queue& queue,
  Workload workload,
  std::uint64_t& checksum
) {
  std::uint64_t local = 0;

  const auto elapsed = measure_ns([&] {
    switch(workload) {
      case Workload::Push:
        for(std::size_t i = 0; i < Capacity; ++i) {
          local += static_cast<std::uint64_t>(
            queue.try_push(i + 1)
          );
        }
        break;

      case Workload::PopMany:
        for(std::size_t i = 0; i < Capacity - 1; ++i) {
          const auto result = queue.pop();

          if(!result) {
            std::abort();
          }

          local += *result;
          local += 1;
        }
        break;

      case Workload::PushPopPair:
        for(std::size_t i = 0; i < Capacity; ++i) {
          const bool pushed =
            queue.try_push(i + 3);

          const auto result =
            queue.pop();

          if(!pushed || !result) {
            std::abort();
          }

          local += static_cast<std::uint64_t>(pushed);
          local += *result;
          local += 1;
        }
        break;

      case Workload::EmptySteal:
        for(std::size_t i = 0; i < Capacity; ++i) {
          const auto result = queue.steal();

          if(result) {
            local += *result;
            local += 1;
          }
        }
        break;

      case Workload::SuccessfulSteal:
        for(std::size_t i = 0; i < Capacity; ++i) {
          const auto result = queue.steal();

          if(!result) {
            std::abort();
          }

          local += *result;
          local += 1;
        }
        break;
    }
  });

  checksum += local;
  observable_checksum = checksum;

  return elapsed;
}

std::size_t operations_per_sample(Workload workload) {
  switch(workload) {
    case Workload::PopMany:
      return Capacity - 1;

    default:
      return Capacity;
  }
}

const char* workload_name(Workload workload) {
  switch(workload) {
    case Workload::Push:
      return "push";

    case Workload::PopMany:
      return "pop-many";

    case Workload::PushPopPair:
      return "push-pop-pair";

    case Workload::EmptySteal:
      return "empty-steal";

    case Workload::SuccessfulSteal:
      return "successful-steal";
  }

  return "unknown";
}

Stats calculate_stats(
  std::vector<std::uint64_t> times,
  std::size_t operations
) {
  std::sort(times.begin(), times.end());

  const auto n = times.size();

  const double median =
    (n & 1)
      ? static_cast<double>(times[n / 2])
      : (
          static_cast<double>(times[n / 2 - 1]) +
          static_cast<double>(times[n / 2])
        ) / 2.0;

  const auto p10_index =
    (n - 1) * 10 / 100;

  const auto p90_index =
    (n - 1) * 90 / 100;

  return {
    median / operations,
    static_cast<double>(times[p10_index]) / operations,
    static_cast<double>(times[p90_index]) / operations
  };
}

void benchmark(
  Workload workload,
  std::size_t warmups,
  std::size_t samples,
  std::uint64_t& checksum
) {
  Queue queue;

  for(std::size_t i = 0; i < warmups; ++i) {
    prepare(queue, workload);
    timed_run(queue, workload, checksum);
  }

  std::vector<std::uint64_t> times(samples);

  for(std::size_t i = 0; i < samples; ++i) {
    prepare(queue, workload);

    times[i] =
      timed_run(queue, workload, checksum);
  }

  const auto stats =
    calculate_stats(
      std::move(times),
      operations_per_sample(workload)
    );

  std::printf(
    "%-18s taskflow=%8.3f ns/op\n",
    workload_name(workload),
    stats.median_ns
  );

  std::printf(
    "%-18s p10/p90=%8.3f/%8.3f\n",
    "",
    stats.p10_ns,
    stats.p90_ns
  );
}

}  // namespace

int main(int argc, char** argv) {
  std::size_t warmups = 6;
  std::size_t samples = 24;

  if(argc > 1) {
    warmups =
      static_cast<std::size_t>(
        std::strtoull(argv[1], nullptr, 10)
      );
  }

  if(argc > 2) {
    samples =
      static_cast<std::size_t>(
        std::strtoull(argv[2], nullptr, 10)
      );
  }

  if(samples < 5) {
    return 2;
  }

  std::uint64_t checksum = 0;

  std::printf(
    "R0.1 P07 Taskflow reference benchmark\n"
  );

  std::printf(
    "capacity=%zu warmups=%zu samples=%zu\n",
    Capacity,
    warmups,
    samples
  );

  benchmark(
    Workload::Push,
    warmups,
    samples,
    checksum
  );

  benchmark(
    Workload::PopMany,
    warmups,
    samples,
    checksum
  );

  benchmark(
    Workload::PushPopPair,
    warmups,
    samples,
    checksum
  );

  benchmark(
    Workload::EmptySteal,
    warmups,
    samples,
    checksum
  );

  benchmark(
    Workload::SuccessfulSteal,
    warmups,
    samples,
    checksum
  );

  std::printf(
    "checksum=%llu\n",
    static_cast<unsigned long long>(checksum)
  );

  std::printf(
    "R0.1 P07 PASS\n"
  );

  return 0;
}
