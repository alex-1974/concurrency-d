#include <atomic>
#include <cstdint>

extern "C"
__attribute__((noinline))
std::int64_t cpp_pop_protocol_step(
  std::atomic<std::int64_t>* top,
  std::atomic<std::int64_t>* bottom
) {
  auto b =
    bottom->load(
      std::memory_order_relaxed
    ) - 1;

  bottom->store(
    b,
    std::memory_order_relaxed
  );

  std::atomic_thread_fence(
    std::memory_order_seq_cst
  );

  const auto t =
    top->load(
      std::memory_order_relaxed
    );

  return b - t;
}
