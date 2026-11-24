import AppKit
import InkwellKit

/// App preferences, kept in UserDefaults. The Settings window edits them with @AppStorage under the same keys.
nonisolated enum Prefs {
    static let editorFontSize = "EditorFontSize"
    static let inlineImages = "InlineImages"
    static let spellCheck = "SpellCheck"
    static let smartQuotes = "SmartQuotes"
    static let imageMaxSize = "ImageMaxSize"
    static let jpegQuality = "JPEGQuality"
    static let syncMinutes = "SyncMinutes"
    static let reopenLastSite = "ReopenLastSite"
    static let seenSites = "SeenSites"
    static let checkForUpdates = "CheckForUpdates"
    static let lastUpdateCheck = "LastUpdateCheck"
    static let skippedVersion = "SkippedVersion"

    static var defaults: [String: Any] { [
        editorFontSize: 15.0, inlineImages: true, spellCheck: true, smartQuotes: false,
        imageMaxSize: 2400, jpegQuality: 0.82, syncMinutes: 5, reopenLastSite: true, checkForUpdates: true,
    ] }

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static var fontSize: CGFloat { CGFloat(min(24, max(11, UserDefaults.standard.double(forKey: editorFontSize)))) }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

extension ImageImport {
    /// The importer with the size and quality chosen in Settings.
    nonisolated static var app: ImageImport {
        var importer = ImageImport()
        let size = UserDefaults.standard.integer(forKey: Prefs.imageMaxSize)
        if size >= 800 { importer.maxPixelSize = size }
        let quality = UserDefaults.standard.double(forKey: Prefs.jpegQuality)
        if quality >= 0.5, quality <= 1 { importer.jpegQuality = quality }
        return importer
    }
}

/// Errors shown to the person, kept in a log file for "Copy Diagnostics". Messages only, never tokens or file contents.
enum Diagnostics {
    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/Inkwell/Inkwell.log")
    }

    static func record(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        // Keep the log small: the last 500 lines.
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > 600 { try? Data((lines.suffix(500).joined(separator: "\n") + "\n").utf8).write(to: url) }
        }
    }

    static func recentLines(_ count: Int) -> [String] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(count).map(String.init)
    }

    @MainActor
    static func report(_ model: AppModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var lines = [
            "Inkwell \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        if let site = model.site {
            let kind = model.backend is GitHubBackend ? "GitHub" : "local folder"
            lines.append("Site: \(site.name) (\(kind)), \(site.sections.count) sections, \(site.documents.count) files, \(model.drafts.count) drafts")
            lines.append("Theme: \(site.config.raw["theme"]?.string ?? site.config.raw["remote_theme"]?.string ?? "site’s own layouts")")
            lines.append("Sync: \(model.syncStatus), \(model.pendingChanges) unpublished, \(model.conflicts.count) conflicts, \(model.unpushed) unpushed")
            lines.append("Health: \(model.healthProblems) problems")
        } else {
            lines.append("No site open")
        }
        lines.append("Signed in: \(model.account.isSignedIn ? "yes" : "no")")
        lines.append("")
        lines.append("Recent errors:")
        let recent = recentLines(20)
        lines += recent.isEmpty ? ["none"] : recent
        return lines.joined(separator: "\n")
    }
}
