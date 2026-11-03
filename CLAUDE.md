# LoudStation

Read `docs/README.md` first: findings go in `docs/discoveries/`, decisions in `docs/decisions/`, in the same change that relies on them.

- Build: `make` (CLI in `build/loudstation`, app in `build/LoudStation.app`); `make install` / `make uninstall`.
- Test: `make test` runs the unit tests (`Tests/Unit`, pure Core logic including `AutoFixPolicy` scenarios), CLI tests (`Tests/cli.sh`), validator tests (`Tests/test_localize.py`) and translation validation. It points the log and state folder at a temporary folder; never run the unit-test binary without it. Add a test with every behaviour change, and put new auto-fix rules in `AutoFixPolicy`, not in the app.
- Strings: edit `Localization/*.json` (English is `en.json`, the master), then `make strings`. Never edit `Resources/*.lproj` or `Sources/Core/EnglishStrings.swift` by hand; they are generated. Log lines (`say`) stay in English; anything shown to the user goes through `L()`.
- Icon: edit `Tools/make-icon.swift`, then `make icon`.
- `loudstation status` and `list` are safe. Anything that cycles a display (`fix`, `relink`, the app's Fix Now or automatic fixing) blanks a screen; only run it with the user's go-ahead.
- Use `/usr/bin/log`, not `log`, in shell commands.
