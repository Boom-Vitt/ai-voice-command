# Isolated ownership checks

Run from the repository root:

```sh
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O \
  MicTest/Sources/MicTest/RefuseRedirects.swift \
  MicTest/Sources/MicTest/WhisperServerManager.swift \
  MicTest/tools/whisper-server-lifecycle/isolation-test.swift \
  -o /tmp/mictest-manager-isolation-test
/tmp/mictest-manager-isolation-test
```

The test launches copies of itself as fake whisper HTTP listeners on unused ports
between 30000 and 55003. Each manager uses its own temporary state directory and
explicit fixture executable. It sends no speech, loads no real model, and stops
only processes created by the test.

Checks cover missing, legacy and mismatched pidfiles; unpinned executables; exact
orphan reclamation; listener replacement; ownership-preserving shutdown; model
discovery priority; and exclusion of VAD arguments from legacy binary launches.
Four gated readiness cases also complete a stop or synchronous start veto while a
health probe is suspended, then release either a stale ready or failed reply.
They verify that the old request cannot return readiness or relaunch a process,
while a later explicit start remains valid. The controlled probe runs only after
the manager has verified its own fixture listener.

`lifecycle-test.swift` is the older real-server performance harness. These isolated
checks do not invoke it.
