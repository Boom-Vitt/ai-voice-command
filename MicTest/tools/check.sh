#!/usr/bin/env bash
# Typecheck the app and run deterministic component tests on Apple silicon macOS.
# Uses no microphone, Accessibility automation, model runtime or network requests.
set -euo pipefail

TASK_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$TASK_REPO_ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "MicTest checks require Apple silicon macOS and a macOS 26+ SDK." >&2
  exit 1
fi

TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mictest-checks.XXXXXX")"
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
TASK_SOURCE="MicTest/Sources/MicTest"
TASK_TOOLS="MicTest/tools"
TASK_SWIFT_FLAGS=(-swift-version 6 -sdk "$TASK_SDK" -target arm64-apple-macos26.0)

echo "Typechecking MicTest..."
xcrun swiftc "${TASK_SWIFT_FLAGS[@]}" -typecheck -module-name MicTest \
  "$TASK_SOURCE"/*.swift

run_suite() {
  local suite_name="$1"
  shift
  echo "Running $suite_name..."
  xcrun swiftc "${TASK_SWIFT_FLAGS[@]}" -O "$@" \
    -o "$TASK_TEST_DIR/$suite_name"
  "$TASK_TEST_DIR/$suite_name"
}

run_suite audio-pipeline -parse-as-library \
  "$TASK_SOURCE/AudioPipeline.swift" \
  "$TASK_TOOLS/audio-pipeline-local-test/main.swift"

run_suite transcription-queue -parse-as-library \
  "$TASK_SOURCE/LocalTranscriptionQueue.swift" \
  "$TASK_TOOLS/local-transcription-queue-test/main.swift"

run_suite stable-transcript \
  "$TASK_SOURCE/StableTranscriptBuffer.swift" \
  "$TASK_TOOLS/stable-transcript-test/main.swift"

run_suite tail-repair \
  "$TASK_SOURCE/TailRepair.swift" \
  "$TASK_TOOLS/tail-repair-test/main.swift"

run_suite audio-gain \
  "$TASK_SOURCE/SpeechAudioGain.swift" \
  "$TASK_TOOLS/local-transcription-integration-test/GainTest.swift"

run_suite segment-joining \
  "$TASK_SOURCE/LocalWhisperTranscriber.swift" \
  "$TASK_SOURCE/SpeechAudioGain.swift" \
  "$TASK_SOURCE/RefuseRedirects.swift" \
  "$TASK_TOOLS/local-transcription-integration-test/ClientTextTest.swift"

echo "All checks passed: app typecheck and six component suites."
