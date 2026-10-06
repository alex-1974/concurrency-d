#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

static atomic_int topState;
static atomic_int bottom;

static atomic_int ownerState;
static atomic_int batchCasSucceeded;
static atomic_int batchBottom;

/*
 * Initial abstract queue:
 *
 *     top    = 0
 *     bottom = 4
 *
 * The owner is trying to pop item 4.
 * A batch thief is trying to claim items 1..4.
 *
 * Forbidden:
 *
 *     owner sees idle top
 *     AND batch successfully marks top busy
 *     AND batch still sees bottom == 4
 *
 * That would allow both sides to include item 4.
 */

static void *owner(void *unused)
{
    (void)unused;

    atomic_store_explicit(
        &bottom,
        3,
        memory_order_relaxed);

    atomic_thread_fence(
        memory_order_seq_cst);

    int state =
        atomic_load_explicit(
            &topState,
            memory_order_relaxed);

    atomic_store_explicit(
        &ownerState,
        state,
        memory_order_relaxed);

    return 0;
}

static void *batch(void *unused)
{
    (void)unused;

    int expected = 0;

    bool success =
        atomic_compare_exchange_strong_explicit(
            &topState,
            &expected,
            1,
            memory_order_seq_cst,
            memory_order_relaxed);

    atomic_store_explicit(
        &batchCasSucceeded,
        success ? 1 : 0,
        memory_order_relaxed);

    if (success)
    {
        atomic_thread_fence(
            memory_order_seq_cst);

        int observedBottom =
            atomic_load_explicit(
                &bottom,
                memory_order_acquire);

        atomic_store_explicit(
            &batchBottom,
            observedBottom,
            memory_order_relaxed);
    }

    return 0;
}

int main(void)
{
    atomic_init(&topState, 0);
    atomic_init(&bottom, 4);

    atomic_init(&ownerState, -1);
    atomic_init(&batchCasSucceeded, 0);
    atomic_init(&batchBottom, -1);

    pthread_t ownerThread;
    pthread_t batchThread;

    assert(
        pthread_create(
            &ownerThread,
            0,
            owner,
            0) == 0);

    assert(
        pthread_create(
            &batchThread,
            0,
            batch,
            0) == 0);

    assert(
        pthread_join(
            ownerThread,
            0) == 0);

    assert(
        pthread_join(
            batchThread,
            0) == 0);

    int o =
        atomic_load_explicit(
            &ownerState,
            memory_order_relaxed);

    int c =
        atomic_load_explicit(
            &batchCasSucceeded,
            memory_order_relaxed);

    int b =
        atomic_load_explicit(
            &batchBottom,
            memory_order_relaxed);

    /*
     * Duplicate/overlap witness:
     *
     * owner saw idle topState == 0
     * batch successfully changed 0 -> busy
     * batch nevertheless observed the pre-owner bottom == 4
     */
    assert(
        !(o == 0 &&
          c == 1 &&
          b == 4));

    return 0;
}
