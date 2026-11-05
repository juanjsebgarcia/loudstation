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
expectEqual(silent(&policy, 0), .wait(.confirming, seconds: 0.5), "a first silent probe asks for a second at once")
expectEqual(silent(&policy, 4), .wait(.confirming, seconds: 6), "a second verdict too soon still waits out the gap")
expectEqual(silent(&policy, 10), .fix, "verdicts 10 s apart allow a fix")
policy = settled()
_ = silent(&policy, 0)
policy.observedWorking("A", isWatched: true)
expectEqual(silent(&policy, 11), .wait(.confirming, seconds: 0.5), "a working probe in between restarts confirmation")
expectEqual(silent(&policy, 12), .wait(.confirming, seconds: 9), "and the gap counts from the restart")

section("Two quick silent verdicts never shortcut the gap")
policy = settled()
var now = 0.0
var decision = silent(&policy, now)
while case .wait(.confirming, let seconds) = decision {
    now += seconds + 1
    decision = silent(&policy, now)
}
expectEqual(decision, .fix, "fixes in the end")
expect(now >= 10, "but only once the verdicts span the gap (\(now) s)")

section("A fresh silent verdict skips the final probe before a fix")
policy = settled()
expect(policy.needsFinalProbe("A", now: at(0)), "no verdict at all needs one")
_ = silent(&policy, 0)
_ = silent(&policy, 10)
expect(!policy.needsFinalProbe("A", now: at(11)), "a verdict a second old does not")
expect(policy.needsFinalProbe("A", now: at(40)), "a verdict from half a minute ago does")
expect(policy.needsFinalProbe("A", now: at(19)), "a verdict nine seconds old does: the app times it from its own probe, not the check's slowest")
policy.observedWorking("A", isWatched: true)
expect(policy.needsFinalProbe("A", now: at(11)), "a display last seen working needs one")
policy = settled()
_ = silent(&policy, 0)
policy.displaysMaySettle(now: at(5))
expectEqual(silent(&policy, 10), .wait(.confirming, seconds: 7), "a wake mid-confirmation waits for settling")

section("A burst of display events delays the first check by at most ten seconds")
expectEqual(eventCheckDelay(now: at(0), burstStarted: at(0), delay: 5, longest: 10), 5, "a lone event waits the short delay")
expectEqual(eventCheckDelay(now: at(3), burstStarted: at(0), delay: 5, longest: 10), 5, "an early follow-up restarts it")
expectEqual(eventCheckDelay(now: at(8), burstStarted: at(0), delay: 5, longest: 10), 2, "but not past the deadline")
expectEqual(eventCheckDelay(now: at(30), burstStarted: at(0), delay: 5, longest: 10), 0, "a burst that runs on checks at once")
// Events every 250 ms for 30 s, each replacing the pending check, as the app does.
var pendingCheck: Double? = nil
var firstCheck: Double? = nil
for event in stride(from: 0.0, to: 30, by: 0.25) {
    if let due = pendingCheck, due <= event {
        firstCheck = due
        break
    }
    pendingCheck = event + eventCheckDelay(now: at(event), burstStarted: at(0), delay: 5, longest: 10)
}
expect((firstCheck ?? pendingCheck ?? 99) <= 10.25, "a long burst of rapid events is checked by about 10 s (\(firstCheck ?? pendingCheck ?? 99) s)")

section("Only a screen arriving or leaving starts a check")
expect(isArrivalOrDeparture([.addFlag]), "an added display")
expect(isArrivalOrDeparture([.removeFlag]), "a removed display")
expect(isArrivalOrDeparture([.enabledFlag, .setModeFlag]), "an enabled display, whatever else changed")
expect(!isArrivalOrDeparture([.setModeFlag]), "not a mode change")
expect(!isArrivalOrDeparture([.movedFlag, .desktopShapeChangedFlag]), "not a rearrangement")
expect(!isArrivalOrDeparture([.setMainFlag]), "not a new main display")
expectEqual(describeDisplayEvent([.addFlag, .setModeFlag]), "added, mode", "events are logged in words")

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

section("A probe's start signal can be waited on more than once")
let startSignal = OneShotSignal()
expect(!startSignal.wait(seconds: 0.05), "an unfired signal times out")
startSignal.fire()
let waitStarted = Date()
expect(startSignal.wait(seconds: 5) && startSignal.wait(seconds: 5), "a fired signal satisfies every wait")
expect(Date().timeIntervalSince(waitStarted) < 1, "at once, not after the timeout")

section("Health threshold")
expect(isHealthy(callbacks: 90, advancedFrames: 47_000, sampleRate: 48_000, seconds: 1), "a full second of frames is healthy")
expect(isHealthy(callbacks: 4, advancedFrames: 15_000, sampleRate: 48_000, seconds: 1), "large buffers with few callbacks are healthy")
expect(!isHealthy(callbacks: 0, advancedFrames: 0, sampleRate: 48_000, seconds: 1), "no callbacks is stuck")
expect(!isHealthy(callbacks: 90, advancedFrames: 1_000, sampleRate: 48_000, seconds: 1), "callbacks without clock movement is stuck")

section("The kernel engine's counter overrules an estimated clock")
// The values seen on 2026-11-05: 12288-frame buffers at 48 kHz, so one pass every 0.256 s.
func engine(_ transfers: Int, running: Bool = true, entry: UInt64 = 7) -> EngineSample {
    EngineSample(entryID: entry, running: running, transfers: transfers, bufferSeconds: 0.256)
}
expectEqual(engineStalled(before: engine(1422), after: engine(1422), elapsed: 1), true, "running with no pass in a second is stalled")
expectEqual(engineStalled(before: engine(5591), after: engine(5595), elapsed: 1), false, "a counter that moves is not stalled")
expectEqual(engineStalled(before: engine(1422), after: engine(1422), elapsed: 0.7), nil, "under three passes' time proves nothing")
expectEqual(engineStalled(before: engine(3, running: false), after: engine(3, running: false), elapsed: 1), nil, "an idle engine proves nothing")
expectEqual(engineStalled(before: engine(3, running: false), after: engine(3), elapsed: 1), nil, "an engine that only just started proves nothing")
expectEqual(engineStalled(before: engine(1422), after: engine(1422, entry: 8), elapsed: 1), nil, "a different engine (a relink) proves nothing")
expectEqual(engineStalled(before: engine(1422), after: engine(2), elapsed: 1), nil, "a counter that went back proves nothing")
expectEqual(engineStalled(before: nil, after: engine(1422), elapsed: 1), nil, "no sample proves nothing")
expectEqual(engineStalled(before: EngineSample(entryID: 7, running: true, transfers: 1, bufferSeconds: 0), after: engine(1), elapsed: 5),
            nil, "an unknown buffer length proves nothing")

section("The built app is a trusted bundle for this version")
if let app = environment["LOUDSTATION_TEST_APP"] {
    expect(isTrustedAppBundle(URL(fileURLWithPath: app)), "build/LoudStation.app matches the identifier, version and owner (Info.plist and toolVersion agree)")
}
expect(!isTrustedAppBundle(URL(fileURLWithPath: stateDirectory)), "a folder that is not LoudStation is not trusted")

// MARK: Update check

section("Release versions")
expectEqual(ReleaseVersion("v0.3.0")?.description, "0.3.0", "a leading v is accepted")
expectEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"), "a missing patch number is zero")
expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!, "numbers compare numerically, not as text")
expect(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!, "the major number wins")
expect(!(ReleaseVersion("0.3.0")! > ReleaseVersion("0.3")!), "equal versions are not newer")
for bad in ["", "v", "0.3.0-beta", "0.3.0.1", "1..2", "x.y.z", "0.3.0 extra", "٣.٠.٠", "1234567890.0.0", "-1.0.0"] {
    expect(ReleaseVersion(bad) == nil, "\"\(bad)\" is not a release version")
}
expectEqual(ReleaseVersion(toolVersion)?.description, toolVersion, "this build's own version parses")

section("GitHub's latest-release answer")
func releaseJSON(_ fields: [String: Any]) -> Data {
    var object: [String: Any] = ["tag_name": "v9.0.0", "html_url": "https://github.com/\(projectRepository)/releases/tag/v9.0.0", "draft": false, "prerelease": false]
    fields.forEach { object[$0.key] = $0.value }
    return try! JSONSerialization.data(withJSONObject: object)
}
let latest = parseLatestRelease(releaseJSON([:]))
expectEqual(latest?.version.description, "9.0.0", "the tag becomes the version")
expectEqual(latest?.pageURL.absoluteString, "https://github.com/\(projectRepository)/releases/tag/v9.0.0", "the release page is kept")
expect(parseLatestRelease(releaseJSON(["draft": true])) == nil, "a draft is ignored")
expect(parseLatestRelease(releaseJSON(["prerelease": true])) == nil, "a pre-release is ignored")
expect(parseLatestRelease(releaseJSON(["tag_name": "nightly"])) == nil, "a tag that is not a version is ignored")
expect(parseLatestRelease(releaseJSON(["tag_name": 3])) == nil, "a tag of the wrong type is ignored")
for page in ["http://github.com/\(projectRepository)/releases/tag/v9.0.0", "https://evil.example/\(projectRepository)/releases/tag/v9.0.0",
             "https://github.com.evil.example/\(projectRepository)/releases/", "https://github.com/someone/else/releases/tag/v9.0.0",
             "https://user@github.com/\(projectRepository)/releases/tag/v9.0.0", "https://github.com:8443/\(projectRepository)/releases/tag/v9.0.0",
             "https://github.com/\(projectRepository)/releases/../../../someone/else", "https://github.com/\(projectRepository)/releases/%2e%2e/%2e%2e/x",
             "javascript:alert(1)"] {
    expect(parseLatestRelease(releaseJSON(["html_url": page])) == nil, "the page \(page) is refused")
}
expect(parseLatestRelease(Data("not json".utf8)) == nil, "a body that is not JSON is ignored")
expect(parseLatestRelease(Data("[1, 2]".utf8)) == nil, "JSON that is not an object is ignored")
expect(parseLatestRelease(Data("{\"message\": \"API rate limit exceeded\"}".utf8)) == nil, "an error answer is ignored")

section("Only a newer release is offered")
expect(newerRelease(latest, than: "0.3.0") != nil, "9.0.0 is offered to 0.3.0")
expect(newerRelease(latest, than: "9.0.0") == nil, "the same version is not offered")
expect(newerRelease(latest, than: "10.0.0") == nil, "an older release is not offered")
expect(newerRelease(nil, than: "0.3.0") == nil, "no release, no offer")
expect(newerRelease(latest, than: "garbage") == nil, "an unparseable current version offers nothing")

section("Homebrew or source install")
expect(isHomebrewInstall(bundlePath: "/opt/homebrew/Cellar/loudstation/0.3.0/libexec/LoudStation.app"), "Homebrew's Cellar on Apple Silicon")
expect(isHomebrewInstall(bundlePath: "/opt/homebrew/opt/loudstation/libexec/LoudStation.app"), "Homebrew's opt link")
expect(isHomebrewInstall(bundlePath: "/Users/me/homebrew/Cellar/loudstation/0.3.0/libexec/LoudStation.app"), "a Homebrew in the home folder")
expect(!isHomebrewInstall(bundlePath: "/Users/me/Applications/LoudStation.app"), "make install's ~/Applications copy")
expect(!isHomebrewInstall(bundlePath: "/opt/homebrew/Cellar/other/1.0/LoudStation.app"), "another formula's Cellar")

section("A newly opened copy takes over only from a stale one")
let launchedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
let builtBefore = launchedAt.addingTimeInterval(-3600)
let replacedAfter = launchedAt.addingTimeInterval(600)
expect(isStaleCopy(executableModified: replacedAfter, launched: launchedAt, diskVersion: "0.3.0", ownVersion: "0.3.0"),
       "Homebrew's opt link now shows the new version, but the running program was replaced after launch")
expect(isStaleCopy(executableModified: nil, launched: launchedAt, diskVersion: nil, ownVersion: "0.3.0"), "a copy whose program was removed is stale")
expect(isStaleCopy(executableModified: builtBefore, launched: launchedAt, diskVersion: "0.2.0", ownVersion: "0.3.0"), "an older version elsewhere is stale")
expect(!isStaleCopy(executableModified: builtBefore, launched: launchedAt, diskVersion: "0.3.0", ownVersion: "0.3.0"), "the same, untouched version is current")
expect(!isStaleCopy(executableModified: builtBefore, launched: launchedAt, diskVersion: "0.4.0", ownVersion: "0.3.0"), "a newer copy is current")
expect(!isStaleCopy(executableModified: builtBefore, launched: launchedAt, diskVersion: nil, ownVersion: "0.3.0"), "an unknown version is left alone")
expect(!isStaleCopy(executableModified: launchedAt.addingTimeInterval(0.5), launched: launchedAt, diskVersion: "0.3.0", ownVersion: "0.3.0"), "rounding of modification times is tolerated")
expect(isStaleCopy(executableModified: Date(), launched: processStartTime(getpid()).map { $0.addingTimeInterval(-60) }, diskVersion: toolVersion, ownVersion: toolVersion),
       "a login-item copy (no launch date from AppKit) whose program was replaced after it started is stale, using the kernel's start time")
if let started = processStartTime(getpid()) {
    expect(abs(started.timeIntervalSinceNow) < 600, "the kernel's start time of this process is recent")
} else {
    expect(false, "the kernel reports this process's start time")
}
expect(processStartTime(-1) == nil, "no start time for a process that does not exist")
expect(startedFirst((launchedAt, 900), before: (replacedAfter, 100)), "the earlier launch stays")
expect(startedFirst((launchedAt, 100), before: (launchedAt, 900)), "the same launch time falls back to the lower process ID")
expect(!startedFirst((nil, 900), before: (nil, 100)), "unknown launch times fall back to the process ID")

section("Update check schedule")
let schedule = UpdateSchedule()
let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
expect(schedule.isDue(lastChecked: nil, now: checkedAt), "never checked is due")
expect(!schedule.isDue(lastChecked: checkedAt, now: checkedAt.addingTimeInterval(23 * 3600)), "under a day later is not due")
expect(schedule.isDue(lastChecked: checkedAt, now: checkedAt.addingTimeInterval(24 * 3600)), "a day later is due")
expect(!schedule.isDue(lastChecked: checkedAt.addingTimeInterval(30 * 60), now: checkedAt), "a small clock difference is not due")
expect(schedule.isDue(lastChecked: checkedAt.addingTimeInterval(3 * 24 * 3600), now: checkedAt), "a last check in the future (clock set back) is due")

print("\nunit: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
