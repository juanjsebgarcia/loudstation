# 0004: The LoudStation rename, localisation and the icon pipeline

Date: 2026-11-03. Status: accepted. Follows 0003.

## Rename

The project is now **LoudStation**: app `LoudStation.app`, command `loudstation`, bundle ID `io.github.juanjsebgarcia.loudstation`, log `~/Library/Logs/loudstation.log`, state in `~/Library/Application Support/LoudStation/`, repository `juanjsebgarcia/loudstation`, Homebrew formula `loudstation`. Version 0.2.0.

## Localisation

- **Source of truth: `Localization/<language>.json`.** `en.json` is the master and carries a comment per key and a glossary. Other languages carry the same `strings` and `plurals`, plus their own glossary choices and a `reviewed` flag.
- **`Tools/localize.py` validates and generates.** It checks keys, positional placeholders, the CLDR plural categories each language needs, display-width limits for tight UI (East Asian wide characters count double) and the ellipsis character. It then writes `Resources/<language>.lproj/Localizable.strings` and `.stringsdict`, and `Sources/Core/EnglishStrings.swift`. The outputs are committed, so building needs no Python.
- **Plurals use `.stringsdict`,** never a trailing "s". That covers languages with up to six forms (Arabic) and languages with none (Japanese). Variables are positional (`%1$#@name@`) so translators can reorder them.
- **The app** loads strings from its own bundle, so macOS picks the language, including a per-app language set in System Settings. **The CLI** has no bundle under Homebrew, so it borrows the app bundle beside it (Homebrew `libexec` or the Applications folders). Failing that, it falls back to the compiled-in English, whose plural fallback picks one or other by count.
- **The app's name, command and options are passed in as arguments,** never written into translatable text.
- **Lists, dates and numbers** use `ListFormatter`, relative `DateFormatter` output and `NumberFormatter`, so they follow the user's locale. `HH:mm` and "today at" are no longer hard-coded.
- **The terminal status column** pads by display width, so Chinese, Japanese and Korean words line up.
- **Log lines stay English** so they stay useful in bug reports and Apple Feedback. The CLI's help text and option names stay English, as with most command-line tools. Its messages are localised.
- **The CLI ignores Foundation's argument domain** (`-AppleLanguages '(de)'`, `-NS...`), so any language can be tried without changing system settings.
- **36 languages beyond English,** covering every language macOS ships plus regional variants where the wording really differs: es-419, fr-CA, pt-PT, zh-HK. They were machine-drafted with per-language rules (macOS's own wording for Quit, Cancel and Open at Login; quotation marks; capitalisation; right-to-left handling) and are marked `reviewed: false` until a native speaker checks them.

## Icon

- **`Tools/make-icon.swift` draws the icon with Core Graphics** at every size an `.icns` needs, instead of rasterising an SVG, then runs `iconutil`. The design uses a 100-unit grid placed on Apple's macOS icon grid (824 of 1024 pixels, with a soft shadow). Strokes thicken at 16 to 64 pixels so the lines stay visible.
- **The menu bar status icon is the same mark,** a display outline and sawtooth drawn with `NSBezierPath` at 21×18 points and coloured by state, replacing the generic SF Symbols speaker.
