module app;

import concurrency.research.modular_bounded_wsq_rmw :
    ModularRmwBoundedWorkStealingDeque;

alias Queue =
    ModularRmwBoundedWorkStealingDeque!(size_t, 8);

extern(C)
bool probe_rmw_push(
    Queue* queue,
    size_t value)
{
    return queue.tryPush(value);
}

extern(C)
size_t probe_rmw_pop(
    Queue* queue,
    bool* found)
{
    const result = queue.pop();

    *found = result.found;

    return result.value;
}

extern(C)
size_t probe_rmw_steal(
    Queue* queue,
    bool* found)
{
    const result = queue.steal();

    *found = result.found;

    return result.value;
}
