#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <thread>

#include <sched.h>

#include "taskflow/core/wsq.hpp"

namespace {

constexpr std::size_t Workers = 4;
constexpr std::size_t LogSize = 10;
constexpr std::size_t Capacity = std::size_t{1} << LogSize;

constexpr unsigned MaxDepth = 18;

constexpr std::size_t Warmups = 2;
constexpr std::size_t Samples = 9;

using TaskRef = std::uint64_t;
using Queue = tf::BoundedWSQ<TaskRef, LogSize>;

struct Expected {
  std::uint64_t count = 0;
  std::uint64_t spawned = 0;

  std::uint64_t valueSum = 0;
  std::uint64_t valueXor = 0;
  std::uint64_t workChecksum = 0;
};

struct WorkerStats {
  std::uint64_t executed = 0;
  std::uint64_t localPops = 0;

  std::uint64_t stolenTasks = 0;
  std::uint64_t stealClaims = 0;
  std::uint64_t failedSteals = 0;

  std::uint64_t spawned = 0;
  std::uint64_t overflowInline = 0;

  std::uint64_t idleTransitions = 0;

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

  std::uint64_t spawned = 0;
  std::uint64_t overflowInline = 0;
  std::uint64_t idleTransitions = 0;

  std::uint64_t minWorkerExecuted = 0;
  std::uint64_t maxWorkerExecuted = 0;
};

struct Distribution {
  double median;
  double p10;
  double p90;
};

TaskRef makeTask(
  std::uint64_t path,
  unsigned depth
) noexcept {
  return
    (static_cast<std::uint64_t>(depth) << 56) |
    path;
}

std::uint64_t taskPath(
  TaskRef task
) noexcept {
  return
    task &
    0x00ff'ffff'ffff'ffffULL;
}

unsigned taskDepth(
  TaskRef task
) noexcept {
  return
    static_cast<unsigned>(
      task >> 56
    );
}

std::uint64_t mix(
  std::uint64_t x
) noexcept {
  x ^= x >> 30;
  x *=
    0xbf58'476d'1ce4'e5b9ULL;

  x ^= x >> 27;
  x *=
    0x94d0'49bb'1331'11ebULL;

  x ^= x >> 31;

  return x;
}

std::size_t fanout(
  std::uint64_t path,
  unsigned depth
) noexcept {
  if (depth >= MaxDepth) {
    return 0;
  }

  const auto selector =
    mix(
      path ^
      (
        static_cast<std::uint64_t>(depth) *
        0x9e37'79b9'7f4a'7c15ULL
      )
    ) &
    7ULL;

  switch (
    static_cast<unsigned>(
      selector
    )
  ) {
    case 0:
      return 0;

    case 1:
    case 2:
      return 1;

    case 3:
    case 4:
    case 5:
      return 2;

    case 6:
    case 7:
      return 4;
  }

  std::abort();
}

std::size_t workRounds(
  std::uint64_t path,
  unsigned depth
) noexcept {
  const auto selector =
    mix(
      path +
      (
        static_cast<std::uint64_t>(depth) *
        0xd1b5'4a32'd192'ed03ULL
      )
    ) &
    7ULL;

  switch (
    static_cast<unsigned>(
      selector
    )
  ) {
    case 0:
    case 1:
      return 0;

    case 2:
    case 3:
    case 4:
      return 8;

    case 5:
    case 6:
      return 24;

    case 7:
      return 64;
  }

  std::abort();
}

std::uint64_t doWork(
  std::uint64_t value,
  std::size_t rounds
) noexcept {
  std::uint64_t x =
    value +
    0x9e37'79b9'7f4a'7c15ULL;

  for (
    std::size_t i = 0;
    i < rounds;
    ++i
  ) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;

    x *=
      0x2545'f491'4f6c'dd1dULL;

    x +=
      static_cast<std::uint64_t>(i) +
      0x9e37'79b9'7f4a'7c15ULL;
  }

  return x;
}

std::uint64_t childPath(
  std::uint64_t parent,
  std::size_t child
) noexcept {
  return
    (parent << 2) |
    static_cast<std::uint64_t>(
      child + 1
    );
}

void pinCurrentThread(
  std::size_t cpu
) {
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
    static_cast<std::size_t>(
      actual
    ) != cpu
  ) {
    std::fprintf(
      stderr,
      "affinity verification failed\n"
    );
    std::abort();
  }
}

void accumulateExpected(
  std::uint64_t path,
  unsigned depth,
  Expected& expected
) {
  ++expected.count;

  expected.valueSum +=
    path;

  expected.valueXor ^=
    path;

  expected.workChecksum ^=
    doWork(
      path,
      workRounds(
        path,
        depth
      )
    );

  const auto children =
    fanout(
      path,
      depth
    );

  expected.spawned +=
    children;

  for (
    std::size_t child = 0;
    child < children;
    ++child
  ) {
    accumulateExpected(
      childPath(
        path,
        child
      ),
      depth + 1,
      expected
    );
  }
}

Expected expectedGraph() {
  Expected result;

  accumulateExpected(
    1,
    0,
    result
  );

  return result;
}

/*
 * Exact mirror of P14c's recursive execute-inline path.
 */
void executeTask(
  TaskRef task,
  std::size_t workerIndex,
  std::array<Queue, Workers>& queues,
  WorkerStats& stats,
  std::atomic<std::int64_t>& outstanding,
  std::atomic<std::uint64_t>& completed
) {
  const auto path =
    taskPath(task);

  const auto depth =
    taskDepth(task);

  ++stats.executed;

  stats.valueSum +=
    path;

  stats.valueXor ^=
    path;

  stats.workChecksum ^=
    doWork(
      path,
      workRounds(
        path,
        depth
      )
    );

  const auto children =
    fanout(
      path,
      depth
    );

  if (children != 0) {
    outstanding.fetch_add(
      static_cast<std::int64_t>(
        children
      ),
      std::memory_order_release
    );

    stats.spawned +=
      children;

    for (
      std::size_t child = 0;
      child < children;
      ++child
    ) {
      const auto next =
        makeTask(
          childPath(
            path,
            child
          ),
          depth + 1
        );

      if (
        queues[workerIndex]
          .try_push(next)
      ) {
        continue;
      }

      ++stats.overflowInline;

      executeTask(
        next,
        workerIndex,
        queues,
        stats,
        outstanding,
        completed
      );
    }
  }

  completed.fetch_add(
    1,
    std::memory_order_release
  );

  outstanding.fetch_sub(
    1,
    std::memory_order_release
  );
}

RunResult run(
  const Expected& expected
) {
  std::array<Queue, Workers>
    queues;

  std::atomic<std::size_t>
    readyCount {0};

  std::atomic<bool>
    start {false};

  std::atomic<bool>
    rootSeeded {false};

  std::atomic<std::int64_t>
    outstanding {0};

  std::atomic<std::uint64_t>
    completed {0};

  std::array<WorkerStats, Workers>
    publishedStats {};

  std::array<std::thread, Workers>
    threads;

  for (
    std::size_t workerIndex = 0;
    workerIndex < Workers;
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
            (workerIndex + 1) %
            Workers;

          bool idle = false;

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

          if (workerIndex == 0) {
            outstanding.fetch_add(
              1,
              std::memory_order_release
            );

            if (
              !queues[0]
                .try_push(
                  makeTask(
                    1,
                    0
                  )
                )
            ) {
              std::fprintf(
                stderr,
                "root push failed\n"
              );
              std::abort();
            }

            rootSeeded.store(
              true,
              std::memory_order_release
            );
          }

          for (;;) {
            const auto local =
              queues[workerIndex]
                .pop();

            if (local) {
              idle = false;

              ++stats.localPops;

              executeTask(
                *local,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed
              );

              continue;
            }

            bool foundWork = false;

            for (
              std::size_t attempt = 0;
              attempt < Workers - 1;
              ++attempt
            ) {
              const auto victim =
                nextVictim;

              nextVictim =
                (nextVictim + 1) %
                Workers;

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

              idle = false;

              executeTask(
                *stolen,
                workerIndex,
                queues,
                stats,
                outstanding,
                completed
              );

              foundWork = true;
              break;
            }

            if (foundWork) {
              continue;
            }

            if (
              rootSeeded.load(
                std::memory_order_acquire
              ) &&
              outstanding.load(
                std::memory_order_acquire
              ) == 0
            ) {
              break;
            }

            if (!idle) {
              ++stats.idleTransitions;
              idle = true;
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
      Workers
  ) {
    std::this_thread::yield();
  }

  const auto begin =
    std::chrono::steady_clock::now();

  start.store(
    true,
    std::memory_order_release
  );

  for (auto& thread : threads) {
    thread.join();
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
    worker < Workers;
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

    result.spawned +=
      stats.spawned;

    result.overflowInline +=
      stats.overflowInline;

    result.idleTransitions +=
      stats.idleTransitions;

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
    expected.count
  ) {
    std::fprintf(
      stderr,
      "execution count mismatch\n"
    );
    std::abort();
  }

  if (
    result.spawned !=
    expected.spawned
  ) {
    std::fprintf(
      stderr,
      "spawn count mismatch\n"
    );
    std::abort();
  }

  if (
    completed.load(
      std::memory_order_acquire
    ) !=
    expected.count
  ) {
    std::fprintf(
      stderr,
      "completed count mismatch\n"
    );
    std::abort();
  }

  if (
    outstanding.load(
      std::memory_order_acquire
    ) !=
    0
  ) {
    std::fprintf(
      stderr,
      "outstanding mismatch\n"
    );
    std::abort();
  }

  if (
    valueSum !=
    expected.valueSum
  ) {
    std::fprintf(
      stderr,
      "value sum mismatch\n"
    );
    std::abort();
  }

  if (
    valueXor !=
    expected.valueXor
  ) {
    std::fprintf(
      stderr,
      "value xor mismatch\n"
    );
    std::abort();
  }

  if (
    workChecksum !=
    expected.workChecksum
  ) {
    std::fprintf(
      stderr,
      "work checksum mismatch\n"
    );
    std::abort();
  }

  for (
    std::size_t worker = 0;
    worker < Workers;
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
  const Expected& expected
) {
  for (
    std::size_t i = 0;
    i < Warmups;
    ++i
  ) {
    run(expected);
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

  std::uint64_t totalSpawned = 0;
  std::uint64_t totalOverflow = 0;
  std::uint64_t totalIdleTransitions = 0;

  std::uint64_t minWorkerExecuted =
    UINT64_MAX;

  std::uint64_t maxWorkerExecuted = 0;

  for (
    std::size_t sample = 0;
    sample < Samples;
    ++sample
  ) {
    const auto result =
      run(expected);

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

    totalSpawned +=
      result.spawned;

    totalOverflow +=
      result.overflowInline;

    totalIdleTransitions +=
      result.idleTransitions;

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

  const double nsPerTask =
    d.median /
    static_cast<double>(
      expected.count
    );

  const double tasksPerSecond =
    static_cast<double>(
      expected.count
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
      totalExecuted
    );

  std::printf(
    "taskflow median=%8.3f ns/task "
    "p10/p90=%8.3f/%8.3f "
    "tasks/s=%10.1f\n",
    nsPerTask,
    d.p10 /
      static_cast<double>(
        expected.count
      ),
    d.p90 /
      static_cast<double>(
        expected.count
      ),
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
    "idleTransitions=%llu\n",
    static_cast<unsigned long long>(
      totalFailedSteals
    ),
    static_cast<unsigned long long>(
      totalIdleTransitions
    )
  );

  std::printf(
    "         spawned=%llu "
    "overflow/task=%.6f\n",
    static_cast<unsigned long long>(
      totalSpawned
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
  const auto expected =
    expectedGraph();

  std::printf(
    "R0.1 P14i Taskflow irregular control\n"
  );

  std::printf(
    "taskflow_commit="
    "bbd7251d577b33a4aeff434ce5f5569b94d4cc48 "
    "workers=%zu maxDepth=%u "
    "tasks=%llu spawned=%llu "
    "capacity=%zu warmups=%zu samples=%zu\n",
    Workers,
    MaxDepth,
    static_cast<unsigned long long>(
      expected.count
    ),
    static_cast<unsigned long long>(
      expected.spawned
    ),
    Capacity,
    Warmups,
    Samples
  );

  benchmark(expected);

  std::printf(
    "\nR0.1 P14i PASS\n"
  );

  return 0;
}
