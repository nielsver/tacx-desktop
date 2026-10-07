#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_rust_bridge_codegen generate
