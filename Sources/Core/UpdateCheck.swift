import Foundation

// The update check: once a day the app asks GitHub's public API for the latest release and,
// when it is newer, shows one menu item. It never downloads or installs anything. The network
// request lives in the app; everything here is pure and unit-tested.

let projectRepository = "juanjsebgarcia/loudstation"
let latestReleaseURL = URL(string: "https://api.github.com/repos/\(projectRepository)/releases/latest")!
let projectPageURL = URL(string: "https://github.com/\(projectRepository)")!
let homebrewUpgradeCommand = "brew update && brew upgrade \(commandName) && \(commandName) app"
let sourceUpgradeCommand = "make install"

// A release version: three or fewer dot-separated whole numbers, with an optional leading "v".
// Anything else (a pre-release suffix, letters, an absurd length) is not a version, so it can
// never be offered as an update.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), body.count <= 32 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 9, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        // 1.2 and 1.2.0 are the same version.
        while parts.count < 3 { parts.append(0) }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { lhs.parts == rhs.parts }
}

struct AvailableRelease: Equatable {
    let version: ReleaseVersion
    // Always a page under this project's releases on github.com; only ever opened in the browser.
    let pageURL: URL
}

// Reads GitHub's "latest release" answer. Drafts, pre-releases, unparseable versions and
// links that do not point at this project's own release pages are all ignored.
func parseLatestRelease(_ data: Data) -> AvailableRelease? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
          let tag = object["tag_name"] as? String, let version = ReleaseVersion(tag),
          let page = object["html_url"] as? String, let pageURL = URL(string: page),
          isProjectReleasePage(pageURL) else { return nil }
    return AvailableRelease(version: version, pageURL: pageURL)
}

func isProjectReleasePage(_ url: URL) -> Bool {
    guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.port == nil,
          !url.pathComponents.contains(where: { $0 == ".." || $0 == "." }) else { return false }
    return url.path.hasPrefix("/\(projectRepository)/releases/")
}

// What the app shows: a release only when it is newer than this copy.
func newerRelease(_ release: AvailableRelease?, than current: String) -> AvailableRelease? {
    guard let release, let current = ReleaseVersion(current), release.version > current else { return nil }
    return release
}

// A copy that Homebrew installed runs from its Cellar (or the opt link to it) and is updated
// with `brew upgrade`; any other copy was built from source with `make install`.
func isHomebrewInstall(bundlePath: String) -> Bool {
    let parts = bundlePath.components(separatedBy: "/")
    return zip(parts, parts.dropFirst()).contains { ($0 == "Cellar" || $0 == "opt") && $1 == commandName }
}

// After an update, the copy still running is the old one. Its bundle path usually still exists
// and shows the new version, because Homebrew's opt link (which the login item and
// `loudstation app` use) now points at the new Cellar folder, so what is on disk says nothing
// about what is running. A running copy is stale when its program file has gone or was replaced
// after it launched, or when the bundle it came from is an older version than this one. A newly
// opened copy asks stale copies to quit, so `brew upgrade` followed by `loudstation app` leaves
// the new version running.
func isStaleCopy(executableModified: Date?, launched: Date?, diskVersion: String?, ownVersion: String) -> Bool {
    guard let executableModified else { return true }
    // A second of slack for file systems that round modification times.
    if let launched, executableModified > launched.addingTimeInterval(1) { return true }
    guard let disk = diskVersion.flatMap(ReleaseVersion.init), let own = ReleaseVersion(ownVersion) else { return false }
    return disk < own
}

// When a process started, from the kernel. NSRunningApplication's launchDate is nil for a copy
// that launchd started by running its executable (the login item does exactly that), so it
// cannot be relied on.
func processStartTime(_ pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_starttime
    guard started.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
}

// Of two current copies, the one that started first stays and the other quits, so two copies
// opened at once never both quit or both run.
func startedFirst(_ lhs: (launched: Date?, pid: Int32), before rhs: (launched: Date?, pid: Int32)) -> Bool {
    switch (lhs.launched, rhs.launched) {
    case let (left?, right?) where left != right: return left < right
    default: return lhs.pid < rhs.pid
    }
}

// When the next automatic check is due: once a day, and straight away if the last check is
// unknown or lies in the future (the clock was set back).
struct UpdateSchedule {
    var interval: TimeInterval = 24 * 60 * 60
    var clockSlack: TimeInterval = 60 * 60

    func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        if lastChecked > now.addingTimeInterval(clockSlack) { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }
}
