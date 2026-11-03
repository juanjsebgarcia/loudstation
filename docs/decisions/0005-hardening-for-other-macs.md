# 0005: Hardening for other people's Macs

Date: 2026-11-03. Status: accepted. Follows a real-world correctness review, a performance and security review, research into the private API's history, and research into where people report the bug.

## Automatic fixing

- **Settle, confirm, re-check.** Auto-fix waits for displays to settle after launch, wake, a topology change or a session switch (12 s). It then needs the watched display to be silent twice, at least 10 s apart, and probes once more just before cycling. Slow sinks (TVs, receivers, docks) caught mid-negotiation, and verdicts minutes old after a deferral, no longer trigger a cycle.
- **Rate limits that cannot be defeated.** The cycle history is cleared only by an explicit user action. Wake no longer clears it, and neither does every reconfiguration. A latched pause lifts only on a real topology change (the set of online display IDs or display-audio UIDs changed), not on mode, arrangement or wake events. After two failed automatic fixes, a display is left to the user until it is reconnected.
- **Unfixable setups are recognised up front.** No identifiable screen, the only physical screen, a mirrored display, or a missing private function each get one persistent note, with no attempts and no notifications.
- **Events are not lost.** Our own fix's reconfiguration and output-change events are ignored while fixing and for 5 s after. A display change that arrives during an ordinary check is remembered and re-checked. A stranded display is recovered on any display change and on timer ticks, not only at launch.
- **Deferral signals:**
  - On macOS 14 and later, "in a call" uses the per-process `kAudioProcessPropertyIsRunningInput`, so a USB headset that is only playing output does not count. Earlier releases use the device-wide flag.
  - Shielding-level windows count as full screen (`CGDisplayIsCaptured` is unavailable in the SDK).
  - A mouse drag in progress delays the fix by 5 s.
- **Fast user switching:** a background session neither probes nor fixes.

## Probing

- **The start runs on a dedicated `Thread`,** not the GCD pool, so a start that never returns cannot exhaust the pool.
- **A device whose earlier start is still blocked** is reported stuck without a new IOProc.
- **A start/probe hand-off** makes whichever side finishes last stop and destroy the IOProc. A late start can therefore no longer leave silence playing for ever and holding a sleep assertion.
- **Late start errors other than `'stop'` are seen** and give "could not check".
- **A device hogged by another process** gives "could not check".
- **Health is forward clock movement of at least 30% of nominal rate × seconds,** not a callback count, so buffer size and sample-time resets mid-probe do not matter.

## Cycling

- **A cross-process `flock` lock** means the CLI and the app never cycle displays at the same time.
- **SIGHUP, SIGQUIT and SIGTSTP are ignored as well as SIGINT and SIGTERM,** so closing a terminal or pressing Ctrl-Z cannot strand a display.
- **The crash-recovery record carries the owning PID, the boot session and the panel identity.** It must be written before a display goes off, and a cycle refuses if it cannot be. Recovery finds the panel by identity, ignores records from another boot, leaves a live process's in-progress cycle alone, and discards corrupt records instead of trapping.
- **The only-screen guard counts physical screens only** (built-in, or an `AppleCLCD2` panel), and mirrored displays are refused.
- **The sound and system-sounds outputs are restored** if macOS moved them while a display was off.
- **The private function is resolved once from the SkyLight path** on the sealed system volume. The `RTLD_DEFAULT` fallback is gone.

## Timer and resources

- **Timer ticks probe only the watched display.** Everything else refreshes on events.
- **The default interval is 60 s.**
- **Ticks are skipped in Low Power Mode.** The timer stops while displays sleep and has 15% tolerance.
- **The status glyph is cached per state,** and redrawn only when the state changes.

## Security and robustness

- **Neither front end runs as root.**
- **Log hygiene:** the log redacts the home folder and the serial group of display-audio UIDs, opens with `O_NOFOLLOW | O_CLOEXEC` and mode 0600, and uses a fixed POSIX timestamp. Show Log reveals the file in Finder rather than opening it.
- **The CLI borrows translations from, and `loudstation app` opens, only a bundle** with LoudStation's identifier, the same version, and owned by the user or root.
- **`L()` falls back to English** when a translation's format specifiers differ from English.
- **The validator** parses the full printf grammar, compares plural value types, and deletes a failing language's `.lproj` instead of shipping stale strings.
- **The login item runs through `/bin/sh -c '[ -x "$0" ] && exec "$0"; exit 0'`,** so after `brew uninstall` it exits successfully and launchd does not keep retrying. It also has `ThrottleInterval` 60, no `Interactive` process type, an atomic write, and is rewritten whenever it differs from what this copy expects.
- **Both binaries are signed with the hardened runtime** (ad-hoc).
- **The Homebrew formula no longer offers an unpinned `head` build.**

## Deferred

- **Identical monitors from the same production week:** they share an audio UID. Telling them apart needs mapping through the `dcpextN` and `dispextN` registry topology, which is unverified without such a setup. Until then the tool refuses, and the README says so.
- **Detecting the fault without probing,** using `TransferCount` or `AudioDeviceGetCurrentTime`, until it can be confirmed on a stuck engine that is running.
