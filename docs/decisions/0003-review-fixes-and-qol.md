# 0003: Hardening after review, plus first quality-of-life features

Date: 2026-11-03. Status: accepted. Follows three independent reviews (correctness, packaging and docs, quality of life).

## Safety and correctness

- **Build for macOS 13** (`-target arm64-apple-macos13`). Without a target, `swiftc` stamped `minos 27.2`, so the binaries would not have launched on any older macOS despite `LSMinimumSystemVersion` 13.0.
- **A switched-off display is recorded** (`~/Library/Application Support/display-audio-fix/switched-off-display.plist`) before it goes off and cleared once it is back on. `.forSession` configuration outlives the process, so a crash or quit mid-repair used to leave the screen off until logout. Both front ends switch a recorded display back on at start, and the app retries every 5 s for a minute after a failed re-enable. Quitting during a repair waits for it (`applicationShouldTerminate` returns `.terminateLater`).
- **`probe` returns nil (could not check) for any `AudioDeviceStart` error other than `'stop'`,** and nil never leads to a repair in either front end. The healthy threshold scales with the probe length, and probes are at least 0.5 s.
- **The IOProc is destroyed only after `AudioDeviceStart` has returned** (waiting up to 15 s), and leaked deliberately if it never returns, so a late start can never run against a destroyed IOProc.
- **The auto-fix pause latches** after three repairs in ten minutes, until a user action, a genuine display change, wake, or the watched monitor probing healthy. Previously it silently resumed as old attempts aged out.
- **Duplicate audio IDs are tolerated:** dictionaries no longer trap, outputs are de-duplicated, and two `AppleCLCD2` panels with the same `IOMFBUUID` make `display(forAudioUID:)` refuse instead of guessing.
- **The CLI rejects** unknown commands or options, missing values and out-of-range numbers with exit 2. An explicit `--uid` for `fix` must exist and be display audio.
- **`make install` and `make uninstall` boot out the LaunchAgent before stopping the app,** because launchd restarts it on an unsuccessful exit. `uninstall` now also removes settings, the log and the stranded-display record.

## Quality of life

- **The CLI defaults to `status`,** which checks every monitor and changes nothing. Repairs need an explicit `fix`, so trying the command never blanks a screen.
- **First run:** a welcome alert explains the icon and the blackout and asks "Fix Automatically" or "Only Show Status". It also asks for notification permission.
- **Quieter checks:** timer ticks skip monitors already known to have no sound. A dead link only recovers when it is rebuilt, which raises a display-change event and a full check. The log rotates at about 1 MB, and quiet probes no longer log.
- **Notifications** for a restored monitor, one still silent after a repair, a latched pause, and a deferral. Whether they appear for an ad-hoc signed app is to be confirmed on first run.
- **Do not interrupt:** auto-fix waits, and says why, while a microphone is in use or an ordinary window covers the watched monitor exactly (full-screen video, games, presentations). It re-evaluates every 30 s, and Fix This Display still works immediately. A display-sleep power assertion was rejected as a signal, because keep-awake utilities such as Amphetamine can hold one for as long as they are active.
- **Fault counts** per monitor ("No sound 4 times, fixed 3 times") and a total ("Fixed 3 times, last today at 13:16").
- **Wording and accessibility:** Working, No Sound, Checking..., Couldn't Check; status symbols differ in shape as well as colour; the status item has an accessibility label; repairing is blue so it is not confused with the orange "another monitor" state.

## Deferred

`TransferCount`-based detection at playback start, a "Prepare Report for Apple" action, `login-item off`, and a shorter blackout were not chosen for this round. `TransferCount` needs confirming on a stuck engine that is running before anything relies on it.
