import Foundation

// Localisation for both front ends. Translations live in the app bundle's <language>.lproj
// folders (generated from Localization/*.json by Tools/localize.py), so macOS picks the
// language, including a per-app language set in System Settings. The CLI has no bundle of its
// own, so it borrows the app bundle installed beside it; failing that it uses the English
// compiled in from EnglishStrings.swift. Log lines are deliberately never localised.

let appName = "LoudStation"
let appBundleName = "\(appName).app"
let commandName = "loudstation"

// Where the app bundle can be: beside a Homebrew install (libexec), else the Applications folders.
func appBundleCandidates() -> [URL] {
    let binary = Bundle.main.executableURL?.resolvingSymlinksInPath()
    return [
        binary?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/\(appBundleName)"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appBundleName)"),
        URL(fileURLWithPath: "/Applications/\(appBundleName)"),
    ].compactMap { $0 }
}

// The app reads its own bundle, and macOS picks the language. A bare executable reading another
// bundle is always given that bundle's development language (English), whatever the user's
// preference, so the CLI picks the language itself and reads that .lproj folder directly.
// A bundle is only borrowed (for strings, or opened by `loudstation app`) when it is really
// LoudStation, the same version as this binary, and owned by this user or root, so a planted or
// stale copy can neither supply mismatched format strings nor be launched.
func isTrustedAppBundle(_ url: URL) -> Bool {
    guard let bundle = Bundle(url: url),
          bundle.bundleIdentifier == "io.github.juanjsebgarcia.loudstation",
          bundle.infoDictionary?["CFBundleShortVersionString"] as? String == toolVersion,
          let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber else { return false }
    return owner.uint32Value == getuid() || owner.uint32Value == 0
}

private let localization: (bundle: Bundle, locale: Locale)? = {
    if Bundle.main.bundleURL.pathExtension == "app" {
        // Dates and lists follow the language the text is in, not just the region.
        return (Bundle.main, Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"))
    }
    // For Tools/strings-preview and for testing a build before installing it.
    let override = ProcessInfo.processInfo.environment["LOUDSTATION_STRINGS_BUNDLE"].map { URL(fileURLWithPath: $0) }
    let candidates = override.map { [$0] } ?? appBundleCandidates().filter(isTrustedAppBundle)
    guard let app = candidates.filter({ FileManager.default.fileExists(atPath: $0.path) }).compactMap({ Bundle(url: $0) }).first,
          let language = Bundle.preferredLocalizations(from: app.localizations, forPreferences: Locale.preferredLanguages).first,
          let path = app.path(forResource: language, ofType: "lproj"),
          let strings = Bundle(path: path) else { return nil }
    return (strings, Locale(identifier: language))
}()

// The locale that dates, numbers and lists follow, so they match the language of the text.
let displayLocale = localization?.locale ?? Locale(identifier: "en")

private let missingMarker = "\u{1}missing\u{1}"

private let specifierPattern = try! NSRegularExpression(
    pattern: "%(?:(\\d+)\\$)?[-+ #0']*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?(?:hh|h|ll|l|q|z|t|j|L)?([@dfsSxXoucCpneEgGaA%])")

// The (position, conversion) pairs of a format string, so a translation whose placeholders
// differ from English (which would crash String(format:) or read stray memory) can be refused.
private func specifiers(_ format: String) -> [String] {
    var sequence = 0
    return specifierPattern.matches(in: format, range: NSRange(format.startIndex..., in: format)).compactMap { match in
        guard let typeRange = Range(match.range(at: 2), in: format) else { return nil }
        let type = String(format[typeRange])
        if type == "%" { return nil }
        sequence += 1
        let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) } ?? sequence
        return "\(position)\(type)"
    }.sorted()
}

// Looks up a key and formats it. Plural keys resolve through .stringsdict, so the same call
// handles "1 display" and "5 displays" correctly in every language.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    L(key, arguments)
}

func L(_ key: String, _ arguments: [CVarArg]) -> String {
    if let localization {
        let format = localization.bundle.localizedString(forKey: key, value: missingMarker, table: nil)
        let english = englishStrings[key]
        let safe = english.map { specifiers($0) == specifiers(format) } ?? true
        if format != missingMarker, safe {
            return arguments.isEmpty ? format : String(format: format, locale: localization.locale, arguments: arguments)
        }
    }
    let english: String
    if let plain = englishStrings[key] {
        english = plain
    } else if let plural = englishPlurals[key] {
        english = resolveEnglishPlural(plural, arguments)
    } else {
        return key
    }
    return arguments.isEmpty ? english : String(format: english, locale: Locale(identifier: "en"), arguments: arguments)
}

// The English fallback's own plural handling: each %N$#@name@ picks "one" or "other" from
// argument N, then the result is formatted normally.
private func resolveEnglishPlural(_ plural: EnglishPlural, _ arguments: [CVarArg]) -> String {
    var format = plural.format
    let token = try? NSRegularExpression(pattern: "%(\\d+)\\$#@([A-Za-z_]+)@")
    let matches = token?.matches(in: format, range: NSRange(format.startIndex..., in: format)) ?? []
    for match in matches.reversed() {
        guard let whole = Range(match.range, in: format),
              let positionRange = Range(match.range(at: 1), in: format),
              let nameRange = Range(match.range(at: 2), in: format),
              let position = Int(format[positionRange]),
              let variable = plural.variables[String(format[nameRange])] else { continue }
        let count = position - 1 < arguments.count ? (arguments[position - 1] as? Int ?? 0) : 0
        format.replaceSubrange(whole, with: count == 1 ? variable.one : variable.other)
    }
    return format
}

// Joins display names the way the user's language lists things ("A and B", "A et B").
func localizedList(_ items: [String], locale: Locale = displayLocale) -> String {
    let formatter = ListFormatter()
    formatter.locale = locale
    return formatter.string(from: items) ?? items.joined(separator: ", ")
}

// "today at 14:20", "yesterday at 09:12" or a short date, in the user's language.
func relativeTime(_ date: Date, locale: Locale = displayLocale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter.string(from: date)
}

func localizedNumber(_ value: Double, locale: Locale = displayLocale) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}
