#!/bin/bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mictest-local-pipeline.XXXXXX")"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$TEST_DIR/../../Sources/MicTest/AudioPipeline.swift" \
  "$TEST_DIR/main.swift" \
  -o "$TASK_BUILD_DIR/pipeline-test"
"$TASK_BUILD_DIR/pipeline-test"
