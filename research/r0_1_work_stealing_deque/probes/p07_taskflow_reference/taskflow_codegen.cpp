#include <taskflow/core/wsq.hpp>

#include <cstddef>

using Queue = tf::BoundedWSQ<std::size_t, 18>;

extern "C"
__attribute__((noinline))
bool probe_taskflow_push(
  Queue* queue,
  std::size_t value
) {
  return queue->try_push(value);
}

extern "C"
__attribute__((noinline))
std::size_t probe_taskflow_pop(
  Queue* queue,
  bool* found
) {
  const auto result = queue->pop();

  *found = result.has_value();

  return result ? *result : 0;
}

extern "C"
__attribute__((noinline))
std::size_t probe_taskflow_steal(
  Queue* queue,
  bool* found
) {
  const auto result = queue->steal();

  *found = result.has_value();

  return result ? *result : 0;
}
