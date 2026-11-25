import Foundation
import InkwellGitHub

/// Theme files for sites whose layouts live in a gem or remote theme, downloaded once and kept in Caches.
public struct ThemeCache: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static var standard: ThemeCache {
        ThemeCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Inkwell/Themes", directoryHint: .isDirectory))
    }

    /// The names come from the site's `_config.yml`, so anything that could reach outside the cache folder is replaced.
    public func location(owner: String, repository: String, ref: String?) -> URL {
        let name = "\(owner)-\(repository)@\(ref ?? "default")"
        let safe = String(name.map { $0.isLetter || $0.isNumber || "-_.@".contains($0) ? $0 : "_" }).replacingOccurrences(of: "..", with: "_")
        return folder.appending(path: safe, directoryHint: .isDirectory)
    }

    public func cached(owner: String, repository: String, ref: String?) -> URL? {
        let url = location(owner: owner, repository: repository, ref: ref)
        return FileManager.default.fileExists(atPath: url.appending(path: "_layouts").path) ? url : nil
    }

    /// The theme's files, downloading them the first time. Public themes need no sign-in.
    public func ensure(owner: String, repository: String, ref: String?, client: GitHubClient) async throws -> URL {
        if let url = cached(owner: owner, repository: repository, ref: ref) { return url }
        let encoded = ref.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        let path = encoded.map { "repos/\(owner)/\(repository)/tarball/\($0)" } ?? "repos/\(owner)/\(repository)/tarball"
        let (archive, _) = try await client.data("GET", path)
        let fm = FileManager.default
        let staging = folder.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tarFile = staging.appending(path: "theme.tar.gz")
        try archive.write(to: tarFile)
        let unpacked = staging.appending(path: "x", directoryHint: .isDirectory)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try WorkingCopy.untar(tarFile, into: unpacked)
        let top = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        let destination = location(owner: owner, repository: repository, ref: ref)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: top.count == 1 ? top[0] : unpacked, to: destination)
        return destination
    }
}
