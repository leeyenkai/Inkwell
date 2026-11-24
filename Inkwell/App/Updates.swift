import AppKit
import InkwellKit

/// Looks for a newer Inkwell on GitHub: once a day when allowed in Settings, and from "Check for Updates…".
/// Unsigned builds cannot replace themselves safely, so a newer version is offered as a download.
@Observable
final class Updates {
    enum State: Equatable {
        case idle, checking, upToDate, unavailable
        case available(ReleaseInfo)
        case failed(String)
    }

    var state = State.idle
    var windowRequested = false
    /// `--update-feed <url>` points the check at another feed, such as a local file, for testing.
    var feedOverride: URL?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var feed: URL? {
        feedOverride ?? (Bundle.main.object(forInfoDictionaryKey: "InkwellReleasesRepository") as? String).flatMap(UpdateCheck.feed)
    }

    func checkAutomatically() async {
        guard Prefs.bool(Prefs.checkForUpdates) else { return }
        let last = UserDefaults.standard.double(forKey: Prefs.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 60 * 60 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        if userInitiated { state = .checking }
        guard let feed else {
            state = .unavailable
            return
        }
        do {
            let release = try await UpdateCheck.latest(feed: feed)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheck)
            if let release, UpdateCheck.isNewer(release.version, than: currentVersion) {
                let skipped = UserDefaults.standard.string(forKey: Prefs.skippedVersion) == release.version
                if userInitiated || !skipped {
                    state = .available(release)
                    windowRequested = true
                }
            } else {
                state = release == nil ? .unavailable : .upToDate
            }
        } catch {
            Diagnostics.record("Update check: \(error.localizedDescription)")
            if userInitiated { state = .failed(error.localizedDescription) }
        }
    }

    func download(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.download)
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version, forKey: Prefs.skippedVersion)
        state = .idle
    }
}
