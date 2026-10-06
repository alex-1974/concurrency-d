# P08f3 Marked-Top Memory-Model Litmus

This probe isolates the P08d0 owner/batch overlap.

Initial state:

    topState = idle/top0
    bottom   = 4

Owner attempts to remove the newest element by publishing:

    bottom = 3

Batch attempts to reserve the complete old interval:

    topState idle -> busy
    observe bottom

The forbidden outcome is:

    owner observes idle
    batch CAS succeeds
    batch observes bottom == 4

That outcome would allow both owner and batch to include element 4.

Files:

- `marked_top_sc.c`
  - models the P08e/P08f SC-fence structure;
  - expected: assertion is unreachable.

- `marked_top_relaxed_control.c`
  - removes the two SC fences;
  - expected: model checker finds the assertion violation.

The negative control is required to show that the model is capable of
representing the race rather than passing vacuously.
