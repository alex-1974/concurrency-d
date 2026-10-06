#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <genmc.h>

enum {
    MODULO = 16,
    MARK = 8,
    CAPACITY = 4,

    OLD_BOTTOM = 10,
    CURRENT_BOTTOM = 2
};

static atomic_int topState;
static atomic_int bottom;

static atomic_int clearedBusy;

static void *owner_history(void *unused)
{
    (void)unused;

    /*
     * OLD_BOTTOM is already the initial value.
     *
     * Publish the current bounded-queue bottom. This store is relaxed:
     * Batch A must actually observe it; no extra synchronization is used.
     */
    atomic_store_explicit(
        &bottom,
        CURRENT_BOTTOM,
        memory_order_relaxed);

    return 0;
}

static void *batch_a(void *unused)
{
    (void)unused;

    /*
     * Model the P08g pre-CAS validation.
     *
     * We restrict attention to executions where Batch A really observed the
     * current valid bottom before it was allowed to mark top busy.
     */
    int b =
        atomic_load_explicit(
            &bottom,
            memory_order_acquire);

    __VERIFIER_assume(
        b == CURRENT_BOTTOM);

    int state =
        atomic_load_explicit(
            &topState,
            memory_order_acquire);

    __VERIFIER_assume(
        state == 0);

    int distance =
        (b - state) &
        (MODULO - 1);

    __VERIFIER_assume(
        distance > 0 &&
        distance <= CAPACITY);

    int expected = 0;

    int success =
        atomic_compare_exchange_strong_explicit(
            &topState,
            &expected,
            MARK,
            memory_order_seq_cst,
            memory_order_relaxed);

    __VERIFIER_assume(success);

    return 0;
}

static void *batch_b(void *unused)
{
    (void)unused;

    /*
     * This corresponds to P08g's acquire top observation.
     *
     * If this reads Batch A's busy CAS, Batch A's earlier bottom observation
     * happens-before the following bottom observation in this thread.
     */
    int state =
        atomic_load_explicit(
            &topState,
            memory_order_acquire);

    __VERIFIER_assume(
        state == MARK);

    int b =
        atomic_load_explicit(
            &bottom,
            memory_order_acquire);

    int apparentDistance =
        (b - state) &
        (MODULO - 1);

    if (
        apparentDistance > 0 &&
        apparentDistance <= CAPACITY)
    {
        /*
         * This is the feared misclassification:
         * an already-busy state looked like a valid idle queue.
         */
        int expected =
            state;

        int success =
            atomic_compare_exchange_strong_explicit(
                &topState,
                &expected,
                (state + MARK) &
                    (MODULO - 1),
                memory_order_seq_cst,
                memory_order_relaxed);

        if (success)
        {
            atomic_store_explicit(
                &clearedBusy,
                1,
                memory_order_relaxed);
        }
    }

    return 0;
}

int main(void)
{
    atomic_init(
        &topState,
        0);

    /*
     * Historical value:
     *
     *     OLD_BOTTOM - MARK == 2
     *
     * so reading this value while topState==MARK would falsely look like
     * idle occupancy 2.
     */
    atomic_init(
        &bottom,
        OLD_BOTTOM);

    atomic_init(
        &clearedBusy,
        0);

    pthread_t h;
    pthread_t a;
    pthread_t b;

    assert(
        pthread_create(
            &h,
            0,
            owner_history,
            0) == 0);

    assert(
        pthread_create(
            &a,
            0,
            batch_a,
            0) == 0);

    assert(
        pthread_create(
            &b,
            0,
            batch_b,
            0) == 0);

    assert(
        pthread_join(
            h,
            0) == 0);

    assert(
        pthread_join(
            a,
            0) == 0);

    assert(
        pthread_join(
            b,
            0) == 0);

    int cleared =
        atomic_load_explicit(
            &clearedBusy,
            memory_order_relaxed);

    assert(cleared == 0);

    return 0;
}
