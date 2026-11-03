import Foundation

// LoudStation's unit tests: the pure logic in Sources/Core, compiled together with it by
// `make test`. Nothing here probes, fixes or cycles a display. `make test` points the log and
// the state folder at a temporary folder; the runner refuses to start otherwise, so it can never
// touch a real installation's files.

let environment = ProcessInfo.processInfo.environment
guard let stateDirectory = environment["LOUDSTATION_STATE_DIR"], environment["LOUDSTATION_LOG"] != nil,
      environment["LOUDSTATION_STRINGS_BUNDLE"] != nil else {
    FileHandle.standardError.write(Data("Run through `make test`, which sets LOUDSTATION_STATE_DIR, LOUDSTATION_LOG and LOUDSTATION_STRINGS_BUNDLE.\n".utf8))
    exit(2)
}

var passed = 0
var failed = 0

func expect(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL Tests/Unit/main.swift:\(line): \(name)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    expect(actual == expected, "\(name): got \(actual), expected \(expected)", line: line)
}

func section(_ title: String) {
    print("- \(title)")
}

// MARK: Paths

section("stablePath maps Homebrew's versioned Cellar paths to opt")
let scratch = URL(fileURLWithPath: stateDirectory).deletingLastPathComponent().appendingPathComponent("brew")
let cellarBinary = scratch.appendingPathComponent("Cellar/loudstation/0.2.0/bin/loudstation")
let optBinary = scratch.appendingPathComponent("opt/loudstation/bin/loudstation")
try FileManager.default.createDirectory(at: cellarBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: optBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: optBinary.path, contents: Data())
expectEqual(stablePath(cellarBinary.path), optBinary.path, "Cellar path becomes the opt path")
expectEqual(stablePath("/usr/local/bin/loudstation"), "/usr/local/bin/loudstation", "a non-Cellar path is unchanged")
let orphan = scratch.appendingPathComponent("Cellar/other/1.0/bin/other").path
expectEqual(stablePath(orphan), orphan, "a Cellar path with no opt link is unchanged")

// MARK: Logging

section("Log redaction")
let home = FileManager.default.homeDirectoryForCurrentUser.path
expectEqual(redactedForLog("Wrote \(home)/Library/LaunchAgents/x.plist"), "Wrote ~/Library/LaunchAgents/x.plist", "home folder becomes ~")
let zeroSerial = "10AC3C41-0000-0000-041D-010380371F78"
expectEqual(redactedForLog(zeroSerial), zeroSerial, "a UID without a serial is kept")
let withSerial = "10AC3C41-1234-5678-041D-010380371F78"
let redacted = redactedForLog(withSerial)
expect(!redacted.contains("1234-5678"), "the serial group is removed")
expect(redacted.hasPrefix("10AC3C41-#") && redacted.hasSuffix("-041D-010380371F78"), "vendor, model and week stay readable")
expectEqual(redactedForLog(withSerial), redacted, "the hash is stable")
expect(redactedForLog("10AC3C41-9999-5678-041D-010380371F78") != redacted, "different serials hash differently")
expectEqual(redactedForLog("not a uid: DEADBEEF-1234"), "not a uid: DEADBEEF-1234", "other hex is untouched")
expectEqual(redactedForLog("\(home)2/Library"), "\(home)2/Library", "a sibling folder sharing the home prefix is left alone")
expect(logURL.path.hasPrefix(stateDirectory) || logURL.path == environment["LOUDSTATION_LOG"], "the log is the test log")

// MARK: Display identity

section("Display identity from an audio UID")
let identity = identityFromUID(zeroSerial)
expectEqual(identity?.vendor, UInt32(0x10AC), "vendor")
expectEqual(identity?.model, UInt32(0x413C), "model is byte-swapped back")
expect(identity?.serial == nil, "no serial from the UID")
expect(identityFromUID("10AC") == nil, "a short UID gives nothing")
expect(identityFromUID("ZZZZZZZZ-0000") == nil, "non-hex gives nothing")

// MARK: Probing

section("Clock movement")
let tally = CallbackTally()
for sample in [0.0, 512, 1024, 1536] { tally.record(sample) }
expectEqual(tally.snapshot().advanced, 1536.0, "forward movement is summed")
tally.record(256)
tally.record(768)
expectEqual(tally.snapshot().advanced, 2048.0, "a reset is not counted, movement after it is")
expectEqual(tally.snapshot().count, 6, "every callback is counted")

section("Probe and start hand-off")
let startFirst = StartHandoff()
expect(startFirst.finished(0) == false, "when the start returns first, the start thread does not clean up")
expectEqual(startFirst.abandonUnlessFinished(), OSStatus(0) as OSStatus?, "the probe then sees the status")
let probeFirst = StartHandoff()
expect(probeFirst.abandonUnlessFinished() == nil, "when the probe gives up first, there is no status yet")
expect(probeFirst.finished(1_937_010_544) == true, "and the late start cleans up after itself")

// MARK: Crash recovery

section("Switched-off display record")
expectEqual(stateFolderURL.path, stateDirectory, "the state folder is the test folder")
func writeRecord(_ record: [String: Any]) {
    try! FileManager.default.createDirectory(at: stateFolderURL, withIntermediateDirectories: true)
    try! PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0).write(to: strandedMarkerURL)
}
func recordExists() -> Bool { FileManager.default.fileExists(atPath: strandedMarkerURL.path) }
// Vendor 1 and model 1 match no real display, so recovery can never switch anything on here.
let base: [String: Any] = ["display": 4, "pid": 1, "since": Date(), "boot": bootTime(), "vendor": 1, "model": 1, "serial": 1]

writeRecord(base.merging(["display": -5]) { $1 })
expect(strandedRecord() == nil && !recordExists(), "a negative display ID is discarded, not trapped on")
writeRecord(base.merging(["display": "four"]) { $1 })
expect(strandedRecord() == nil && !recordExists(), "a wrongly typed record is discarded")
writeRecord(base.merging(["boot": 1]) { $1 })
expect(recoverStrandedDisplay() && !recordExists(), "a record from another boot is cleared")
writeRecord(base.merging(["pid": Int(getppid())]) { $1 })
expect(recoverStrandedDisplay() && recordExists(), "a live process's fresh record is left alone")
let finished = Process()
finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
try finished.run()
finished.waitUntilExit()
writeRecord(base.merging(["pid": Int(finished.processIdentifier)]) { $1 })
expect(recoverStrandedDisplay() && !recordExists(), "a dead process's record for an absent display is cleared")

// MARK: Localisation

section("Localisation")
expectEqual(L("menu.check_now"), "Check Now (fixture)", "translations come from the bundle")
expectEqual(L("headline.fixing", "DELL"), "Fixing DELL…", "a translation with mismatched placeholders falls back to English")
expectEqual(L("headline.others_silent", 1), "1 other display has no sound", "English plural fallback, one")
expectEqual(L("headline.others_silent", 3), "3 other displays have no sound", "English plural fallback, other")
expectEqual(L("submenu.counts", 1, 2), "No sound 1 time, fixed 2 times", "two plural variables")
expectEqual(L("no.such.key"), "no.such.key", "an unknown key returns itself")
expectEqual(localizedNumber(0.5, locale: Locale(identifier: "de")), "0,5", "German decimal comma")
expectEqual(localizedNumber(30, locale: Locale(identifier: "en")), "30", "whole numbers have no decimals")
expectEqual(localizedList(["A", "B"], locale: Locale(identifier: "en")), "A and B", "English list")
expectEqual(localizedList(["A", "B"], locale: Locale(identifier: "fr")), "A et B", "French list")
expect(relativeTime(Date(), locale: Locale(identifier: "en")).lowercased().contains("today"), "today is relative")

// MARK: Automatic fixing policy

let origin = Date(timeIntervalSince1970: 1_000_000)
func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
func settled() -> AutoFixPolicy { AutoFixPolicy(now: at(-100)) }
// A probe found the display silent, then the app asks what to do: the app's real sequence.
func silent(_ p: inout AutoFixPolicy, _ seconds: Double, blocker: String? = nil) -> AutoFixPolicy.Decision {
    p.observedSilent("A", now: at(seconds))
    return p.decide("A", now: at(seconds), blocker: blocker)
}
// Two silent probes 10 s apart, then a fix that ends with `result`.
func fixOnce(_ p: inout AutoFixPolicy, from start: Double, automatic: Bool = true, result: AutoFixPolicy.FixResult) {
    _ = silent(&p, start)
    _ = silent(&p, start + 10)
    p.fixStarted(now: at(start + 10), automatic: automatic)
    p.fixFinished("A", result: result)
}

section("Auto-fix waits for displays to settle and for two real silent probes")
var policy = AutoFixPolicy(now: at(0))
expectEqual(silent(&policy, 1), .wait(.confirming, seconds: 11), "settling after launch")
expectEqual(policy.decide("A", now: at(12.5), blocker: nil), .wait(.confirming, seconds: 0.5), "no fix without a second probe, even once settled")
expectEqual(silent(&policy, 12.5), .fix, "a second silent probe 11.5 s later allows a fix")
policy = settled()
expectEqual(silent(&policy, 0), .wait(.confirming, seconds: 10), "a first silent probe waits for a second")
expectEqual(silent(&policy, 4), .wait(.confirming, seconds: 6), "a second probe too soon still waits")
policy.observedWorking("A", isWatched: true)
expectEqual(silent(&policy, 11), .wait(.confirming, seconds: 10), "a working probe in between restarts confirmation")
policy = settled()
_ = silent(&policy, 0)
policy.displaysMaySettle(now: at(5))
expectEqual(silent(&policy, 10), .wait(.confirming, seconds: 7), "a wake mid-confirmation waits for settling")

section("Auto-fix rate limits")
policy = settled()
fixOnce(&policy, from: 0, result: .fixed)
expectEqual(silent(&policy, 40), .wait(.tooSoon, seconds: 30), "a minute between fixes")
policy = settled()
policy.fixStarted(now: at(0), automatic: true)
policy.fixCancelled("A")
expect(policy.fixTimes.isEmpty, "a cancelled fix is not counted")
policy = settled()
fixOnce(&policy, from: 0, result: .notAttempted)
expect(policy.fixTimes.isEmpty && policy.failedFixes.isEmpty, "a fix that switched nothing off counts neither towards the limit nor as a failure")

section("Auto-fix pauses after three fixes, and only real changes lift it")
policy = settled()
for start in [0.0, 70, 140] { fixOnce(&policy, from: start, result: .fixed) }
expectEqual(silent(&policy, 300), .blocked(.paused(justPaused: true)), "the fourth is refused and announced")
expectEqual(silent(&policy, 310), .blocked(.paused(justPaused: false)), "and announced only once")
policy.displaysMaySettle(now: at(320))
expectEqual(silent(&policy, 340), .blocked(.paused(justPaused: false)), "a wake does not lift the pause")
policy.topologyChanged(now: at(350))
expectEqual(silent(&policy, 370), .blocked(.paused(justPaused: false)), "a replug lifts the pause but the window still limits")
policy.userActed()
_ = silent(&policy, 400)
expectEqual(silent(&policy, 410), .fix, "a user action clears the history")

section("Auto-fix gives up after two failed automatic fixes until a replug")
policy = settled()
fixOnce(&policy, from: 0, result: .stillSilent)
fixOnce(&policy, from: 70, result: .stillSilent)
expectEqual(silent(&policy, 200), .blocked(.gaveUp), "left to the user")
policy.topologyChanged(now: at(210))
expect(silent(&policy, 230) != .blocked(.gaveUp), "a replug gives it another chance")
policy = settled()
fixOnce(&policy, from: 0, automatic: false, result: .stillSilent)
expect(policy.failedFixes["A"] == nil, "a manual fix that fails does not count towards giving up")
policy = settled()
fixOnce(&policy, from: 0, automatic: true, result: .stillSilent)
expectEqual(policy.failedFixes["A"], 1, "an automatic fix that fails counts, whatever path started it")

section("Auto-fix never touches an unfixable setup")
policy = settled()
expectEqual(silent(&policy, 0, blocker: "it is the only screen you can see"),
            .blocked(.cannotFix("it is the only screen you can see")), "the blocker is reported")
expect(policy.fixTimes.isEmpty, "and no attempt is recorded")

section("A TV that re-announces itself every 20 s for two hours cannot cause a fix loop")
policy = settled()
var fixTimes: [Double] = []
var announcements = 0
for tick in stride(from: 0.0, through: 7200, by: 5) {
    if tick.truncatingRemainder(dividingBy: 20) == 0 { policy.topologyChanged(now: at(tick)) }
    switch silent(&policy, tick) {
    case .fix:
        policy.fixStarted(now: at(tick), automatic: true)
        policy.fixFinished("A", result: .stillSilent)
        fixTimes.append(tick)
    case .blocked(.paused(justPaused: true)):
        announcements += 1
    default:
        break
    }
}
let gaps = zip(fixTimes, fixTimes.dropFirst()).map { $1 - $0 }
expect(!fixTimes.isEmpty, "it does try to fix")
expect(gaps.allSatisfy { $0 >= 60 }, "at least a minute between fixes (gaps: \(gaps.prefix(5)))")
let crowded = fixTimes.contains { start in fixTimes.filter { $0 >= start && $0 < start + 600 }.count > 3 }
expect(!crowded, "never more than three fixes in ten minutes")
expect(announcements <= Int(7200 / 600) + 1, "the pause is announced at most once per window (\(announcements))")

// MARK: Health and trust

section("Health threshold")
expect(isHealthy(callbacks: 90, advancedFrames: 47_000, sampleRate: 48_000, seconds: 1), "a full second of frames is healthy")
expect(isHealthy(callbacks: 4, advancedFrames: 15_000, sampleRate: 48_000, seconds: 1), "large buffers with few callbacks are healthy")
expect(!isHealthy(callbacks: 0, advancedFrames: 0, sampleRate: 48_000, seconds: 1), "no callbacks is stuck")
expect(!isHealthy(callbacks: 90, advancedFrames: 1_000, sampleRate: 48_000, seconds: 1), "callbacks without clock movement is stuck")

section("The built app is a trusted bundle for this version")
if let app = environment["LOUDSTATION_TEST_APP"] {
    expect(isTrustedAppBundle(URL(fileURLWithPath: app)), "build/LoudStation.app matches the identifier, version and owner (Info.plist and toolVersion agree)")
}
expect(!isTrustedAppBundle(URL(fileURLWithPath: stateDirectory)), "a folder that is not LoudStation is not trusted")

print("\nunit: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
