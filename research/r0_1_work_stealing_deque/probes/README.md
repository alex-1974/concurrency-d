# Probes

Each probe answers one narrowly defined question.

Planned initial sequence:

- P01 bounded sequential invariants
- P02 owner/thief last-item race
- P03 multi-thief accounting
- P04 wraparound
- P05 baseline memory-ordering implementation
- P06 cached-top variant
- P07 steal-one versus batch
- P08 queue layout / false-sharing control
- P09 TaskRef width control


## Executed R0.1 extensions

The research sequence evolved as evidence identified additional questions.

- P02b modular last-item wrap race
- P02c modular RMW last-item wrap race
- P03b modular multi-thief wrap accounting
- P03c modular RMW multi-thief wrap accounting
- P05 signed versus modular code generation
- P06 signed/modular and corrected hot-path controls
- P06c modular fence versus modular RMW hot paths
- P07 Taskflow external reference and fence-lowering diagnostics
- P08 queue layout / false-sharing control with fixed thread affinity
- P08 Taskflow 1-owner/1-thief streaming parity control

Probe numbering identifies the research sequence; it is not a public API
versioning scheme.
