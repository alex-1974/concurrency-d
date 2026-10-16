#!/usr/bin/env bash
set -euo pipefail
DC="${1:-dmd}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/research/m1_task_lifetime/prototypes/p11_real_pool"
P23="$BASE/concurrency/research/m1_p23_owned.d"
OWNER="$BASE/concurrency/research/m1_p36_owned.d"
CONSUMER="$BASE/consumer/p36_generational_owner.d"
TMP="$(mktemp -d)"
cleanup() { rm -f -- "$P23" "$OWNER" "$CONSUMER"; rm -rf -- "$TMP"; }
trap cleanup EXIT
[[ ! -e "$P23" && ! -e "$OWNER" && ! -e "$CONSUMER" ]] || exit 2
