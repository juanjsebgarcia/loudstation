import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit
import os

// Shared core for LoudStation's CLI and menu bar app: revives display audio that Apple
// Silicon's DCP leaves dead after monitor hot-plug. See ../docs/ for the investigation
// behind every choice made here. Log lines (say) stay in English; anything shown to the
// user goes through L() in Localization.swift.

let toolVersion = "0.3.0"

// Homebrew runs code from a versioned Cellar path that disappears on upgrade; its stable
// equivalent is the opt symlink. Anything persisted (the login item) must use the latter.
func stablePath(_ path: String) -> String {
    let parts = path.components(separatedBy: "/")
    guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 2 < parts.count else { return path }
    let opt = (parts[..<cellar] + ["opt", parts[cellar + 1]] + parts[(cellar + 3)...]).joined(separator: "/")
    return FileManager.default.fileExists(atPath: opt) ? opt : path
}

// MARK: Logging

// Tests point the log and the state folder at a temporary folder through these variables, so
// they never touch a real installation's files.
private let processEnvironment = ProcessInfo.processInfo.environment

let logURL = processEnvironment["LOUDSTATION_LOG"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/loudstation.log")

private let logLock = NSLock()
private var writesSinceRotationCheck = Int.max
private let maximumLogBytes = 1_000_000
private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
// Log timestamps are fixed-format whatever the user's locale, calendar or 12/24-hour setting.
private let logTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}()
private let audioUIDPattern = try! NSRegularExpression(pattern: "\\b([0-9A-F]{8})-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{12})\\b")

// Logs get attached to public bug reports, so the home folder becomes ~ and a display audio
// UID's EDID serial group becomes a short stable hash (vendor, model and week stay readable).
func redactedForLog(_ text: String) -> String {
    var result = text.replacingOccurrences(of: homePath + "/", with: "~/")
    if result == homePath { result = "~" }
    let matches = audioUIDPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
    for match in matches.reversed() {
        guard let serialRange = Range(match.range(at: 2), in: result), let serialEnd = Range(match.range(at: 3), in: result) else { continue }
        let serial = String(result[serialRange]) + String(result[serialEnd])
        guard serial != "00000000" else { continue }
        let hash = serial.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        result.replaceSubrange(serialRange.lowerBound..<serialEnd.upperBound, with: String(format: "#%04X-#%03X", hash & 0xFFFF, (hash >> 16) & 0xFFF))
    }
    return result
}

// Appends with O_APPEND so the CLI and the app can log at once without interleaving partial
// lines, never follows a symlink, and rotates to `.log.1` once the file passes about 1 MB.
func say(_ message: String, echo: Bool = true) {
    if echo {
        print(message)
        fflush(stdout)
    }
    logLock.lock()
    defer { logLock.unlock() }
    let line = "[\(logTimestamp.string(from: Date()))] \(redactedForLog(message))\n"
    if writesSinceRotationCheck >= 200 {
        writesSinceRotationCheck = 0
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if size > maximumLogBytes {
            let rotated = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: logURL, to: rotated)
        }
    }
    writesSinceRotationCheck += 1
    let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = line.withCString { write(fd, $0, strlen($0)) }
}

// LoudStation must never run as root: everything it writes belongs in the user's own folders.
let runningAsRoot = geteuid() == 0

// MARK: CoreAudio helpers

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalarProperty<T: FixedWidthInteger>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    fallback: T
) -> T {
    var addr = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = fallback
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : fallback
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var ref: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref)
    guard status == noErr, let ref else { return nil }
    return ref.takeRetainedValue() as String
}

func audioDevices() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

func outputStreamCount(_ device: AudioObjectID) -> Int {
    streamCount(device, scope: kAudioObjectPropertyScopeOutput)
}

func uid(of device: AudioObjectID) -> String? {
    stringProperty(device, kAudioDevicePropertyDeviceUID)
}

func name(of device: AudioObjectID) -> String {
    stringProperty(device, kAudioObjectPropertyName) ?? "?"
}

func device(withUID wanted: String) -> AudioObjectID? {
    audioDevices().first { uid(of: $0) == wanted }
}

// True while any app is capturing from a microphone, which is a good sign of a call. On
// macOS 14 and later this asks which processes are actually running input, so a USB headset
// that is only playing sound does not count; earlier releases fall back to device state.
func microphoneInUse() -> Bool {
    if #available(macOS 14.0, *) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
            var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &processes) == noErr {
                return processes.contains { scalarProperty($0, kAudioProcessPropertyIsRunningInput, fallback: UInt32(0)) != 0 }
            }
        }
    }
    return audioDevices().contains { dev in
        streamCount(dev, scope: kAudioObjectPropertyScopeInput) > 0
            && scalarProperty(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, fallback: UInt32(0)) != 0
    }
}

// The UIDs of the kernel's display-audio engines (DCPAVAudioDriver). Their "is running"
// flag reads true while a client is merely trying, so it is never used alone as a health signal.
func displayAudioEngineUIDs() -> Set<String> {
    var result = Set<String>()
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVAudioDriver"), &iterator) == KERN_SUCCESS else {
        return result
    }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        if let engineUID = IORegistryEntryCreateCFProperty(service, "device UID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            result.insert(engineUID)
        }
    }
    return result
}

// What the kernel's display-audio engine reports, whatever an app holding the device open sees.
// TransferCount rises once per pass through the engine's ring buffer, so it moves only while
// the hardware really plays. An app keeping a dead device open (Spotify, on 2026-11-05) gets an
// estimated clock from Core Audio, and so would a probe joining it; this cannot be fooled.
struct EngineSample: Equatable {
    let entryID: UInt64
    let running: Bool
    let transfers: Int
    // How long one pass through the ring buffer takes.
    let bufferSeconds: Double
}

// The engine with this UID, or nil when there is none, it lacks the counters, or two engines
// share the UID (identical monitors), since a sample of the wrong one must never decide anything.
func engineSample(uid wanted: String) -> EngineSample? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVAudioDriver"), &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }
    var found: [EngineSample?] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        let property = { (key: String) in
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard property("device UID") as? String == wanted else { continue }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
              let running = property("is running") as? Bool,
              let transfers = (property("TransferCount") as? NSNumber)?.intValue,
              let frames = (property("io buffer frame size") as? NSNumber)?.doubleValue,
              let fixedRate = (property("sample rate") as? NSNumber)?.doubleValue else {
            found.append(nil)
            continue
        }
        // The kernel stores the sample rate as 32.32 fixed point.
        let rate = fixedRate / 4_294_967_296
        let bufferSeconds = frames > 0 && rate > 0 ? frames / rate : 0
        found.append(EngineSample(entryID: entryID, running: running, transfers: transfers, bufferSeconds: bufferSeconds))
    }
    return found.count == 1 ? found[0] : nil
}

// Whether the engine stalled across a probe window. True only when the same engine was running
// at both ends and did not finish a single pass through its buffer in at least three passes'
// time; false when it moved; nil when there is no evidence either way (no engine, a restart in
// between, too short a window), which leaves the verdict to the probe's own callbacks.
func engineStalled(before: EngineSample?, after: EngineSample?, elapsed: Double) -> Bool? {
    guard let before, let after, before.entryID == after.entryID, before.running, after.running,
          before.bufferSeconds > 0, after.transfers >= before.transfers else { return nil }
    if after.transfers > before.transfers { return false }
    return elapsed >= 3 * before.bufferSeconds ? true : nil
}

// MARK: Probing

final class CallbackTally: @unchecked Sendable {
    private struct State {
        var count = 0
        var lastSample: Float64 = -1
        var advancedFrames: Float64 = 0
    }

    // An unfair lock, not NSLock, because record() runs on the real-time IO thread.
    private let state = OSAllocatedUnfairLock(initialState: State())

    // Only forward movement counts, so a sample-time reset mid-probe (a sample-rate change, an
    // IO restart) neither hides a healthy clock nor fakes one.
    func record(_ sample: Float64) {
        state.withLock {
            if $0.lastSample >= 0, sample > $0.lastSample { $0.advancedFrames += sample - $0.lastSample }
            $0.lastSample = sample
            $0.count += 1
        }
    }

    func snapshot() -> (count: Int, advanced: Float64) {
        state.withLock { ($0.count, $0.advancedFrames) }
    }
}

// Hand-over between a probe and the thread blocked in AudioDeviceStart. Whichever finishes
// last stops and destroys the IOProc, so a late start never runs against a destroyed IOProc,
// and a start that returns after the probe gave up is still cleaned up instead of playing
// silence for ever.
final class StartHandoff: @unchecked Sendable {
    private struct State {
        var status: OSStatus?
        var abandoned = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // Called by the start thread; true means the probe has given up and the start thread cleans up.
    func finished(_ status: OSStatus) -> Bool {
        state.withLock {
            $0.status = status
            return $0.abandoned
        }
    }

    // Called by the probe; the start's status if it has returned, otherwise it is marked abandoned.
    func abandonUnlessFinished() -> OSStatus? {
        state.withLock {
            if $0.status == nil { $0.abandoned = true }
            return $0.status
        }
    }
}

// A one-shot signal that stays raised: once fired, every wait returns at once. A semaphore is
// used up by the first wait, which made every probe of a working display sit out a second,
// 15 s wait for a signal that had already come (2026-11-05).
final class OneShotSignal: @unchecked Sendable {
    private let group = DispatchGroup()

    init() { group.enter() }

    // Call exactly once.
    func fire() { group.leave() }

    @discardableResult
    func wait(seconds: Double) -> Bool { group.wait(timeout: .now() + seconds) == .success }
}

// Devices with a start still blocked. Probing one again would only pile up threads, so it is
// reported as still stuck until that start returns.
private let startsInFlight = OSAllocatedUnfairLock(initialState: Set<AudioObjectID>())

let minimumProbeSeconds = 0.5

// The status a stuck DCP device's AudioDeviceStart returns after ~10s: kAudioHardwareNotRunningError.
private let notRunningStatus: OSStatus = 1_937_010_544

private func nominalSampleRate(_ dev: AudioObjectID) -> Float64 {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var size = UInt32(MemoryLayout<Float64>.size)
    var rate: Float64 = 0
    let status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
    return status == noErr && rate > 0 ? rate : 48_000
}

private func hoggedByAnotherProcess(_ dev: AudioObjectID) -> Bool {
    let owner = scalarProperty(dev, kAudioDevicePropertyHogMode, fallback: pid_t(-1))
    return owner != -1 && owner != getpid()
}

// Healthy means the clock moved forward by a fair share of the frames the device should have
// played, which holds whatever buffer size or sample rate it runs at.
func isHealthy(callbacks: Int, advancedFrames: Double, sampleRate: Double, seconds: Double) -> Bool {
    callbacks >= 3 && advancedFrames >= sampleRate * seconds * 0.3
}

// Plays silence to the device and checks whether its clock actually ticks.
// Returns true when healthy, false when stuck, nil when the probe could not run or the device
// failed for some other reason (unplugged, hogged), which must never trigger a repair.
func probe(_ dev: AudioObjectID, seconds requested: Double, log: Bool = true) -> Bool? {
    let seconds = max(minimumProbeSeconds, requested)
    let devName = name(of: dev)
    if hoggedByAnotherProcess(dev) {
        say("Could not check '\(devName)': another app has exclusive use of it.", echo: log)
        return nil
    }
    guard startsInFlight.withLock({ $0.insert(dev).inserted }) else {
        say("'\(devName)' is still stuck from an earlier check.", echo: log)
        return false
    }
    let release = { _ = startsInFlight.withLock { $0.remove(dev) } }
    if log { say("Probing '\(devName)' (\(uid(of: dev) ?? "?")) with \(seconds)s of silence...") }
    let tally = CallbackTally()
    var procID: AudioDeviceIOProcID?
    let created = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, _, _, outData, outTime in
        for buffer in UnsafeMutableAudioBufferListPointer(outData) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        tally.record(outTime.pointee.mSampleTime)
    }
    guard created == noErr, let procID else {
        release()
        say("Could not create an IOProc on '\(devName)' (OSStatus \(created)).", echo: log)
        return nil
    }

    let handoff = StartHandoff()
    let returned = OneShotSignal()
    // A dedicated thread rather than the shared pool: a start that never returns must not starve GCD.
    let starter = Thread {
        let status = AudioDeviceStart(dev, procID)
        if handoff.finished(status) {
            AudioDeviceStop(dev, procID)
            AudioDeviceDestroyIOProcID(dev, procID)
            release()
            say("A late start on '\(devName)' returned; its IOProc is cleaned up.", echo: false)
        }
        returned.fire()
    }
    starter.name = "LoudStation probe"
    starter.start()

    // The window starts once AudioDeviceStart returns (a slow TV or receiver needs a moment), but
    // no later than 2 s in, since a stuck device's start blocks for about 10 s.
    returned.wait(seconds: 2)
    let engineUID = uid(of: dev)
    let engineBefore = engineUID.flatMap { engineSample(uid: $0) }
    let windowStart = Date()
    Thread.sleep(forTimeInterval: seconds)
    let result = tally.snapshot()
    let stalled = engineStalled(before: engineBefore, after: engineUID.flatMap { engineSample(uid: $0) },
                                elapsed: Date().timeIntervalSince(windowStart))
    // A stuck device's start returns 'stop' after about 10 s; wait for it before tearing down.
    returned.wait(seconds: 15)
    guard let startStatus = handoff.abandonUnlessFinished() else {
        say("AudioDeviceStart on '\(devName)' has not returned after 15s; it will be cleaned up when it does.", echo: log)
        return false
    }
    AudioDeviceStop(dev, procID)
    AudioDeviceDestroyIOProcID(dev, procID)
    release()

    if startStatus != noErr && startStatus != notRunningStatus {
        say("Could not check '\(devName)': AudioDeviceStart returned OSStatus \(startStatus).", echo: log)
        return nil
    }
    let expected = nominalSampleRate(dev) * seconds
    let clockMoved = isHealthy(callbacks: result.count, advancedFrames: result.advanced, sampleRate: nominalSampleRate(dev), seconds: seconds)
    // Core Audio's clock can be an estimate; the kernel engine's own counter has the last word.
    let healthy = clockMoved && stalled != true
    if clockMoved && !healthy {
        say("'\(devName)' looks open and playing, but its audio engine has not moved; another app is probably holding a dead device open.", echo: log)
    }
    if log { say("\(healthy ? "HEALTHY" : "STUCK"): \(result.count) IO callbacks, clock advanced \(Int(result.advanced)) of about \(Int(expected)) frames.") }
    return healthy
}

// MARK: Displays

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

struct PanelIdentity {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32?
}

enum PanelLookup {
    case found(PanelIdentity)
    case ambiguous
    case notFound
}

// Every external panel the DCP drives: its AppleCLCD2 framebuffer carries IOMFBUUID, which
// equals the CoreAudio UID of that panel's DCP audio device, alongside the EDID
// ProductAttributes, whose serial matches CGDisplaySerialNumber.
func externalPanels() -> [(uid: String, identity: PanelIdentity)] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var panels: [(uid: String, identity: PanelIdentity)] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        guard let panelUID = IORegistryEntryCreateCFProperty(service, "IOMFBUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
              let model = (product["ProductID"] as? NSNumber)?.uint32Value else { continue }
        let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value
        panels.append((panelUID, PanelIdentity(vendor: vendor, model: model, serial: serial)))
    }
    return panels
}

// Two identical monitors from the same production week can share an IOMFBUUID, so more than
// one match is reported as ambiguous, never guessed.
func panelLookup(forAudioUID audioUID: String) -> PanelLookup {
    let matches = externalPanels().filter { $0.uid == audioUID }
    if matches.count > 1 { return .ambiguous }
    return matches.first.map { .found($0.identity) } ?? .notFound
}

func matches(_ display: CGDirectDisplayID, _ identity: PanelIdentity) -> Bool {
    CGDisplayVendorNumber(display) == identity.vendor && CGDisplayModelNumber(display) == identity.model
        && (identity.serial.map { CGDisplaySerialNumber(display) == $0 } ?? true)
}

// Active screens a person can actually see: the built-in panel and externals the DCP drives.
// Sidecar, AirPlay, virtual and DisplayLink screens are left out, so the only-screen guard
// never counts a screen that is not really there.
func physicalActiveDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let panels = externalPanels().map(\.identity)
    return ids.prefix(Int(count)).filter { display in
        CGDisplayIsBuiltin(display) != 0 || panels.contains { matches(display, $0) }
    }
}

// Why a display must not be switched off, or nil when it may be.
func cycleBlocker(_ display: CGDirectDisplayID) -> String? {
    if CGDisplayIsInMirrorSet(display) != 0 { return "it is part of a mirrored set" }
    if !physicalActiveDisplays().contains(where: { $0 != display }) { return "it is the only screen you can see" }
    if configureDisplayEnabled == nil { return "SkyLight's ConfigureDisplayEnabled is not available on this macOS" }
    return nil
}

// Fallback when the registry has no matching panel: a DCP audio UID starts with the EDID
// vendor, then the product code byte-swapped (product 0x413C appears as "3C41").
func identityFromUID(_ audioUID: String) -> PanelIdentity? {
    let chars = Array(audioUID)
    guard chars.count >= 8,
          let vendor = UInt32(String(chars[0..<4]), radix: 16),
          let swapped = UInt32(String(chars[4..<8]), radix: 16) else { return nil }
    return PanelIdentity(vendor: vendor, model: ((swapped & 0xFF) << 8) | (swapped >> 8), serial: nil)
}

private let ambiguousLogged = OSAllocatedUnfairLock(initialState: Set<String>())

func display(forAudioUID audioUID: String) -> CGDirectDisplayID? {
    let identity: PanelIdentity
    switch panelLookup(forAudioUID: audioUID) {
    case .found(let found):
        identity = found
    case .ambiguous:
        if ambiguousLogged.withLock({ $0.insert(audioUID).inserted }) {
            say("Two monitors report the same audio ID \(audioUID); refusing to guess which to cycle.")
        }
        return nil
    case .notFound:
        guard let parsed = identityFromUID(audioUID) else { return nil }
        identity = parsed
    }
    var matches = onlineDisplays().filter { CGDisplayVendorNumber($0) == identity.vendor && CGDisplayModelNumber($0) == identity.model }
    if matches.count > 1, let serial = identity.serial {
        matches = matches.filter { CGDisplaySerialNumber($0) == serial }
    }
    if matches.count > 1 {
        say("Several displays match vendor/model \(String(format: "%04X/%04X", identity.vendor, identity.model)); refusing to guess which to cycle.")
        return nil
    }
    return matches.first
}

func describe(_ display: CGDirectDisplayID) -> String {
    let mode = CGDisplayCopyDisplayMode(display)
    let ids = String(format: "vendor=0x%04X model=0x%04X", CGDisplayVendorNumber(display), CGDisplayModelNumber(display))
    let size = "\(mode?.width ?? 0)x\(mode?.height ?? 0)@\(Int(mode?.refreshRate ?? 0))Hz"
    let main = CGDisplayIsMain(display) != 0 ? " main" : ""
    return "display id=\(display) \(ids) \(size) rotation=\(Int(CGDisplayRotation(display)))\(main)"
}

// True when an ordinary app window exactly covers the display: a full-screen video, game or
// presentation. Window bounds and layers are readable without Screen Recording permission.
func fullScreenWindowCovers(_ display: CGDirectDisplayID) -> Bool {
    let bounds = CGDisplayBounds(display)
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    // Ordinary windows (layer 0), plus shielding-level windows that games and presenters use
    // when they capture a display.
    let shielding = Int(CGShieldingWindowLevel())
    return windows.contains { window in
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 || layer >= shielding,
              let frame = window[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: frame as CFDictionary) else { return false }
        return rect.integral == bounds.integral
    }
}

// MARK: Cycling

typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

// Private SkyLight call, the same one display utilities use to switch a screen off in software,
// resolved once from the signed system volume. A mode switch does not work: it never tears
// down the audio link (see docs/discoveries). On Apple Silicon it does a real disconnect from
// macOS 13, the app's minimum.
let configureDisplayEnabled: ConfigureDisplayEnabled? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
    for symbolName in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
        if let symbol = dlsym(handle, symbolName) {
            return unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
        }
    }
    return nil
}()

// Display configuration is done on the main thread, wherever the caller is running.
func onMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}

func setEnabled(_ display: CGDirectDisplayID, _ enabled: Bool, using fn: ConfigureDisplayEnabled) -> CGError {
    onMain { configure(display, enabled, using: fn) }
}

private func configure(_ display: CGDirectDisplayID, _ enabled: Bool, using fn: ConfigureDisplayEnabled) -> CGError {
    var config: CGDisplayConfigRef?
    var err = CGBeginDisplayConfiguration(&config)
    guard err == .success, let config else { return err }
    err = fn(config, display, enabled)
    guard err == .success else {
        CGCancelDisplayConfiguration(config)
        return err
    }
    return CGCompleteDisplayConfiguration(config, .forSession)
}

// A switched-off display stays off until logout, even if the process that switched it off dies.
// So the display is recorded (with the owning process, the boot session and the panel's
// identity) before it goes off and cleared once it is back on, and both front ends switch back
// on anything left recorded by a process that is gone.
let stateFolderURL = processEnvironment["LOUDSTATION_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LoudStation")
let strandedMarkerURL = stateFolderURL.appendingPathComponent("switched-off-display.plist")
private let cycleLockURL = stateFolderURL.appendingPathComponent("cycle.lock")

struct StrandedRecord {
    let display: CGDirectDisplayID
    let pid: pid_t
    let since: Date
    let boot: Int
    let identity: PanelIdentity
}

func bootTime() -> Int {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    return sysctl(&mib, 2, &boot, &size, nil, 0) == 0 ? boot.tv_sec : 0
}

private func recordSwitchedOff(_ display: CGDirectDisplayID) -> Bool {
    let record: [String: Any] = [
        "display": Int(display), "pid": Int(getpid()), "since": Date(), "boot": bootTime(),
        "vendor": Int(CGDisplayVendorNumber(display)), "model": Int(CGDisplayModelNumber(display)),
        "serial": Int(CGDisplaySerialNumber(display)),
    ]
    do {
        try FileManager.default.createDirectory(at: stateFolderURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
        try data.write(to: strandedMarkerURL, options: .atomic)
        return true
    } catch {
        say("Could not record the display before switching it off (\(error.localizedDescription)); not switching it off.")
        return false
    }
}

private func clearSwitchedOff() {
    try? FileManager.default.removeItem(at: strandedMarkerURL)
}

// Parses defensively: a corrupt or hand-edited record is discarded, never trusted.
func strandedRecord() -> StrandedRecord? {
    guard let data = try? Data(contentsOf: strandedMarkerURL) else { return nil }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let display = (plist["display"] as? Int).flatMap(CGDirectDisplayID.init(exactly:)),
          let pid = (plist["pid"] as? Int).flatMap(pid_t.init(exactly:)),
          let since = plist["since"] as? Date, let boot = plist["boot"] as? Int,
          let vendor = (plist["vendor"] as? Int).flatMap(UInt32.init(exactly:)),
          let model = (plist["model"] as? Int).flatMap(UInt32.init(exactly:)) else {
        say("Discarding an unreadable switched-off-display record.", echo: false)
        clearSwitchedOff()
        return nil
    }
    let serial = (plist["serial"] as? Int).flatMap(UInt32.init(exactly:))
    return StrandedRecord(display: display, pid: pid, since: since, boot: boot, identity: PanelIdentity(vendor: vendor, model: model, serial: serial))
}

func strandedDisplay() -> CGDirectDisplayID? {
    strandedRecord()?.display
}

private func processAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

// Returns true when nothing is stranded, or the stranded display was switched back on.
@discardableResult
func recoverStrandedDisplay() -> Bool {
    guard let record = strandedRecord() else { return true }
    // A different boot means logout or restart already reverted the session's configuration.
    if record.boot != bootTime() {
        clearSwitchedOff()
        return true
    }
    // Another live process is in the middle of its own cycle; leave it alone unless it has
    // overrun by a wide margin.
    if record.pid != getpid(), processAlive(record.pid), Date().timeIntervalSince(record.since) < holdRange.upperBound + 30 {
        return true
    }
    // The display ID may have been reused; find the panel by identity, preferring the recorded ID.
    guard let fn = configureDisplayEnabled else { return false }
    let candidates = onlineDisplays().filter { matches($0, record.identity) }
    guard let display = candidates.first(where: { $0 == record.display }) ?? candidates.first else {
        // A switched-off display may not be listed at all; try the recorded ID once before
        // concluding it was unplugged.
        if setEnabled(record.display, true, using: fn) == .success {
            say("Switched display id=\(record.display) back on; an earlier fix had left it off.")
        }
        clearSwitchedOff()
        return true
    }
    let err = setEnabled(display, true, using: fn)
    if err == .success {
        say("Switched display id=\(display) back on; an earlier fix had left it off.")
        clearSwitchedOff()
        return true
    }
    say("Could not switch display id=\(display) back on yet (CGError \(err.rawValue)).")
    return false
}

let holdRange = 0.5...30.0
let settleRange = 0.0...60.0

// Only one LoudStation process switches a display at a time: two at once would recreate the
// very collision that breaks display audio.
private func withCycleLock(_ body: () -> Bool) -> Bool {
    try? FileManager.default.createDirectory(at: stateFolderURL, withIntermediateDirectories: true)
    let fd = open(cycleLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
        say("Could not open the cycle lock; not switching a display off.")
        return false
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        say("Another LoudStation process is switching a display; not switching another.")
        return false
    }
    defer { flock(fd, LOCK_UN) }
    return body()
}

private let shieldedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP]

enum CycleResult {
    // Switched off and back on.
    case done
    // Nothing was switched off: a guard, the lock, an earlier stranded display, or no record.
    case refused
    // Switched off, but switching it back on has not worked yet.
    case stranded
}

// Switches one display off and on, which makes the DCP rebuild its whole link, HDCP and audio
// included. Interrupts, hang-ups and suspends are ignored meanwhile, so a screen cannot be
// stranded switched off by closing a terminal or pressing Ctrl-C or Ctrl-Z. Everything is
// decided inside the cross-process lock, so another process cannot change the picture between
// the checks and the switch.
func cycle(_ display: CGDirectDisplayID, hold requested: Double) -> CycleResult {
    let hold = min(max(requested, holdRange.lowerBound), holdRange.upperBound)
    var result = CycleResult.refused
    _ = withCycleLock {
        // A display an earlier fix left off must come back first, or its record would be lost.
        guard recoverStrandedDisplay(), strandedRecord() == nil else {
            say("A display an earlier fix switched off is still off; not switching another.")
            return false
        }
        if let blocker = cycleBlocker(display) {
            say("Not switching \(describe(display)) off: \(blocker).")
            return false
        }
        guard let fn = configureDisplayEnabled else { return false }
        say("Cycling \(describe(display)) off for \(hold)s, then on.")
        shieldedSignals.forEach { signal($0, SIG_IGN) }
        defer { shieldedSignals.forEach { signal($0, SIG_DFL) } }
        guard recordSwitchedOff(display) else { return false }
        let off = setEnabled(display, false, using: fn)
        guard off == .success else {
            clearSwitchedOff()
            say("Switching off failed: CGError \(off.rawValue).")
            return false
        }
        Thread.sleep(forTimeInterval: hold)
        for attempt in 1...5 {
            if setEnabled(display, true, using: fn) == .success {
                clearSwitchedOff()
                result = .done
                return true
            }
            say("Switching back on, attempt \(attempt), failed.")
            Thread.sleep(forTimeInterval: 1)
        }
        say("Could not switch the display back on yet; will keep trying. Unplugging and replugging its cable also works.")
        result = .stranded
        return false
    }
    return result
}

// MARK: Outputs

func defaultOutputDevice() -> AudioObjectID? {
    let dev = scalarProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, fallback: AudioObjectID(0))
    return dev == 0 ? nil : dev
}

// Makes `dev` the Mac's sound output, as choosing it in System Settings > Sound would.
@discardableResult
func setDefaultOutputDevice(_ dev: AudioObjectID) -> Bool {
    setOutput(kAudioHardwarePropertyDefaultOutputDevice, dev)
}

@discardableResult
func setSystemSoundsOutputDevice(_ dev: AudioObjectID) -> Bool {
    setOutput(kAudioHardwarePropertyDefaultSystemOutputDevice, dev)
}

private func setOutput(_ selector: AudioObjectPropertySelector, _ dev: AudioObjectID) -> Bool {
    var addr = address(selector)
    var value = dev
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &value) == noErr
}

func systemSoundsOutputDevice() -> AudioObjectID? {
    let dev = scalarProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, fallback: AudioObjectID(0))
    return dev == 0 ? nil : dev
}

func transportName(of device: AudioObjectID) -> String {
    switch scalarProperty(device, kAudioDevicePropertyTransportType, fallback: UInt32(0)) {
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    default: return "display"
    }
}

struct DisplayAudioOutput {
    let device: AudioObjectID
    let uid: String
    let name: String
    let transport: String
}

// Every DCP display-audio output currently present, in a stable order, one per UID.
func displayAudioOutputs() -> [DisplayAudioOutput] {
    let engines = displayAudioEngineUIDs()
    var seen = Set<String>()
    return audioDevices().compactMap { dev -> DisplayAudioOutput? in
        guard let devUID = uid(of: dev), engines.contains(devUID), seen.insert(devUID).inserted else { return nil }
        return DisplayAudioOutput(device: dev, uid: devUID, name: name(of: dev), transport: transportName(of: dev))
    }.sorted { $0.uid < $1.uid }
}

func isDisplayAudio(_ dev: AudioObjectID) -> Bool {
    guard let devUID = uid(of: dev) else { return false }
    return displayAudioEngineUIDs().contains(devUID)
}

// MARK: Repair

enum RepairStatus {
    case fixed
    case stillStuck
    case noDisplay
    // Nothing was switched off (a guard, the lock, or an earlier stranded display).
    case notAttempted
    // Switched off, but it has not come back on yet.
    case cycleFailed

    // The CLI's exit code: 0 fixed, 1 still silent, 2 no such display, 3 not switched or failed.
    var exitCode: Int32 {
        switch self {
        case .fixed: return 0
        case .stillStuck: return 1
        case .noDisplay: return 2
        case .notAttempted, .cycleFailed: return 3
        }
    }
}

// `message` is localised for the user; the log gets its own English lines.
struct RepairOutcome {
    let status: RepairStatus
    let message: String
    let collateral: [String]
}

// Cycles the display behind `dev`, re-probes it, then probes every other display-audio
// output and reports, without touching, any that the cycle knocked out.
// `othersToCheck` limits the check for collateral damage to these displays (those working
// before the fix, since a silent one cannot be knocked out); nil checks every other display.
func repair(_ dev: AudioObjectID, probeSeconds: Double, hold: Double, settle requested: Double,
            othersToCheck: Set<String>? = nil) -> RepairOutcome {
    let settle = min(max(requested, settleRange.lowerBound), settleRange.upperBound)
    let devName = name(of: dev)
    guard let devUID = uid(of: dev), let display = display(forAudioUID: devUID) else {
        say("Could not tell which screen '\(devName)' is, so did not switch anything off.", echo: false)
        return RepairOutcome(status: .noDisplay, message: L("outcome.unknown_display", devName), collateral: [])
    }
    // While a display is off, macOS may move the sound output elsewhere and not move it back.
    let soundBefore = defaultOutputDevice().flatMap(uid(of:))
    let systemBefore = systemSoundsOutputDevice().flatMap(uid(of:))
    switch cycle(display, hold: hold) {
    case .done:
        break
    case .refused:
        say("Did not switch '\(devName)' off.", echo: false)
        return RepairOutcome(status: .notAttempted, message: L("outcome.cycle_failed", devName), collateral: [])
    case .stranded:
        say("Switching '\(devName)' off and on did not complete.", echo: false)
        return RepairOutcome(status: .cycleFailed, message: L("outcome.cycle_failed", devName), collateral: [])
    }
    Thread.sleep(forTimeInterval: settle)
    if let soundBefore, defaultOutputDevice().flatMap(uid(of:)) != soundBefore, let dev = device(withUID: soundBefore) {
        say("The sound output moved during the cycle; switching it back.", echo: false)
        setDefaultOutputDevice(dev)
    }
    if let systemBefore, systemSoundsOutputDevice().flatMap(uid(of:)) != systemBefore, let dev = device(withUID: systemBefore) {
        setSystemSoundsOutputDevice(dev)
    }
    // The cycle may renumber audio devices, so this one is looked up afresh. It and the other
    // displays are checked at once, since each silent one blocks for about 10 seconds.
    let others = displayAudioOutputs().filter { $0.uid != devUID && othersToCheck?.contains($0.uid) != false }
    let targets = [device(withUID: devUID)] + others.map { Optional($0.device) }
    var results = [Bool?](repeating: nil, count: targets.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: targets.count) { index in
        let result = targets[index].flatMap { probe($0, seconds: probeSeconds) }
        lock.lock()
        results[index] = result
        lock.unlock()
    }
    let after = results[0]
    let silent = results.dropFirst().map { $0 == false }
    var collateral: [String] = []
    for (index, other) in others.enumerated() where silent[index] {
        collateral.append(other.name)
        say("WARNING: '\(other.name)' (\(other.uid)) has no sound after the cycle. Not touching it; run `\(commandName) fix --uid \(other.uid)` if you need it.")
    }
    switch after {
    case true?:
        say("Fixed '\(devName)'.", echo: false)
        return RepairOutcome(status: .fixed, message: L("outcome.fixed", devName), collateral: collateral)
    case false?:
        say("'\(devName)' still has no sound after cycling.", echo: false)
        return RepairOutcome(status: .stillStuck, message: L("outcome.still_silent", devName), collateral: collateral)
    case nil:
        say("Cycled '\(devName)' but could not check it afterwards.", echo: false)
        return RepairOutcome(status: .stillStuck, message: L("outcome.unverified", devName), collateral: collateral)
    }
}
