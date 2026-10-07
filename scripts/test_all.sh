#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
(cd rust && cargo test)
flutter analyze
flutter test
