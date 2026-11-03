import CoreAudio
import CoreGraphics
import Foundation

// loudstation: one-shot command-line front end to Sources/Core. Messages are localised; the
// help text and option names stay in English, as with most command-line tools.
//
// Exit codes: 0 working (or nothing to do, or repaired), 1 no sound (still silent after a fix),
// 2 usage error or no such display, 3 switching the display off and on failed, 4 could not check.

let usage = """
\(commandName) \(toolVersion) - detect and fix silent monitor speakers on Apple Silicon Macs

  status (default)  Check every display's sound and print whether it works; changes nothing
  fix               Check the sound output; if it is a display with no sound, switch that display
                    off and on (about 3s of black screen), check again, and report any other
                    display the fix knocked out (never touched)
  relink            Like fix, but without checking first
  list              Audio outputs, the displays behind them, and all displays
  app               Open the \(appName) menu bar app

Options:
  --uid <id>        Act on this display's audio output instead (IDs are shown by `list`)
  --seconds <s>     Length of each check, 0.5 to 60 (default 3)
  --hold <s>        How long the display stays off, 0.5 to 30 (default 3)
  --settle <s>      Wait before checking again, 0 to 60 (default 4)
  -h, --help        This help        --version   Print the version

Exit codes: 0 working or fixed, 1 no sound, 2 usage error or no such display,
3 switching the display off and on failed, 4 could not check.
Messages follow the system language; try another with: -AppleLanguages '(de)'
Log: ~/Library/Logs/loudstation.log
"""

func fail(_ message: String) -> Never {
    let text = L("cli.error.prefix", commandName, message) + "\n" + L("cli.error.see_help", commandName) + "\n"
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

struct Options {
    var command = "status"
    var uid: String?
    var seconds = 3.0
    var hold = 3.0
    var settle = 4.0
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var commandSeen = false
    var index = 0
    func number(_ flag: String, in range: ClosedRange<Double>) -> Double {
        index += 1
        guard index < arguments.count else { fail(L("cli.error.needs_value", flag)) }
        guard let value = Double(arguments[index]), value.isFinite, range.contains(value) else {
            fail(L("cli.error.range", flag, localizedNumber(range.lowerBound), localizedNumber(range.upperBound), arguments[index]))
        }
        return value
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help", "help":
            print(usage)
            exit(0)
        case "--version", "version":
            print("\(commandName) \(toolVersion)")
            exit(0)
        case "--uid":
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("-") else { fail(L("cli.error.needs_value", argument)) }
            options.uid = arguments[index]
        case "--seconds":
            options.seconds = number(argument, in: minimumProbeSeconds...60)
        case "--hold":
            options.hold = number(argument, in: holdRange)
        case "--settle":
            options.settle = number(argument, in: settleRange)
        case "status", "probe", "fix", "relink", "list", "app":
            guard !commandSeen else { fail(L("cli.error.one_command", options.command, argument)) }
            commandSeen = true
            options.command = argument == "probe" ? "status" : argument
        // Foundation's own argument domain, e.g. -AppleLanguages '(de)': Foundation reads it,
        // so it and its value are skipped here.
        case _ where argument.hasPrefix("-Apple") || argument.hasPrefix("-NS"):
            index += 1
        default:
            fail(argument.hasPrefix("-") ? L("cli.error.unknown_option", argument) : L("cli.error.unknown_command", argument))
        }
        index += 1
    }
    return options
}

let options = parse(Array(CommandLine.arguments.dropFirst()))

// Run as root it would create root-owned files in the user's folders that the app then cannot
// write, including the record that switches a display back on after a crash.
if runningAsRoot && options.command != "list" { fail(L("cli.error.root", commandName)) }

// The display `fix` works on: an explicit --uid, which must be a display's audio, otherwise
// the sound output when it is one. Exits 2 when an explicit --uid is not usable.
func fixTarget() -> AudioObjectID? {
    if let explicit = options.uid {
        guard let dev = device(withUID: explicit) else { fail(L("cli.error.no_output", explicit, commandName)) }
        guard isDisplayAudio(dev) else { fail(L("cli.error.not_display", name(of: dev))) }
        return dev
    }
    guard let dev = defaultOutputDevice(), isDisplayAudio(dev) else { return nil }
    return dev
}

func fix(force: Bool) -> Int32 {
    guard recoverStrandedDisplay() else {
        print(L("cli.stranded"))
        return 3
    }
    guard let dev = fixTarget() else {
        print(L("cli.nothing_to_fix"))
        return 0
    }
    if !force {
        switch probe(dev, seconds: options.seconds) {
        case true?:
            return 0
        case nil:
            print(L("cli.couldnt_check", name(of: dev)))
            return 4
        case false?:
            break
        }
    }
    let outcome = repair(dev, probeSeconds: options.seconds, hold: options.hold, settle: options.settle)
    print(outcome.message)
    if !outcome.collateral.isEmpty { print(L("note.collateral", name(of: dev), localizedList(outcome.collateral))) }
    return outcome.status.exitCode
}

// Terminal columns a string occupies: East Asian wide characters take two, combining marks none.
func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { total, scalar in
        if scalar.properties.generalCategory == .nonspacingMark { return total }
        let v = scalar.value
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
        return total + (wide ? 2 : 1)
    }
}

func padded(_ text: String, to columns: Int) -> String {
    text + String(repeating: " ", count: max(1, columns - displayWidth(text)))
}

func status() -> Int32 {
    var outputs = displayAudioOutputs()
    if let explicit = options.uid {
        outputs = outputs.filter { $0.uid == explicit }
        if outputs.isEmpty { fail(L("cli.error.no_output", explicit, commandName)) }
    }
    if outputs.isEmpty {
        print(L("cli.none"))
        return 0
    }
    let sound = defaultOutputDevice()
    let words = [L("cli.status.working"), L("cli.status.no_sound"), L("cli.status.couldnt_check")]
    let column = (words.map(displayWidth).max() ?? 14) + 2
    var anyStuck = false
    var anyUnknown = false
    var soundOutputStuck = false
    var stuckOthers: [String] = []
    // Every display is checked at once; a silent one blocks for about 10 seconds, so in
    // sequence they would add up. Results print in a stable order afterwards.
    var results = [Bool?](repeating: nil, count: outputs.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: outputs.count) { index in
        let result = probe(outputs[index].device, seconds: options.seconds, log: false)
        lock.lock()
        results[index] = result
        lock.unlock()
    }
    for (index, output) in outputs.enumerated() {
        let result = results[index]
        let isSoundOutput = output.device == sound
        let verdict: String
        switch result {
        case true?:
            verdict = words[0]
        case false?:
            verdict = words[1]
            anyStuck = true
            if isSoundOutput { soundOutputStuck = true } else { stuckOthers.append(output.uid) }
        case nil:
            verdict = words[2]
            anyUnknown = true
        }
        let tag = isSoundOutput ? "  " + L("cli.status.sound_output") : ""
        print("\(padded(verdict, to: column)) \(output.name) [\(output.transport)]\(tag)  \(output.uid)")
    }
    if soundOutputStuck {
        print("\n" + L("cli.status.hint_fix", commandName))
    } else if let other = stuckOthers.first {
        print("\n" + L("cli.status.hint_other", commandName, other))
    }
    return anyStuck ? 1 : (anyUnknown ? 4 : 0)
}

func listEverything() {
    let engines = displayAudioEngineUIDs()
    let defaultOutput = defaultOutputDevice()
    let systemOutput = systemSoundsOutputDevice()
    print(L("cli.list.outputs"))
    for dev in audioDevices() where outputStreamCount(dev) > 0 {
        let devUID = uid(of: dev) ?? "?"
        var tags: [String] = []
        if dev == defaultOutput { tags.append(L("cli.list.default")) }
        if dev == systemOutput { tags.append(L("cli.list.system_sounds")) }
        if engines.contains(devUID), let display = display(forAudioUID: devUID) { tags.append(L("cli.list.on_display", String(display))) }
        print("  \(name(of: dev))  [\(devUID)]  \(tags.joined(separator: ", "))")
    }
    print(L("cli.list.displays"))
    for display in onlineDisplays() {
        print("  \(describe(display))")
    }
}

func openApp() -> Int32 {
    let candidates = appBundleCandidates()
    guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) && isTrustedAppBundle($0) }) else {
        print(L("cli.app.not_found", appBundleName) + "\n" + candidates.map { "  \($0.path)" }.joined(separator: "\n"))
        return 2
    }
    let path = stablePath(app.path)
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // A new instance even if an older copy is still running from the same path (Homebrew's opt
    // link), so it can take over; a copy of the same version simply quits again.
    open.arguments = ["-n", path]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        print(L("cli.app.open_failed", appName))
        return 3
    }
    guard open.terminationStatus == 0 else {
        print(L("cli.app.open_failed", appName))
        return 3
    }
    print(L("cli.app.opened", appName))
    return 0
}

switch options.command {
case "fix":
    exit(fix(force: false))
case "relink":
    exit(fix(force: true))
case "list":
    listEverything()
case "app":
    exit(openApp())
default:
    exit(status())
}
