import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import UserNotifications

// LoudStation: menu bar front end to Sources/Core. Checks every display's audio on display, wake
// and output changes (and the watched display on a timer); fixes only the display with the
// user's monitor speakers automatically, because cycling one display can knock out another
// display's audio link (see docs/). Every user-facing string goes through L(); log lines stay
// in English.

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.juanjsebgarcia.loudstation"
let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")

enum PanelHealth {
    case checking
    case working
    case noSound
    case unknown
}

struct PanelState {
    let output: DisplayAudioOutput
    var health: PanelHealth
    var lastProbe: Date?
}

enum Tone: String {
    case green, orange, red, blue, grey

    var color: NSColor {
        switch self {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .blue: return .systemBlue
        case .grey: return .secondaryLabelColor
        }
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "loudstation.work")
    private let defaults = UserDefaults.standard

    private var panels: [PanelState] = []
    private var soundOutputUID: String?
    private var busy = false
    private var fixingUID: String?
    private var quitAfterFix = false
    private var note: String?
    private var lastLoggedNote: String?
    private var lastCheck: Date?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var recheck: DispatchWorkItem?
    // When automatic fixing may act: settling, confirmation, rate limits and give-ups (Core).
    private var policy = AutoFixPolicy(now: Date())
    private var deferredUID: String?
    private var displaysAsleep = false
    private var sessionActive = true
    private var recoveryAttempts = 0
    private var strandedRetryPending = false
    private var fixIsAutomatic = false
    // Our own fix reconfigures displays and moves outputs; those events are ignored for a moment.
    private var ignoreEventsUntil = Date.distantPast
    private var recheckWhenDone = false
    private var lastTopology = ""
    private var glyphs: [Tone: NSImage] = [:]
    private var lastRendered = ""

    // A healthy probe gets callbacks within milliseconds; a stuck one blocks ~10s regardless.
    private let probeSeconds = 1.0
    private let settleAfterEvent = 12.0
    private let deferralRecheck = 30.0

    private var autoFix: Bool {
        get { defaults.bool(forKey: "autoFix") }
        set { defaults.set(newValue, forKey: "autoFix") }
    }

    private var interval: Int {
        get {
            let stored = defaults.integer(forKey: "interval")
            return stored <= 0 ? 0 : max(10, stored)
        }
        set { defaults.set(newValue, forKey: "interval") }
    }

    // nil means "follow the sound output".
    private var pinnedUID: String? {
        get { defaults.string(forKey: "watchedUID") }
        set { defaults.set(newValue, forKey: "watchedUID") }
    }

    private var watchedUID: String? { pinnedUID ?? soundOutputUID }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty || runningAsRoot {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: ["autoFix": true, "interval": 60])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu
        UNUserNotificationCenter.current().delegate = self
        render()
        if !defaults.bool(forKey: "launchAtLoginConfigured") {
            setLaunchAtLogin(true)
            defaults.set(true, forKey: "launchAtLoginConfigured")
        } else {
            repairLaunchAgent()
        }
        if !defaults.bool(forKey: "welcomed") { welcome() }
        observeEvents()
        lastTopology = topology()
        rescheduleTimer()
        say("\(appName) \(toolVersion) started (auto-fix \(autoFix ? "on" : "off"), every \(interval)s).", echo: false)
        recoverStranded()
        // Fill the menu with every display straight away, then check them all at once. Automatic
        // fixing still waits for the policy's settle time, since displays may still be coming up at login.
        check(reason: "launch", manual: false)
    }

    // A fix switches a screen off for a few seconds; quitting then would leave it off until
    // logout, so quitting waits for the fix to finish.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard fixingUID != nil else { return .terminateNow }
        quitAfterFix = true
        note = L("note.quitting")
        render()
        return .terminateLater
    }

    private func welcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("welcome.title", appName)
        alert.informativeText = L("welcome.body")
        alert.addButton(withTitle: L("welcome.fix_automatically"))
        alert.addButton(withTitle: L("welcome.status_only"))
        autoFix = alert.runModal() == .alertFirstButtonReturn
        defaults.set(true, forKey: "welcomed")
        say("Welcome answered: auto-fix \(autoFix ? "on" : "off").", echo: false)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            say("Notifications \(granted ? "allowed" : "not allowed").", echo: false)
        }
    }

    // MARK: Icon and menu

    private func overall() -> (tone: Tone, headline: String) {
        if let fixingUID {
            return (.blue, L("headline.fixing", label(for: fixingUID)))
        }
        if panels.isEmpty {
            return (.grey, L("headline.none"))
        }
        let silent = panels.filter { $0.health == .noSound }
        if let watchedUID, silent.contains(where: { $0.output.uid == watchedUID }) {
            return (.red, L("headline.speakers_silent"))
        }
        if !silent.isEmpty {
            return (.orange, L("headline.others_silent", silent.count))
        }
        if panels.contains(where: { $0.health == .checking }) {
            return (.grey, L("headline.checking"))
        }
        if panels.contains(where: { $0.health == .unknown }) {
            return (.grey, L("headline.couldnt_check"))
        }
        return (.green, L("headline.all_working"))
    }

    // Redraws the status item only when its state actually changed.
    private func render() {
        guard let button = statusItem?.button else { return }
        let look = overall()
        let key = "\(look.tone.rawValue)|\(look.headline)"
        guard key != lastRendered else { return }
        lastRendered = key
        button.image = statusGlyph(look.tone)
        button.toolTip = look.headline
        button.setAccessibilityLabel(L("accessibility.status", appName, look.headline))
    }

    // The app icon's mark, drawn for the menu bar: a display outline with a sawtooth wave on its
    // screen, in the colour of the current state. Coordinates follow the icon's 100-unit grid.
    // One image per tone is enough: drawing-handler images resolve dynamic colours when drawn.
    private func statusGlyph(_ tone: Tone) -> NSImage {
        if let cached = glyphs[tone] { return cached }
        let color = tone.color
        let image = NSImage(size: NSSize(width: 21, height: 18), flipped: true) { rect in
            let scale = min(rect.width / 92, rect.height / 80)
            let left = (rect.width - 92 * scale) / 2
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: left + (x - 4) * scale, y: (y - 10) * scale) }
            color.setStroke()
            color.setFill()
            let screen = NSBezierPath(roundedRect: NSRect(origin: point(12, 20), size: NSSize(width: 76 * scale, height: 50 * scale)),
                                      xRadius: 7 * scale, yRadius: 7 * scale)
            screen.lineWidth = 7 * scale
            screen.stroke()
            NSBezierPath(rect: NSRect(origin: point(44, 70), size: NSSize(width: 12 * scale, height: 9 * scale))).fill()
            NSBezierPath(roundedRect: NSRect(origin: point(30, 79), size: NSSize(width: 40 * scale, height: 6 * scale)),
                         xRadius: 3 * scale, yRadius: 3 * scale).fill()
            let wave = NSBezierPath()
            let teeth: [(CGFloat, CGFloat)] = [(18, 45), (18, 56), (39.33, 34), (39.33, 56), (60.67, 34), (60.67, 56), (82, 34), (82, 45)]
            wave.move(to: point(teeth[0].0, teeth[0].1))
            teeth.dropFirst().forEach { wave.line(to: point($0.0, $0.1)) }
            wave.lineWidth = 7 * scale
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = false
        glyphs[tone] = image
        return image
    }

    private func symbol(_ name: String, _ color: NSColor, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    // Disambiguates identical names by connection, then by position.
    private func label(for panelUID: String) -> String {
        guard let panel = panels.first(where: { $0.output.uid == panelUID }) else { return L("display.fallback") }
        let sameName = panels.filter { $0.output.name == panel.output.name }
        if sameName.count == 1 { return panel.output.name }
        let connection = panel.output.transport == "display" ? L("display.connection_generic") : panel.output.transport
        let sameTransport = sameName.filter { $0.output.transport == panel.output.transport }
        if sameTransport.count == 1 { return L("display.with_connection", panel.output.name, connection) }
        let position = (sameTransport.firstIndex { $0.output.uid == panelUID } ?? 0) + 1
        return L("display.with_connection_number", panel.output.name, connection, position)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let look = overall()
        menu.addItem(info(look.headline))
        if look.tone == .red, let watchedUID { menu.addItem(info(L("headline.speakers_on", label(for: watchedUID)))) }
        if let note { menu.addItem(info(note)) }
        if let summary = fixSummary() { menu.addItem(info(summary)) }
        menu.addItem(.separator())

        for panel in panels {
            let panelUID = panel.output.uid
            let isWatched = panelUID == watchedUID
            var tags: [String] = []
            if isWatched { tags.append(L("row.tag.speakers")) }
            if panelUID == soundOutputUID && pinnedUID != nil { tags.append(L("row.tag.sound_output")) }
            let look: (word: String, symbol: String, color: NSColor) = {
                if fixingUID == panelUID { return (L("status.fixing"), "arrow.triangle.2.circlepath", .systemBlue) }
                switch panel.health {
                case .working: return (L("status.working"), "checkmark.circle.fill", .systemGreen)
                case .noSound: return (L("status.no_sound"), isWatched ? "xmark.circle.fill" : "exclamationmark.circle.fill", isWatched ? .systemRed : .systemOrange)
                case .checking: return (L("status.checking"), "circle.dotted", .secondaryLabelColor)
                case .unknown: return (L("status.couldnt_check"), "questionmark.circle.fill", .secondaryLabelColor)
                }
            }()
            let title = tags.isEmpty
                ? L("row.plain", label(for: panelUID), look.word)
                : L("row.with_tags", label(for: panelUID), localizedList(tags), look.word)
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.image = symbol(look.symbol, look.color, size: 12)
            let sub = NSMenu()
            sub.autoenablesItems = false
            let here = item(L("submenu.speakers_here"), #selector(watchDisplay(_:)), enabled: true)
            here.representedObject = panelUID
            here.state = pinnedUID == panelUID ? .on : .off
            sub.addItem(here)
            let fix = item(isWatched ? L("submenu.fix_now") : L("submenu.fix_now_confirm"), #selector(fixDisplay(_:)), enabled: !busy)
            fix.representedObject = panelUID
            sub.addItem(fix)
            sub.addItem(info(L("submenu.hint_blackout")))
            if !isWatched { sub.addItem(info(L("submenu.hint_others"))) }
            if let counts = stats(for: panelUID) { sub.addItem(info(counts)) }
            if let lastProbe = panel.lastProbe { sub.addItem(info(L("submenu.checked", relativeTime(lastProbe)))) }
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())

        menu.addItem(item(L("menu.check_now"), #selector(checkNow), key: "r", enabled: !busy))
        let follow = item(L("menu.follow_sound_output"), #selector(followSoundOutput), enabled: true)
        follow.state = pinnedUID == nil ? .on : .off
        menu.addItem(follow)
        let auto = item(L("menu.fix_automatically"), #selector(toggleAutoFix), enabled: true)
        auto.state = autoFix ? .on : .off
        menu.addItem(auto)
        let every = NSMenuItem(title: L("menu.check_every"), action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for seconds in [10, 20, 60, 0] {
            let title = seconds == 0 ? L("menu.interval.events_only") : (seconds == 60 ? L("menu.interval.minute") : L("menu.interval.seconds", seconds))
            let choice = item(title, #selector(chooseInterval(_:)), enabled: true)
            choice.tag = seconds
            choice.state = interval == seconds ? .on : .off
            choices.addItem(choice)
        }
        every.submenu = choices
        menu.addItem(every)
        let login = item(L("menu.open_at_login"), #selector(toggleLaunchAtLogin), enabled: true)
        login.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        if let lastCheck { menu.addItem(info(L("menu.last_checked", relativeTime(lastCheck)))) }
        menu.addItem(item(L("menu.show_log"), #selector(openLog), key: "l", enabled: true))
        menu.addItem(item(fixingUID == nil ? L("menu.quit", appName) : L("menu.quit_after_fix"), #selector(quit), key: "q", enabled: true))
    }

    private func info(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    // MARK: Fault counts

    private func record(_ panelUID: String, fixed: Bool) {
        var all = defaults.dictionary(forKey: "stats") ?? [:]
        var entry = all[panelUID] as? [String: Any] ?? [:]
        if fixed {
            entry["fixed"] = (entry["fixed"] as? Int ?? 0) + 1
            entry["lastFixed"] = Date()
        } else {
            entry["noSound"] = (entry["noSound"] as? Int ?? 0) + 1
        }
        all[panelUID] = entry
        defaults.set(all, forKey: "stats")
    }

    private func stats(for panelUID: String) -> String? {
        guard let entry = defaults.dictionary(forKey: "stats")?[panelUID] as? [String: Any] else { return nil }
        let silent = entry["noSound"] as? Int ?? 0
        let fixed = entry["fixed"] as? Int ?? 0
        guard silent + fixed > 0 else { return nil }
        return L("submenu.counts", silent, fixed)
    }

    private func fixSummary() -> String? {
        let entries = (defaults.dictionary(forKey: "stats") ?? [:]).values.compactMap { $0 as? [String: Any] }
        let fixed = entries.reduce(0) { $0 + ($1["fixed"] as? Int ?? 0) }
        guard fixed > 0, let last = entries.compactMap({ $0["lastFixed"] as? Date }).max() else { return nil }
        return L("menu.fix_summary", fixed, relativeTime(last))
    }

    // MARK: Notifications

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // MARK: Actions

    // Only a deliberate action from the user resets the fix history and lifts a latched pause.
    private func userActed() {
        policy.userActed()
    }

    @objc private func checkNow() {
        userActed()
        check(reason: "manual", manual: true)
    }

    @objc private func watchDisplay(_ sender: NSMenuItem) {
        guard let panelUID = sender.representedObject as? String else { return }
        pinnedUID = pinnedUID == panelUID ? nil : panelUID
        say("Monitor speakers set to \(pinnedUID.map { label(for: $0) } ?? "follow the sound output").", echo: false)
        // Setting a display as the speaker output also makes it the Mac's sound output, so the
        // menu item does what it says. Going back to following the sound output changes nothing.
        if let pinned = pinnedUID, let dev = device(withUID: pinned), dev != defaultOutputDevice() {
            let switched = setDefaultOutputDevice(dev)
            say(switched ? "Sound output switched to \(label(for: pinned))." : "Could not switch the sound output to \(label(for: pinned)).", echo: false)
            if switched { note = L("note.output_switched", label(for: pinned)) }
        }
        render()
    }

    @objc private func followSoundOutput() {
        pinnedUID = nil
        say("Watching the sound output.", echo: false)
        render()
    }

    @objc private func fixDisplay(_ sender: NSMenuItem) {
        guard let panelUID = sender.representedObject as? String else { return }
        if panelUID != watchedUID {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("confirm.title", label(for: panelUID))
            alert.informativeText = L("confirm.body", label(for: panelUID))
            alert.addButton(withTitle: L("confirm.fix"))
            alert.addButton(withTitle: L("confirm.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard !busy else {
            note = L("note.busy")
            render()
            return
        }
        userActed()
        fix(panelUID, reason: "manual", automatic: false, confirmFirst: false)
    }

    @objc private func toggleAutoFix() {
        autoFix.toggle()
        say("Auto-fix turned \(autoFix ? "on" : "off").", echo: false)
        if autoFix {
            userActed()
            check(reason: "auto-fix enabled", manual: true)
        } else {
            note = nil
            render()
        }
    }

    @objc private func chooseInterval(_ sender: NSMenuItem) {
        interval = sender.tag
        rescheduleTimer()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!FileManager.default.fileExists(atPath: launchAgentURL.path))
    }

    // Revealed in Finder rather than opened, so a swapped file can never be launched by it.
    @objc private func openLog() { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Login item

    // The login item runs this app through a guard that exits successfully when the app is gone
    // (after `brew uninstall`, say), so launchd neither relaunches nor logs failures for ever.
    private func launchAgentArguments() -> [String]? {
        guard let executable = Bundle.main.executablePath.map(stablePath) else { return nil }
        return ["/bin/sh", "-c", "[ -x \"$0\" ] && exec \"$0\"; exit 0", executable]
    }

    // A per-user LaunchAgent: works for an ad-hoc signed app, needs no privileges, and takes
    // effect at the next login. Not loaded now, so it never starts a second copy.
    private func setLaunchAtLogin(_ enabled: Bool) {
        if !enabled {
            try? FileManager.default.removeItem(at: launchAgentURL)
            say("Launch at login turned off.", echo: false)
            return
        }
        guard let arguments = launchAgentArguments() else { return }
        let agent: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 60,
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
            say("Launch at login turned on (\(launchAgentURL.path)).", echo: false)
        } catch {
            say("Could not write the launch agent: \(error.localizedDescription)", echo: false)
        }
    }

    // An existing login item that does not run this copy the expected way (a vanished or
    // versioned Homebrew path, an older format, an edited command) is rewritten.
    private func repairLaunchAgent() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path),
              let expected = launchAgentArguments() else { return }
        let data = try? Data(contentsOf: launchAgentURL)
        let agent = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let arguments = agent?["ProgramArguments"] as? [String] ?? []
        // Another copy that still exists (Homebrew's or ~/Applications) keeps the login item; only a
        // missing or versioned path, or an older format, is rewritten to this copy.
        let recorded = arguments.last ?? ""
        let oldFormat = arguments.first != expected.first || arguments.count != expected.count || agent?["ThrottleInterval"] == nil
        let broken = !FileManager.default.fileExists(atPath: recorded) || recorded.contains("/Cellar/")
        guard oldFormat || broken else { return }
        say("Login item was \(oldFormat ? "in an older format" : "pointing at a missing or versioned path"); rewriting it.", echo: false)
        setLaunchAtLogin(true)
    }

    // A display a fix left switched off (a crash, a failed re-enable) is switched back on,
    // retrying every 5 seconds for a minute.
    private func recoverStranded() {
        guard fixingUID == nil, !strandedRetryPending, strandedDisplay() != nil else { return }
        work.async {
            let recovered = recoverStrandedDisplay()
            DispatchQueue.main.async {
                guard !recovered else {
                    self.recoveryAttempts = 0
                    return
                }
                self.recoveryAttempts += 1
                self.note = L("note.stranded")
                self.render()
                if self.recoveryAttempts < 12 {
                    self.strandedRetryPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.strandedRetryPending = false
                        self.recoverStranded()
                    }
                } else if self.recoveryAttempts == 12 {
                    self.notify(L("notify.stranded.title"), L("notify.stranded.body", appName))
                }
            }
        }
    }

    // MARK: Triggers

    private func observeEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for sleep in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: sleep, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaysAsleep = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        for wake in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaysAsleep = false
                self.policy.displaysMaySettle(now: Date())
                self.rescheduleTimer()
                self.schedule(after: self.settleAfterEvent, reason: "wake")
            }
        }
        // Fast user switching: a session in the background must not probe or touch displays.
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionActive = false
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionActive = true
            self.policy.displaysMaySettle(now: Date())
            self.schedule(after: self.settleAfterEvent, reason: "session active")
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.displaysChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self, self.fixingUID == nil, Date() >= self.ignoreEventsUntil else { return }
            self.schedule(after: 2, reason: "output changed")
        }
    }

    // Which displays and display-audio devices exist; a change means a real replug or new monitor.
    private func topology() -> String {
        onlineDisplays().sorted().map(String.init).joined(separator: ",") + "|" + displayAudioEngineUIDs().sorted().joined(separator: ",")
    }

    // Our own fixes reconfigure displays too; those are ignored. Only a real topology change
    // (a replug, a new monitor) lifts a latched pause and the per-display give-up; mode,
    // arrangement and wake events do not. A change during a check is remembered, not lost.
    private func displaysChanged() {
        guard Date() >= ignoreEventsUntil else { return }
        // During our own fix the reconfiguration is ours; a re-check after it covers a real replug too.
        if fixingUID != nil {
            recheckWhenDone = true
            return
        }
        let now = topology()
        if now != lastTopology {
            lastTopology = now
            policy.topologyChanged(now: Date())
            say("Display topology changed.", echo: false)
        }
        recoverStranded()
        if busy {
            recheckWhenDone = true
            return
        }
        schedule(after: settleAfterEvent, reason: "displays changed")
    }

    // Timer ticks re-check only the display with the monitor speakers: the fault starts at link
    // setup, which raises events that re-check everything. Ticks are skipped in Low Power Mode,
    // and the timer stops while the displays sleep.
    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard interval > 0, !displaysAsleep else { return }
        let next = Timer(timeInterval: Double(interval), repeats: true) { [weak self] _ in
            guard let self, self.sessionActive, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            self.recoverStranded()
            self.check(reason: "timer", manual: false)
        }
        next.tolerance = Double(interval) * 0.15
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func schedule(after seconds: Double, reason: String) {
        pending?.cancel()
        let next = DispatchWorkItem { [weak self] in self?.check(reason: reason, manual: false) }
        pending = next
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: next)
    }

    // Re-probes the watched display after a wait, so the next decision rests on a fresh result.
    private func scheduleRecheck(after seconds: Double) {
        recheck?.cancel()
        let next = DispatchWorkItem { [weak self] in self?.check(reason: "confirm", manual: false) }
        recheck = next
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, seconds), execute: next)
    }

    // MARK: Checking and fixing

    private func check(reason: String, manual: Bool) {
        guard !busy else {
            // A check that is not a routine tick is remembered and run after the current one.
            if reason != "timer" { recheckWhenDone = true }
            return
        }
        if (displaysAsleep || !sessionActive) && !manual { return }
        busy = true
        // On timer ticks only the watched display is probed, and not while it is known silent: a
        // silent display only recovers when its link is rebuilt, which raises an event and a full
        // check, and each such probe blocks ~10 s.
        let watched = watchedUID
        let skip: Set<String>
        switch reason {
        case "timer": skip = Set(panels.filter { $0.output.uid != watched || $0.health == .noSound }.map { $0.output.uid })
        case "confirm": skip = Set(panels.filter { $0.output.uid != watched }.map { $0.output.uid })
        default: skip = []
        }
        let seconds = probeSeconds
        let before = Dictionary(panels.map { ($0.output.uid, $0.health) }, uniquingKeysWith: { first, _ in first })
        work.async {
            let outputs = displayAudioOutputs()
            let sound = defaultOutputDevice().flatMap { dev in outputs.first { $0.device == dev }?.uid }
            // Listing is instant, so the menu shows every display before any probe finishes.
            DispatchQueue.main.async { self.showOutputs(outputs, sound: sound) }
            // Probes run in parallel and each row updates as its own result lands: a healthy
            // display answers in about a second, while a silent one blocks for about 10.
            let lock = NSLock()
            var results: [String: Bool?] = [:]
            let probed = outputs.filter { !skip.contains($0.uid) }
            DispatchQueue.concurrentPerform(iterations: probed.count) { index in
                let output = probed[index]
                let result = probe(output.device, seconds: seconds, log: manual)
                lock.lock()
                results[output.uid] = result
                lock.unlock()
                DispatchQueue.main.async { self.showResult(output.uid, result) }
            }
            DispatchQueue.main.async { self.finishCheck(outputs, sound: sound, results: results, before: before, reason: reason) }
        }
    }

    // New displays appear as Checking…; displays already known keep their last state.
    private func showOutputs(_ outputs: [DisplayAudioOutput], sound: String?) {
        soundOutputUID = sound
        panels = outputs.map { output in
            panels.first { $0.output.uid == output.uid } ?? PanelState(output: output, health: .checking, lastProbe: nil)
        }
        render()
    }

    private func showResult(_ panelUID: String, _ result: Bool?) {
        guard let index = panels.firstIndex(where: { $0.output.uid == panelUID }) else { return }
        panels[index].health = result == true ? .working : (result == false ? .noSound : .unknown)
        panels[index].lastProbe = Date()
        render()
    }

    private func finishCheck(_ outputs: [DisplayAudioOutput], sound: String?, results: [String: Bool?], before: [String: PanelHealth], reason: String) {
        busy = false
        lastCheck = Date()
        soundOutputUID = sound
        panels = outputs.map { output in
            if let result = results[output.uid] {
                let health: PanelHealth = result == true ? .working : (result == false ? .noSound : .unknown)
                return PanelState(output: output, health: health, lastProbe: Date())
            }
            return panels.first { $0.output.uid == output.uid } ?? PanelState(output: output, health: .checking, lastProbe: nil)
        }
        for panel in panels {
            let panelUID = panel.output.uid
            if let result = results[panelUID] {
                if result == true { policy.observedWorking(panelUID, isWatched: panelUID == watchedUID) }
                if result == false { policy.observedSilent(panelUID, now: Date()) }
            }
            guard before[panelUID] != panel.health, panel.health != .checking else { continue }
            let word = panel.health == .working ? "working" : (panel.health == .noSound ? "has no sound" : "could not be checked")
            say("\(label(for: panelUID)) \(panel.health == .working ? "is " : "")\(word) (\(reason)).", echo: false)
            if panel.health == .noSound { record(panelUID, fixed: false) }
        }
        if let watchedUID, panels.first(where: { $0.output.uid == watchedUID })?.health == .working {
            deferredUID = nil
        }
        note = nil
        if let watchedUID, pinnedUID != nil, !panels.contains(where: { $0.output.uid == watchedUID }) {
            note = L("note.speakers_missing")
        }
        if recheckWhenDone {
            recheckWhenDone = false
            schedule(after: settleAfterEvent, reason: "recheck")
        }
        considerAutoFix(reason: reason)
        render()
    }

    // Decides whether to fix the monitor speakers' display now, later, or not at all, and says
    // why. The rules live in AutoFixPolicy (Core), where they are unit-tested.
    private func considerAutoFix(reason: String) {
        guard autoFix, !busy, !displaysAsleep, sessionActive, let watchedUID,
              panels.first(where: { $0.output.uid == watchedUID })?.health == .noSound else { return }
        let target = label(for: watchedUID)
        let display = display(forAudioUID: watchedUID)
        let blocker = display.map { cycleBlocker($0) } ?? "its screen cannot be identified"
        let limit = policy.timing.maximumFixesPerWindow
        switch policy.decide(watchedUID, now: Date(), blocker: blocker) {
        case .blocked(.gaveUp):
            setNote(L("note.gave_up"), log: "Auto-fix stopped for \(target) after \(policy.timing.maximumFailedFixes) failed fixes.")
        case .blocked(.cannotFix(let why)):
            setNote(L("note.cant_autofix"), log: "Cannot fix \(target) automatically: \(why).")
        case .blocked(.paused(let justPaused)):
            setNote(L("note.paused", limit), log: "Auto-fix paused after \(limit) tries.")
            if justPaused { notify(L("notify.paused.title"), L("notify.paused.body", limit, target)) }
        case .wait(.tooSoon, let seconds):
            setNote(L("note.too_soon"), log: "Auto-fix waiting: the last fix was under a minute ago.")
            scheduleRecheck(after: seconds + 1)
        case .wait(.confirming, let seconds):
            setNote(L("note.confirming"), log: "Waiting to confirm \(target) is silent before fixing.")
            scheduleRecheck(after: seconds + 0.5)
        case .fix:
            guard let display else { return }
            if let deferral = deferralReason(for: display) {
                switch deferral {
                case .pointer:
                    scheduleRecheck(after: 5)
                case .call, .fullScreen:
                    let inCall = deferral == .call
                    setNote(L(inCall ? "note.waiting_call" : "note.waiting_full_screen"),
                            log: "Auto-fix waiting while \(inCall ? "a microphone is in use" : "something is full screen on it").")
                    if deferredUID != watchedUID {
                        deferredUID = watchedUID
                        notify(L("notify.waiting.title"), L(inCall ? "notify.waiting_call.body" : "notify.waiting_full_screen.body", target))
                    }
                    scheduleRecheck(after: deferralRecheck)
                }
                return
            }
            deferredUID = nil
            fix(watchedUID, reason: "auto, \(reason)", automatic: true, confirmFirst: true)
        }
    }

    private enum Deferral {
        case call
        case fullScreen
        case pointer
    }

    // A fix blanks the display, so it waits out calls, full-screen use on that display, and a
    // drag in progress.
    private func deferralReason(for display: CGDirectDisplayID) -> Deferral? {
        if NSEvent.pressedMouseButtons != 0 { return .pointer }
        if microphoneInUse() { return .call }
        if fullScreenWindowCovers(display) { return .fullScreen }
        return nil
    }

    // Shows a localised note and logs its English equivalent once.
    private func setNote(_ text: String, log: String) {
        note = text
        if log != lastLoggedNote {
            lastLoggedNote = log
            say(log, echo: false)
        }
    }

    private func fix(_ panelUID: String, reason: String, automatic: Bool, confirmFirst: Bool) {
        guard !busy, let dev = device(withUID: panelUID) else { return }
        busy = true
        fixingUID = panelUID
        lastLoggedNote = nil
        note = L("note.fixing", label(for: panelUID))
        render()
        policy.fixStarted(now: Date(), automatic: automatic)
        fixIsAutomatic = automatic
        say("Fix of \(label(for: panelUID)) started (\(reason)).", echo: false)
        work.async {
            // An automatic fix probes once more first, so a display that recovered meanwhile is left alone.
            if confirmFirst, probe(dev, seconds: self.probeSeconds, log: false) != false {
                DispatchQueue.main.async { self.cancelFix(panelUID) }
                return
            }
            let outcome = repair(dev, probeSeconds: 2, hold: 3, settle: 4)
            DispatchQueue.main.async { self.finishFix(panelUID, outcome) }
        }
    }

    private func cancelFix(_ panelUID: String) {
        busy = false
        fixingUID = nil
        policy.fixCancelled(panelUID)
        note = nil
        say("\(label(for: panelUID)) recovered before the fix; leaving it alone.", echo: false)
        if quitAfterFix {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        schedule(after: 1, reason: "recovered")
        render()
    }

    private func finishFix(_ panelUID: String, _ outcome: RepairOutcome) {
        let automatic = fixIsAutomatic
        fixIsAutomatic = false
        busy = false
        fixingUID = nil
        ignoreEventsUntil = Date().addingTimeInterval(5)
        let target = label(for: panelUID)
        if let index = panels.firstIndex(where: { $0.output.uid == panelUID }) {
            panels[index].health = outcome.status == .fixed ? .working : .noSound
            panels[index].lastProbe = Date()
        }
        let collateral = outcome.collateral.isEmpty ? nil : localizedList(outcome.collateral)
        switch outcome.status {
        case .fixed:
            record(panelUID, fixed: true)
            note = collateral.map { L("note.collateral", target, $0) }
            if automatic {
                notify(L("notify.fixed.title"), collateral.map { L("notify.fixed.body_collateral", target, $0) } ?? L("notify.fixed.body", target))
            }
        case .stillStuck:
            note = outcome.message
            if automatic { notify(L("notify.still_silent.title"), L("notify.still_silent.body", target)) }
        case .noDisplay, .notAttempted:
            note = outcome.message
        case .cycleFailed:
            note = outcome.message
            recoveryAttempts = 0
            recoverStranded()
        }
        let result: AutoFixPolicy.FixResult
        switch outcome.status {
        case .fixed: result = .fixed
        case .stillStuck, .cycleFailed: result = .stillSilent
        case .noDisplay, .notAttempted: result = .notAttempted
        }
        policy.fixFinished(panelUID, result: result)
        lastTopology = topology()
        render()
        if quitAfterFix {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        // The cycle may have knocked others out; re-check everything shortly to show it. This also
        // covers a real replug that arrived during the fix.
        recheckWhenDone = false
        schedule(after: 6, reason: "after fix")
    }
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
