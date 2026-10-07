#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <thread>

#include <pthread.h>
#include <sched.h>

#include "taskflow/core/wsq.hpp"

namespace {

constexpr std::size_t MaxWorkers = 4;
constexpr std::size_t LogSize = 10;
constexpr std::size_t Capacity = std::size_t{1} << LogSize;

constexpr std::size_t Tasks = 262144;

constexpr std::size_t Warmups = 2;
constexpr std::size_t Samples = 9;

using TaskRef = std::uint64_t;
using Queue = tf::BoundedWSQ<TaskRef, LogSize>;

struct WorkerStats {
  std::uint64_t executed = 0;
  std::uint64_t localPops = 0;

  std::uint64_t stolenTasks = 0;
  std::uint64_t stealClaims = 0;
  std::uint64_t failedSteals = 0;

  std::uint64_t overflowInline = 0;

  std::uint64_t valueSum = 0;
  std::uint64_t valueXor = 0;
  std::uint64_t workChecksum = 0;
};

struct RunResult {
  std::uint64_t elapsedNs = 0;

  std::uint64_t executed = 0;
  std::uint64_t localPops = 0;

  std::uint64_t stolenTasks = 0;
  std::uint64_t stealClaims = 0;
  std::uint64_t failedSteals = 0;

  std::uint64_t overflowInline = 0;

  std::uint64_t minWorkerExecuted = 0;
  std::uint64_t maxWorkerExecuted = 0;
};

struct Distribution {
  double median;
  double p10;
  double p90;
};

void pinCurrentThread(std::size_t cpu) {
  cpu_set_t mask;
  CPU_ZERO(&mask);
  CPU_SET(cpu, &mask);

  if (
    sched_setaffinity(
      0,
      sizeof(mask),
      &mask
    ) != 0
  ) {
    std::fprintf(
      stderr,
      "sched_setaffinity failed\n"
    );
    std::abort();
  }

  const int actual =
    sched_getcpu();

  if (
    actual < 0 ||
    static_cast<std::size_t>(actual) != cpu
  ) {
    std::fprintf(
      stderr,
      "affinity verification failed\n"
    );
    std::abort();
  }
}

std::uint64_t doWork(
  std::uint64_t value,
  std::size_t rounds
) noexcept {
  std::uint64_t x =
    value +
    0x9e3779b97f4a7c15ULL;

  for (
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

std::uint64_t expectedWorkChecksum(
  std::size_t rounds
) {
  std::uint64_t result = 0;

  for (
    std::size_t i = 0;
    i < Tasks;
    ++i
  ) {
    result ^=
      doWork(
        static_cast<std::uint64_t>(i) + 1,
        rounds
      );
  }

  return result;
}

void executeTask(
  TaskRef task,
  std::size_t rounds,
  WorkerStats& stats,
  std::atomic<std::uint64_t>& completed
) noexcept {
  ++stats.executed;

  stats.valueSum +=
    task;

  stats.valueXor ^=
    task;

  stats.workChecksum ^=
    doWork(
      task,
      rounds
    );

  completed.fetch_add(
    1,
    std::memory_order_release
  );
}

RunResult run(
  std::size_t workerCount,
  std::size_t rounds
) {
  std::array<Queue, MaxWorkers>
    queues;

  std::atomic<std::size_t>
    readyCount {0};

  std::atomic<bool>
    start {false};

  std::atomic<bool>
    producerDone {false};

  std::atomic<std::uint64_t>
    completed {0};

  std::array<WorkerStats, MaxWorkers>
    publishedStats {};

  std::array<std::thread, MaxWorkers>
    threads;

  for (
    std::size_t workerIndex = 0;
    workerIndex < workerCount;
    ++workerIndex
  ) {
    threads[workerIndex] =
      std::thread(
        [&, workerIndex] {
          pinCurrentThread(
            workerIndex
          );

          WorkerStats stats;

          std::size_t nextVictim =
            workerCount > 1
              ? (workerIndex + 1) %
                  workerCount
              : workerIndex;

          readyCount.fetch_add(
            1,
            std::memory_order_release
          );

          while (
            !start.load(
              std::memory_order_acquire
            )
          ) {
            std::this_thread::yield();
          }

          /*
           * Exact P14a single-producer semantics.
           *
           * Queue full:
           *     execute-inline
           *
           * Production therefore remains inside the measured interval.
           */
          if (workerIndex == 0) {
            for (
              std::size_t i = 0;
              i < Tasks;
              ++i
            ) {
              const TaskRef task =
                static_cast<std::uint64_t>(i) +
                1;

              if (
                queues[0]
                  .try_push(task)
              ) {
                continue;
              }

              ++stats.overflowInline;

              executeTask(
                task,
                rounds,
                stats,
                completed
              );
            }

            producerDone.store(
              true,
              std::memory_order_release
            );
          }

          for (;;) {
            const auto local =
              queues[workerIndex]
                .pop();

            if (local) {
              ++stats.localPops;

              executeTask(
                *local,
                rounds,
                stats,
                completed
              );

              continue;
            }

            bool foundWork = false;

            if (workerCount > 1) {
              for (
                std::size_t attempt = 0;
                attempt <
                  workerCount - 1;
                ++attempt
              ) {
                const std::size_t victim =
                  nextVictim;

                nextVictim =
                  (nextVictim + 1) %
                  workerCount;

                if (
                  victim ==
                  workerIndex
                ) {
                  continue;
                }

                const auto stolen =
                  queues[victim]
                    .steal();

                if (!stolen) {
                  ++stats.failedSteals;
                  continue;
                }

                ++stats.stealClaims;
                ++stats.stolenTasks;

                executeTask(
                  *stolen,
                  rounds,
                  stats,
                  completed
                );

                foundWork = true;
                break;
              }
            }

            if (foundWork) {
              continue;
            }

            if (
              producerDone.load(
                std::memory_order_acquire
              ) &&
              completed.load(
                std::memory_order_acquire
              ) ==
                Tasks
            ) {
              break;
            }

            std::this_thread::yield();
          }

          publishedStats[
            workerIndex
          ] =
            stats;
        }
      );
  }

  while (
    readyCount.load(
      std::memory_order_acquire
    ) !=
      workerCount
  ) {
    std::this_thread::yield();
  }

  const auto begin =
    std::chrono::steady_clock::now();

  start.store(
    true,
    std::memory_order_release
  );

  for (
    std::size_t i = 0;
    i < workerCount;
    ++i
  ) {
    threads[i].join();
  }

  const auto end =
    std::chrono::steady_clock::now();

  RunResult result;

  result.elapsedNs =
    static_cast<std::uint64_t>(
      std::chrono::duration_cast<
        std::chrono::nanoseconds
      >(end - begin).count()
    );

  std::uint64_t valueSum = 0;
  std::uint64_t valueXor = 0;
  std::uint64_t workChecksum = 0;

  result.minWorkerExecuted =
    UINT64_MAX;

  for (
    std::size_t worker = 0;
    worker < workerCount;
    ++worker
  ) {
    const auto& stats =
      publishedStats[worker];

    result.executed +=
      stats.executed;

    result.localPops +=
      stats.localPops;

    result.stolenTasks +=
      stats.stolenTasks;

    result.stealClaims +=
      stats.stealClaims;

    result.failedSteals +=
      stats.failedSteals;

    result.overflowInline +=
      stats.overflowInline;

    valueSum +=
      stats.valueSum;

    valueXor ^=
      stats.valueXor;

    workChecksum ^=
      stats.workChecksum;

    result.minWorkerExecuted =
      std::min(
        result.minWorkerExecuted,
        stats.executed
      );

    result.maxWorkerExecuted =
      std::max(
        result.maxWorkerExecuted,
        stats.executed
      );
  }

  if (
    result.executed !=
    Tasks
  ) {
    std::fprintf(
      stderr,
      "execution count mismatch\n"
    );
    std::abort();
  }

  if (
    completed.load(
      std::memory_order_acquire
    ) !=
    Tasks
  ) {
    std::fprintf(
      stderr,
      "completed count mismatch\n"
    );
    std::abort();
  }

  const std::uint64_t n =
    static_cast<std::uint64_t>(
      Tasks
    );

  const std::uint64_t expectedSum =
    n * (n + 1) / 2;

  if (
    valueSum !=
    expectedSum
  ) {
    std::fprintf(
      stderr,
      "value sum mismatch\n"
    );
    std::abort();
  }

  std::uint64_t expectedXor = 0;

  switch (n & 3ULL) {
    case 0:
      expectedXor = n;
      break;

    case 1:
      expectedXor = 1;
      break;

    case 2:
      expectedXor = n + 1;
      break;

    case 3:
      expectedXor = 0;
      break;
  }

  if (
    valueXor !=
    expectedXor
  ) {
    std::fprintf(
      stderr,
      "value xor mismatch\n"
    );
    std::abort();
  }

  if (
    workChecksum !=
    expectedWorkChecksum(
      rounds
    )
  ) {
    std::fprintf(
      stderr,
      "work checksum mismatch\n"
    );
    std::abort();
  }

  for (
    std::size_t worker = 0;
    worker < workerCount;
    ++worker
  ) {
    if (
      !queues[worker]
        .empty()
    ) {
      std::fprintf(
        stderr,
        "queue not empty\n"
      );
      std::abort();
    }
  }

  return result;
}

Distribution distribution(
  std::array<
    std::uint64_t,
    Samples
  > values
) {
  std::sort(
    values.begin(),
    values.end()
  );

  return Distribution {
    static_cast<double>(
      values[
        values.size() / 2
      ]
    ),
    static_cast<double>(
      values[
        (values.size() - 1) *
        10 / 100
      ]
    ),
    static_cast<double>(
      values[
        (values.size() - 1) *
        90 / 100
      ]
    )
  };
}

void benchmark(
  std::size_t workerCount,
  std::size_t rounds
) {
  for (
    std::size_t i = 0;
    i < Warmups;
    ++i
  ) {
    run(
      workerCount,
      rounds
    );
  }

  std::array<
    std::uint64_t,
    Samples
  > elapsed {};

  std::uint64_t totalExecuted = 0;
  std::uint64_t totalLocalPops = 0;

  std::uint64_t totalStolen = 0;
  std::uint64_t totalClaims = 0;
  std::uint64_t totalFailedSteals = 0;

  std::uint64_t totalOverflow = 0;

  std::uint64_t minWorkerExecuted =
    UINT64_MAX;

  std::uint64_t maxWorkerExecuted = 0;

  for (
    std::size_t sample = 0;
    sample < Samples;
    ++sample
  ) {
    const auto result =
      run(
        workerCount,
        rounds
      );

    elapsed[sample] =
      result.elapsedNs;

    totalExecuted +=
      result.executed;

    totalLocalPops +=
      result.localPops;

    totalStolen +=
      result.stolenTasks;

    totalClaims +=
      result.stealClaims;

    totalFailedSteals +=
      result.failedSteals;

    totalOverflow +=
      result.overflowInline;

    minWorkerExecuted =
      std::min(
        minWorkerExecuted,
        result.minWorkerExecuted
      );

    maxWorkerExecuted =
      std::max(
        maxWorkerExecuted,
        result.maxWorkerExecuted
      );
  }

  const auto d =
    distribution(
      elapsed
    );

  const double medianNsPerTask =
    d.median /
    static_cast<double>(
      Tasks
    );

  const double p10NsPerTask =
    d.p10 /
    static_cast<double>(
      Tasks
    );

  const double p90NsPerTask =
    d.p90 /
    static_cast<double>(
      Tasks
    );

  const double tasksPerSecond =
    static_cast<double>(
      Tasks
    ) *
    1'000'000'000.0 /
    d.median;

  const double localRatio =
    static_cast<double>(
      totalLocalPops
    ) /
    static_cast<double>(
      totalExecuted
    );

  const double overflowPerTask =
    static_cast<double>(
      totalOverflow
    ) /
    static_cast<double>(
      Tasks * Samples
    );

  std::printf(
    "taskflow workers=%zu work=%2zu "
    "median=%8.3f ns/task "
    "p10/p90=%8.3f/%8.3f "
    "tasks/s=%10.1f\n",
    workerCount,
    rounds,
    medianNsPerTask,
    p10NsPerTask,
    p90NsPerTask,
    tasksPerSecond
  );

  std::printf(
    "         localRatio=%.3f "
    "claims=%llu stolen/claim=%.3f\n",
    localRatio,
    static_cast<unsigned long long>(
      totalClaims
    ),
    totalClaims != 0
      ? static_cast<double>(
          totalStolen
        ) /
        static_cast<double>(
          totalClaims
        )
      : 0.0
  );

  std::printf(
    "         failedSteals=%llu "
    "overflow/task=%.6f\n",
    static_cast<unsigned long long>(
      totalFailedSteals
    ),
    overflowPerTask
  );

  std::printf(
    "         workerExecutedRange=%llu..%llu\n",
    static_cast<unsigned long long>(
      minWorkerExecuted
    ),
    static_cast<unsigned long long>(
      maxWorkerExecuted
    )
  );
}

}  // namespace

int main() {
  std::printf(
    "R0.1 P14d Taskflow flat control\n"
  );

  std::printf(
    "taskflow_commit="
    "bbd7251d577b33a4aeff434ce5f5569b94d4cc48 "
    "tasks=%zu capacity=%zu "
    "warmups=%zu samples=%zu\n",
    Tasks,
    Capacity,
    Warmups,
    Samples
  );

  for (
    const std::size_t rounds :
    {std::size_t{0},
     std::size_t{16},
     std::size_t{64}}
  ) {
    std::printf(
      "\n=== work=%zu ===\n",
      rounds
    );

    for (
      const std::size_t workers :
      {std::size_t{1},
       std::size_t{2},
       std::size_t{4}}
    ) {
      benchmark(
        workers,
        rounds
      );
    }
  }

  std::printf(
    "\nR0.1 P14d PASS\n"
  );

  return 0;
}
