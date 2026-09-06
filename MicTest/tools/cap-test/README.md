# cap-test — the divergence-repair cap, checked outside the app

`cap_test.swift` copies `commonPrefixLength` / `commonSuffixLength` and the effective-change
formula from `Sources/MicTest/main.swift` (slice S1, 2026-09-03) verbatim and checks eleven
cases against the two caps: `reanchorMaxStaleChars = 10` on `effectiveChange = staleCount −
commonSuffix`, and `retractionMaxStaleChars = 4` on a pure retraction. The cases are the
measured shapes from `TEST-2026-08-31-run5-trace.txt` (the 175-stale wipe at line 115, the
93→83 borderline at line 86, the 3→12 growth at line 144) plus Thai combining-mark cases that
prove the suffix walk never splits a grapheme cluster.

It tests the formula, not the app: `replaceLastInserted` and the trace lines are exercised by
`tools/run-correction-harness.sh` against the real binary.

```bash
xcrun swiftc -swift-version 6 -O -o /tmp/cap_test MicTest/tools/cap-test/cap_test.swift && /tmp/cap_test
```

`RESULT-2026-09-03.txt` is the output of that command on the day the cap landed: `ALL PASS`.
If the formula in `main.swift` changes, change it here in the same commit, or this file lies.
