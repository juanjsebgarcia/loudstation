// Prints every LoudStation string in one language with sample values, so translations can be
// proofread and plural forms checked at real counts.
//
//   make app
//   swiftc -o build/strings-preview Sources/Core/*.swift Tools/strings-preview/main.swift
//   LOUDSTATION_STRINGS_BUNDLE=build/LoudStation.app build/strings-preview -AppleLanguages '(pl)'
//
// Without LOUDSTATION_STRINGS_BUNDLE it shows the compiled-in English fallback.

import Foundation

let display = "DELL U2518D (HDMI)"
let other = "DELL U2520D"
let samples: [String: [CVarArg]] = [
    "headline.speakers_on": [display], "headline.fixing": [display],
    "accessibility.status": [appName, "…"], "display.with_connection": ["DELL U2518D", "HDMI"],
    "display.with_connection_number": ["DELL U2518D", "DisplayPort", 2],
    "row.with_tags": [display, "…", "…"], "row.plain": [display, "…"],
    "submenu.checked": ["14:20"], "menu.last_checked": ["14:20"], "menu.quit": [appName],
    "note.fixing": [display], "note.collateral": [display, other],
    "outcome.fixed": [display], "outcome.still_silent": [display], "outcome.unverified": [display],
    "outcome.unknown_display": [display], "outcome.cycle_failed": [display],
    "welcome.title": [appName], "confirm.title": [other], "confirm.body": [other],
    "notify.fixed.body": [display], "notify.fixed.body_collateral": [display, other],
    "notify.still_silent.body": [display], "notify.waiting_call.body": [display],
    "notify.waiting_full_screen.body": [display], "notify.stranded.body": [appName],
    "cli.status.hint_fix": [commandName], "cli.status.hint_other": [commandName, "10AC50A1-…"],
    "cli.couldnt_check": [display], "cli.list.on_display": ["4"], "cli.app.opened": [appName],
    "cli.app.not_found": [appBundleName], "cli.app.open_failed": [appName],
    "cli.error.prefix": [commandName, "…"], "cli.error.see_help": [commandName],
    "cli.error.needs_value": ["--hold"], "cli.error.range": ["--hold", "0.5", "30", "1e9"],
    "cli.error.one_command": ["fix", "relink"], "cli.error.unknown_option": ["--hodl"],
    "cli.error.unknown_command": ["prob"], "cli.error.no_output": ["NOPE", commandName],
    "cli.error.not_display": ["MacBook Pro Speakers"],
]
let counts = [0, 1, 2, 3, 5, 11, 21, 101]
let plurals: [String: (Int) -> [CVarArg]] = [
    "headline.others_silent": { [$0] }, "menu.interval.seconds": { [$0] },
    "submenu.counts": { [$0, 1] }, "menu.fix_summary": { [$0, "14:20"] },
    "note.paused": { [$0] }, "notify.paused.body": { [$0, display] },
]

for key in englishStrings.keys.sorted() {
    print("\(key)\n    \(L(key, samples[key] ?? []).replacingOccurrences(of: "\n", with: "\n    "))")
}
for key in englishPlurals.keys.sorted() {
    print(key)
    for count in counts {
        print("    \(count): \(L(key, plurals[key]?(count) ?? [count]))")
    }
}
