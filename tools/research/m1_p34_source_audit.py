#!/usr/bin/env python3
"""P34 review gate: exact immutable owner, pool and P29 research source anatomy.

Source-level counts are NOT allocator event counts or mutex timing evidence.
"""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PINS = {
    "source/concurrency/internal/owned_task.d":
        "e74d6a73f956c562eab176e27687a47249f5815d",
    "source/concurrency/internal/submission_pool.d":
        "b7d8fafcb3179f00cba7e89e28c6d6b9b676353a",
    "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d":
        "d19405f2ef0f8d7159978174c1a919ed6d66764f",
}
OWNER_MARKERS = (
    "auto trySubmit(F)(F callable) @system",
    "synchronized (_mutex)",
    "if (!_pool.hasIngressCapacity())",
    "auto cell = new ResultCell!R();",
    "handle = new TaskHandle!R(cell);",
    "auto node = new OwnedNode!(F, R)(callable, cell);",
    "_retained ~= RetainedTask(node, node.returnedFlag());",
    "const status = _pool.trySubmit(node.reference());",
    "_retained[$ - 1] = RetainedTask.init;",
    "reapCompletedUnderLock();",
)
MANAGER_MARKERS = (
    "bool publish(F)(OwnerHandle h, F work)",
    "++entries[h.slot].operations;",
    "auto result = owner.trySubmit(work);",
    "--entries[h.slot].operations;",
)


def git_blob(raw):
    return hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()


def one_section(source, begin, end):
    if source.count(begin) != 1:
        raise ValueError("P34 ambiguous begin anchor: " + begin)
    after = source.split(begin, 1)[1]
    if end not in after:
        raise ValueError("P34 missing section end: " + end)
    return after.split(end, 1)[0]


def audit(root):
    sources = {}
    for name, wanted in PINS.items():
        raw = (root / name).read_bytes()
        actual = git_blob(raw)
        if actual != wanted:
            raise ValueError(f"P34 source pin drift: {name}: {actual} != {wanted}")
        sources[name] = raw.decode()
    owner = sources["source/concurrency/internal/owned_task.d"]
    method = one_section(owner, "    auto trySubmit(F)(F callable) @system",
                         "    private void reapCompletedUnderLock()")
    for marker in OWNER_MARKERS[1:]:
        if marker not in method:
            raise ValueError("P34 admission anatomy drift: " + marker)
    p29 = sources[
        "research/m1_task_lifetime/prototypes/p11_real_pool/consumer/p29_generational_owner.d"
    ]
    manager = one_section(p29, "    bool publish(F)(OwnerHandle h, F work)",
                          "    bool orphan(OwnerHandle h)")
    for marker in MANAGER_MARKERS[1:]:
        if marker not in manager:
            raise ValueError("P34 manager anatomy drift: " + marker)
    if not (manager.index("++entries[h.slot].operations;") <
            manager.index("auto result = owner.trySubmit(work);") <
            manager.index("--entries[h.slot].operations;")):
        raise ValueError("P34 manager operation ordering drift")
    print("P34_PINNED_OWNED_ADMISSION_SOURCE_PASS")
    print("P34_SOURCE_OBSERVATION three-new-expressions-under-owner-lock; "
          "manager-two-separated-lock-phases; NOT allocator calls")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    audit(args.root)


if __name__ == "__main__":
    main()
