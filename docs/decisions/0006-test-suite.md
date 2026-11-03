# 0006: A test suite that never touches displays

Date: 2026-11-03. Status: accepted.

- **The auto-fix rules moved out of the app into `Sources/Core/AutoFixPolicy.swift`:** a value type with an injected clock that the app feeds events and asks for decisions (fix, wait, or blocked, and why). The rules can then be tested as scenarios in simulated time. One such scenario, a sink re-announcing itself every 20 s for two hours, found that a repeatedly lifted pause would re-send the "paused" notification. The policy now announces a pause at most once per window.
- **`make test` runs four layers:**
  - `Tests/Unit/main.swift`: a plain runner compiled with the core by `swiftc`, so no Xcode and no XCTest are needed. It covers paths, log redaction, display identity, clock movement, the probe hand-off, crash-recovery records, localisation fallbacks and formatting, and the policy scenarios.
  - `Tests/cli.sh`: argument handling, exit codes and localised messages.
  - `Tests/test_localize.py`: the validator must still catch each kind of bad translation.
  - `Tools/localize.py --check`.
- **Tests are isolated from real installations.** `LOUDSTATION_LOG` and `LOUDSTATION_STATE_DIR` override the log and state folder, and `make test` points them at a temporary folder. The unit runner refuses to start without them. Crash-recovery tests use a vendor and model that match no real display, so recovery can never switch a screen on or off.
- **Mutation-checked when written:** each of six deliberate bugs made at least one test fail. The bugs: dropping the minimum gap, clearing history on wake, skipping confirmation, skipping redaction, trusting mismatched translations, and counting clock resets.
- **The display cycle itself is not automated.** It needs real displays with real dead links, so `docs/releasing.md` has a short hardware checklist instead.
- **CI** (`.github/workflows/ci.yml`, an Apple Silicon `macos-15` runner) builds, runs `make test`, checks that the binaries target macOS 13, and checks that the generated strings match `Localization/`.

## Amendment, 2026-11-03: final review fixes

A final code review found that automatic fixes started from a confirmation retry were recorded as manual: `automatic` was inferred from the reason string, which was "retry". As a result, notifications never fired and giving up never engaged. The tests missed it because the flag lived in the app. Changes:

- **The automatic flag is passed explicitly and stored by the policy** (`fixStarted(now:automatic:)`). A test fails if it is ignored, which was mutation-checked.
- **`fixFinished(_:result:)` takes `.fixed`, `.stillSilent` or `.notAttempted`.** A fix that switched nothing off (a guard, the cross-process lock, an earlier stranded display) counts neither as a failure nor against the rate limit. `cycle` returns `.done`, `.refused` or `.stranded`, and `RepairStatus` gains `.notAttempted`.
- **Confirmation now rests on real probes:**
  - `observedSilent` is fed only by probe results.
  - `decide` needs two silent probes at least 10 s apart.
  - Every wait re-probes the watched display rather than re-deciding on old results.
  - The final probe still runs just before cycling.
- **Earlier stranded displays:** `cycle` refuses, or recovers first, while an earlier stranded display is recorded. It also evaluates its guards inside the lock, so a later cycle cannot overwrite the record of a display that is still off.
- **Stranded recovery runs as one retry chain** and notifies once. A display that is not listed is tried by its recorded ID before its record is discarded.
- **The login item is rewritten only when broken** (a missing or `Cellar` path, or an older format). It no longer flips to whichever copy launched last.
- **Events are not dropped:**
  - Display changes during a fix are remembered.
  - Non-timer checks requested during a check run afterwards.
  - The probe window starts once `AudioDeviceStart` returns, within 2 s.
- **Tests and logging:**
  - `Tests/cli.sh` uses the fixture bundle for English expectations, so it passes on a Mac in any language.
  - It refuses to run without a temporary state folder.
  - Unit tests now cover the health threshold and that the built app is a trusted bundle for this version.
  - Redaction only replaces the home folder as a whole path component.
  - The "same audio ID" warning is logged once per ID.
