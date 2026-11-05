import CoreGraphics
import Foundation

// When LoudStation may fix the monitor speakers' display automatically. Pure logic with an
// injected clock, so Tests/Unit can drive it through scenarios (a TV that keeps re-announcing
// itself, a wake during a fix, a single glitch) without hardware or real time. The app owns one
// instance and feeds it events; deferral for calls and full screen stays in the app, because it
// needs live system state.
// How long to wait before checking after a display event. Each event restarts a short wait, so a
// burst of events leads to one check, but never later than `longest` after the burst's first
// event: macOS can keep announcing changes for a minute after a replug (2026-11-05).
func eventCheckDelay(now: Date, burstStarted: Date, delay: Double, longest: Double) -> Double {
    let untilDeadline = burstStarted.addingTimeInterval(longest).timeIntervalSince(now)
    // Past the deadline the check is due at once: any floor here would let events arriving
    // faster than it put the check off for as long as they kept coming.
    return max(0, min(delay, untilDeadline))
}

// Whether a display event means a screen arrived or left, as opposed to a mode, position or
// main-screen change of one already there. Only arrivals and departures start a check; the rest
// only hold off fixing while macOS rearranges.
func isArrivalOrDeparture(_ flags: CGDisplayChangeSummaryFlags) -> Bool {
    !flags.isDisjoint(with: [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag])
}

// The flags of a display event in words, for the log.
func describeDisplayEvent(_ flags: CGDisplayChangeSummaryFlags) -> String {
    let names: [(CGDisplayChangeSummaryFlags, String)] = [
        (.addFlag, "added"), (.removeFlag, "removed"), (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
        (.mirrorFlag, "mirrored"), (.unMirrorFlag, "unmirrored"), (.setModeFlag, "mode"), (.movedFlag, "moved"),
        (.setMainFlag, "main"), (.desktopShapeChangedFlag, "desktop shape"),
    ]
    let present = names.filter { flags.contains($0.0) }.map { $0.1 }
    return present.isEmpty ? "flags \(flags.rawValue)" : present.joined(separator: ", ")
}

struct AutoFixPolicy {
    struct Timing {
        var settleAfterEvent = 12.0
        var confirmationGap = 10.0
        var minimumGapBetweenFixes = 60.0
        var maximumFixesPerWindow = 3
        var window = 600.0
        var maximumFailedFixes = 2
        // A silent verdict this recent needs no further probe right before the fix.
        var freshVerdict = 3.0
    }

    enum Block: Equatable {
        // Two automatic fixes left this display silent; it is left to the user until reconnected.
        case gaveUp
        // This setup can never be fixed automatically (only screen, mirrored, unidentifiable).
        case cannotFix(String)
        // Too many fixes in the window; `justPaused` is true only on the decision that paused.
        case paused(justPaused: Bool)
    }

    enum Wait: Equatable {
        // Displays are settling, or the silence is not yet confirmed twice.
        case confirming
        // The previous fix was too recent.
        case tooSoon
    }

    enum FixResult {
        // The display was switched off and on and has sound again.
        case fixed
        // The display was switched off and on and is still silent.
        case stillSilent
        // Nothing was switched off (a guard, the lock, an unidentifiable screen); not a failure.
        case notAttempted
    }

    enum Decision: Equatable {
        case fix
        case wait(Wait, seconds: Double)
        case blocked(Block)
    }

    let timing: Timing
    private(set) var quietUntil: Date
    // The first and the latest probe that found each display silent: an automatic fix needs two
    // real probes at least `confirmationGap` apart, never a single verdict reused.
    private(set) var silentSince: [String: Date] = [:]
    private(set) var lastSilent: [String: Date] = [:]
    // Whether the fix in progress was started automatically; only those count towards giving up.
    private(set) var fixInProgressIsAutomatic = false
    private(set) var failedFixes: [String: Int] = [:]
    private(set) var fixTimes: [Date] = []
    private(set) var paused = false
    // When the user was last told about a pause; a sink that keeps re-announcing itself lifts the
    // pause each time, and must not trigger the same notification again and again.
    private(set) var pauseAnnounced: Date?

    init(now: Date, timing: Timing = Timing()) {
        self.timing = timing
        quietUntil = now.addingTimeInterval(timing.settleAfterEvent)
    }

    // Launch, wake or a session switch: displays may still be negotiating links.
    mutating func displaysMaySettle(now: Date) {
        quietUntil = max(quietUntil, now.addingTimeInterval(timing.settleAfterEvent))
    }

    // A real replug or new monitor: lift the pause and the per-display give-up, and settle.
    // The fix history is kept, so a sink that keeps re-announcing itself cannot reset the limit.
    mutating func topologyChanged(now: Date) {
        paused = false
        failedFixes.removeAll()
        displaysMaySettle(now: now)
    }

    // Only a deliberate user action clears the history.
    mutating func userActed() {
        paused = false
        pauseAnnounced = nil
        fixTimes.removeAll()
        failedFixes.removeAll()
    }

    // A display probed silent.
    mutating func observedSilent(_ uid: String, now: Date) {
        if silentSince[uid] == nil { silentSince[uid] = now }
        lastSilent[uid] = now
    }

    // A display probed working: forget its silence and failures; the watched one also unpauses.
    mutating func observedWorking(_ uid: String, isWatched: Bool) {
        silentSince[uid] = nil
        lastSilent[uid] = nil
        failedFixes[uid] = nil
        if isWatched { paused = false }
    }

    // What to do about a watched display that probed silent (`observedSilent` must come first).
    // `blocker` is why it can never be cycled on this setup, or nil. A `.wait(.confirming)` means
    // probe the display again after the given seconds, then ask again.
    mutating func decide(_ uid: String, now: Date, blocker: String?) -> Decision {
        if failedFixes[uid, default: 0] >= timing.maximumFailedFixes { return .blocked(.gaveUp) }
        if let blocker { return .blocked(.cannotFix(blocker)) }
        if paused { return .blocked(.paused(justPaused: false)) }
        let window = timing.window
        fixTimes.removeAll { now.timeIntervalSince($0) > window }
        if fixTimes.count >= timing.maximumFixesPerWindow {
            paused = true
            let announce = pauseAnnounced.map { now.timeIntervalSince($0) > window } ?? true
            if announce { pauseAnnounced = now }
            return .blocked(.paused(justPaused: announce))
        }
        if let last = fixTimes.last, now.timeIntervalSince(last) < timing.minimumGapBetweenFixes {
            return .wait(.tooSoon, seconds: timing.minimumGapBetweenFixes - now.timeIntervalSince(last))
        }
        guard let first = silentSince[uid], let latest = lastSilent[uid] else {
            return .wait(.confirming, seconds: timing.confirmationGap)
        }
        let settling = quietUntil.timeIntervalSince(now)
        let confirmed = latest.timeIntervalSince(first) >= timing.confirmationGap
        if settling > 0 || !confirmed {
            // After a single verdict the second probe may start at once: a stuck probe blocks for
            // about 10 s by itself, and the gap between the two verdicts is still required.
            let untilSecondProbe = confirmed || latest == first ? 0 : max(0, first.addingTimeInterval(timing.confirmationGap).timeIntervalSince(now))
            return .wait(.confirming, seconds: max(settling, untilSecondProbe, 0.5))
        }
        return .fix
    }

    // Whether a fix should probe once more before switching the display off: only when the
    // display's latest silent verdict is not fresh, since a dead link does not recover by itself.
    func needsFinalProbe(_ uid: String, now: Date) -> Bool {
        guard let latest = lastSilent[uid] else { return true }
        return now.timeIntervalSince(latest) > timing.freshVerdict
    }

    mutating func fixStarted(now: Date, automatic: Bool) {
        fixTimes.append(now)
        fixInProgressIsAutomatic = automatic
    }

    // The final re-probe found the display working, so no cycle happened.
    mutating func fixCancelled(_ uid: String) {
        if !fixTimes.isEmpty { fixTimes.removeLast() }
        silentSince[uid] = nil
        lastSilent[uid] = nil
    }

    mutating func fixFinished(_ uid: String, result: FixResult) {
        switch result {
        case .fixed:
            failedFixes[uid] = nil
            silentSince[uid] = nil
            lastSilent[uid] = nil
        case .stillSilent:
            if fixInProgressIsAutomatic { failedFixes[uid, default: 0] += 1 }
        case .notAttempted:
            // Nothing was switched off, so it neither counts as a failure nor against the limit.
            if !fixTimes.isEmpty { fixTimes.removeLast() }
        }
        fixInProgressIsAutomatic = false
    }
}
