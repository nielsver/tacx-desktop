#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
(cd rust && cargo test && cargo build)
export LD_LIBRARY_PATH="$PWD/rust/target/debug:${LD_LIBRARY_PATH:-}"
flutter analyze
flutter test
