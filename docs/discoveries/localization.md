# Discoveries: localisation

## 2026-11-03

- **A bare executable reading another bundle's strings always gets that bundle's development language.** The CLI is a plain Mach-O with no bundle, and it borrows the app bundle's translations. `Bundle(url: app).localizedString(...)` and `.preferredLocalizations` returned English (`["en"]`) even with `-AppleLanguages '(ru)'`, while `Bundle.preferredLocalizations(from:forPreferences:)` correctly chose `ru`. The fix is to choose the language explicitly, open that `.lproj` folder as its own `Bundle`, and read strings from it. The app itself is a main bundle, so macOS chooses the language normally. Test with `LOUDSTATION_STRINGS_BUNDLE=build/LoudStation.app build/strings-preview -AppleLanguages '(ru)'`.
- **Plural rules from `.stringsdict` work through a per-language `.lproj` bundle** when formatted with `String(format:locale:arguments:)` and that language's locale. Verified at counts 0, 1, 2, 3, 5, 11, 21 and 101:
  - Russian: one, few, many, including 21 and 101 as one.
  - Polish: one, few, many.
  - Arabic: zero, one, two, few, many and other.
  - Japanese: other only.
- **Dates, numbers and lists must use the text's locale, not `Locale.current`.** In the CLI, `Locale.current` follows the system region, so Russian text could get an English "0.5". `displayLocale` comes from the chosen `.lproj`.
- **The CLI's `status` column pads by display width,** so Japanese "音が出ない" and "正常" line up with Latin rows. Terminals do not apply bidirectional layout as AppKit does, so Arabic and Hebrew CLI output is readable but not mirrored. The menu bar app mirrors properly.
- **Foundation reads `-AppleLanguages '(xx)'` from the arguments of any process,** including the CLI, as long as the argument parser does not reject it. `parse` skips `-Apple*` and `-NS*` with their values.
