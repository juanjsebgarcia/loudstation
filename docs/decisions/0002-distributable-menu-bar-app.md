# 0002: A distributable menu bar app, built from source

Date: 2026-11-03. Status: accepted. Builds on 0001.

## Decisions

- **A repository of its own** (`mac-display-audio-fix`, MIT), because the bug affects many Apple Silicon users, not one machine. It began as a script in the author's dotfiles.
- **Build from source with `make install`**, using only the Command Line Tools' `swiftc`, with no Xcode project and no Swift Package. A binary built locally is not quarantined, so Gatekeeper does not block it, and the linker ad-hoc signs it. Distributing a prebuilt app would need a Developer ID and notarisation (Apple Developer Program, $99 a year); that is deferred until there is demand.
- **Three sources, one core:** `Sources/Core` (probe, display mapping, repair), `Sources/CLI` (`fix-display-audio`) and `Sources/App` (Display Audio Fix). `swiftc` compiles the core together with one entry point, so no `public` API surface is needed.
- **Launch at login with a per-user LaunchAgent** that the app writes itself (`~/Library/LaunchAgents/<bundle id>.plist`, `KeepAlive` only on crash), rather than `SMAppService`, which is not dependable for ad-hoc signed apps. The agent is written but not loaded, so toggling it never starts a second copy; a single-instance check covers the rest.
- **Per-monitor menu** (chosen from three mock-ups): each monitor shows a status dot and has Watch and Fix in a submenu. The icon is green when all are healthy, amber when a non-watched monitor is stuck, and red when the watched one is.
- **Auto-fix only the watched monitor**, by default the sound output, because cycling one DCP can break another's audio (see discoveries, 13:07). Fixing a non-watched monitor by hand asks for confirmation.
- **Probe every display-audio output** on each check; a healthy probe takes about 1 s. Stuck outputs are re-probed at most once a minute on timer ticks, because each stuck probe blocks for about 10 s.
- **Guard rails:** at most one repair a minute and three in ten minutes, then auto-fix pauses; checks are skipped while displays sleep; the only active display is never cycled.
- **Audio-to-display mapping by serial:** `AppleCLCD2`'s `IOMFBUUID` equals the audio device UID, and its EDID `ProductAttributes.SerialNumber` equals `CGDisplaySerialNumber`, so identical monitors are told apart. The vendor and model parsed from the UID remain as a fallback, and the tool refuses when that is ambiguous.

## Amendment, 2026-11-03: Homebrew

- **Distribute through a personal tap**, `juanjsebgarcia/homebrew-tap`, with a formula that builds from the tagged source tarball. That needs no signing, unlike a cask, and avoids `homebrew/core`'s notability bar. It requires this repository to be public.
- The formula installs the CLI into `bin` and the app into `libexec`. Formulae cannot write to `~/Applications`, so `fix-display-audio app` finds and opens the bundled app.
- Homebrew runs code from a versioned `Cellar` path that disappears on upgrade, so the login item records the stable `opt` path (`stablePath`), and the app rewrites an existing login item that points at a missing or `Cellar` path.
- `brew uninstall` cannot remove the per-user LaunchAgent, so the caveats tell users to turn off Launch at Login first.
