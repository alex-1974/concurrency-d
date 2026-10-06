#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>

/*
 * Reduced model of the P08g ambiguity.
 *
 * Real algorithm:
 *
 *     busy = logicalTop + 2^63
 *
 * Here MARK=8 represents that half-range offset.
 *
 * A sufficiently old bottom value can make an already-busy raw top look
 * like a valid idle state to a fresh observer.
 */

enum {
    MARK = 8,
    CAPACITY = 4
};

static atomic_int topState;
static atomic_int bottom;

static atomic_int misclassified;
static atomic_int clearedBusy;

static void *history(void *unused)
{
    (void)unused;

    /*
     * Historical valid phase:
     *
     *     logical top = 0
     *     bottom      = MARK + 2
     *
     * Later the modular counters advance by MARK and bottom becomes 2.
     *
     * The point of the probe is whether a later observer may still read
     * the old bottom value.
     */
    atomic_store_explicit(
        &bottom,
        MARK + 2,
        memory_order_relaxed);

    atomic_store_explicit(
        &bottom,
        2,
        memory_order_relaxed);

    return 0;
}

static void *batch_owner(void *unused)
{
    (void)unused;

    /*
     * Current logical top is zero.
     *
     * Publish busy representation.
     */
    atomic_store_explicit(
        &topState,
        MARK,
        memory_order_seq_cst);

    return 0;
}

static void *other_thief(void *unused)
{
    (void)unused;

    int state =
        atomic_load_explicit(
            &topState,
            memory_order_acquire);

    int b =
        atomic_load_explicit(
            &bottom,
            memory_order_acquire);

    /*
     * Reduced modular arithmetic:
     *
     * For state=MARK and stale b=MARK+2,
     * the apparent distance is 2 and therefore looks idle.
     */
    int apparentDistance =
        (b - state) & 15;

    if (
        state == MARK &&
        apparentDistance > 0 &&
        apparentDistance <= CAPACITY)
    {
        atomic_store_explicit(
            &misclassified,
            1,
            memory_order_relaxed);

        int expected = state;

        /*
         * Symmetric mark/unmark operation.
         *
         * Applied to an already-busy state this clears busy.
         */
        if (atomic_compare_exchange_strong_explicit(
                &topState,
                &expected,
                (state + MARK) & 15,
                memory_order_seq_cst,
                memory_order_relaxed))
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
    atomic_init(&topState, 0);
    atomic_init(&bottom, 0);

    atomic_init(&misclassified, 0);
    atomic_init(&clearedBusy, 0);

    pthread_t h;
    pthread_t b;
    pthread_t t;

    assert(pthread_create(&h, 0, history, 0) == 0);
    assert(pthread_join(h, 0) == 0);

    assert(pthread_create(&b, 0, batch_owner, 0) == 0);
    assert(pthread_join(b, 0) == 0);

    assert(pthread_create(&t, 0, other_thief, 0) == 0);
    assert(pthread_join(t, 0) == 0);

    int m =
        atomic_load_explicit(
            &misclassified,
            memory_order_relaxed);

    int c =
        atomic_load_explicit(
            &clearedBusy,
            memory_order_relaxed);

    /*
     * P08g requires this outcome to be impossible.
     */
    assert(!(m == 1 && c == 1));

    return 0;
}
