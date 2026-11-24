import Foundation
import InkwellKit

struct PublishOutcome {
    var commit: String
    var pushed: Bool
    var pushError: String?
}

struct SyncOutcome {
    var updated: [String] = []
    var conflicts: [String] = []
}

/// One saved version of a file on GitHub (or in the folder's git history).
struct Revision: Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var date: Date?
}

/// Where a site's files live and how they reach GitHub. Paths are relative to the site folder.
@MainActor
protocol SiteBackend: AnyObject {
    var siteRoot: URL { get }
    var displayName: String { get }
    var draftKey: String { get }
    /// `owner/name` on GitHub, when known.
    var repository: (owner: String, name: String)? { get }
    var client: GitHubClient? { get }
    func changes() async throws -> [String: ChangeKind]
    func publish(paths: [String], message: String) async throws -> PublishOutcome
    func sync() async throws -> SyncOutcome
    func discard(path: String) async throws
    func conflicts() async -> [String]
    func resolve(path: String, keepMine: Bool) async throws
    func remoteVersion(of path: String) async throws -> String?
    /// Commits made here that are not on GitHub yet (local folders only).
    func unpushed() async -> Int
    func pushAgain() async throws
    /// Published versions of a file, newest first.
    func history(of path: String) async throws -> [Revision]
    /// A file's text in a given version, or nil when it did not exist then.
    func contents(of path: String, at revision: String) async throws -> String?
}

/// A site Inkwell downloaded from GitHub and keeps in Application Support. Publishing goes through the GitHub API.
@MainActor
final class GitHubBackend: SiteBackend {
    let copy: WorkingCopy
    let client: GitHubClient?

    init(copy: WorkingCopy, client: GitHubClient) {
        self.copy = copy
        self.client = client
    }

    static var container: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Inkwell/Sites", directoryHint: .isDirectory)
    }

    var siteRoot: URL { copy.siteRoot }
    var displayName: String { copy.ref.fullName }
    var draftKey: String { copy.ref.key }
    var repository: (owner: String, name: String)? { (copy.ref.owner, copy.ref.name) }

    func toRepo(_ path: String) -> String { copy.repoPath(path) }

    func fromRepo(_ path: String) -> String? {
        let prefix = copy.ref.sitePath
        if prefix.isEmpty { return path }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : nil
    }

    func changes() async throws -> [String: ChangeKind] {
        var result: [String: ChangeKind] = [:]
        for (path, kind) in try await copy.changes() {
            if let site = fromRepo(path) { result[site] = kind }
        }
        return result
    }

    func publish(paths: [String], message: String) async throws -> PublishOutcome {
        guard let client else { throw GitHubError.unauthorized }
        let commit = try await copy.publish(paths: paths.map(toRepo), message: message, client: client)
        return PublishOutcome(commit: commit, pushed: true)
    }

    func sync() async throws -> SyncOutcome {
        guard let client else { throw GitHubError.unauthorized }
        let outcome = try await copy.pull(client: client)
        return SyncOutcome(updated: outcome.updated.compactMap(fromRepo), conflicts: outcome.conflicts.compactMap(fromRepo))
    }

    func discard(path: String) async throws {
        guard let client else { throw GitHubError.unauthorized }
        try await copy.discard(path: toRepo(path), client: client)
    }

    func conflicts() async -> [String] { await copy.conflicts.compactMap(fromRepo) }

    func resolve(path: String, keepMine: Bool) async throws {
        guard let client else { throw GitHubError.unauthorized }
        try await copy.resolve(path: toRepo(path), keepMine: keepMine, client: client)
    }

    func remoteVersion(of path: String) async throws -> String? {
        guard let client else { throw GitHubError.unauthorized }
        return try await copy.remoteVersion(of: toRepo(path), client: client).map { String(decoding: $0, as: UTF8.self) }
    }

    func unpushed() async -> Int { 0 }
    func pushAgain() async throws {}

    func history(of path: String) async throws -> [Revision] {
        guard let client else { throw GitHubError.unauthorized }
        let ref = copy.ref
        return try await client.commits(ref.owner, ref.name, path: toRepo(path), branch: ref.branch).map {
            Revision(id: $0.sha, title: $0.title, author: $0.commit.author?.name ?? "", date: $0.date)
        }
    }

    func contents(of path: String, at revision: String) async throws -> String? {
        guard let client else { throw GitHubError.unauthorized }
        return try await client.fileContents(copy.ref.owner, copy.ref.name, path: toRepo(path), ref: revision)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Advanced: a clone the person keeps themselves, published with their own git.
@MainActor
final class LocalGitBackend: SiteBackend {
    let git: Git
    let siteRoot: URL
    let client: GitHubClient?
    private var repoPrefix = ""
    private(set) var remote: String?

    init?(siteRoot: URL, client: GitHubClient?) {
        guard let git = Git(root: siteRoot) else { return nil }
        self.git = git
        self.siteRoot = siteRoot
        self.client = client
    }

    func prepare() async -> Bool {
        guard await git.isRepository() else { return false }
        repoPrefix = await git.prefix()
        remote = await git.remoteURL()
        return true
    }

    var displayName: String { siteRoot.lastPathComponent }
    var draftKey: String { DraftStore(base: URL(fileURLWithPath: "/"), siteRoot: siteRoot).root.lastPathComponent }
    var repository: (owner: String, name: String)? { remote.flatMap(Git.gitHubRepository) }

    func changes() async throws -> [String: ChangeKind] {
        var result: [String: ChangeKind] = [:]
        for (path, status) in try await git.status() {
            guard path.hasPrefix(repoPrefix) else { continue }
            let site = String(path.dropFirst(repoPrefix.count))
            switch status {
            case .untracked, .added: result[site] = .added
            case .deleted: result[site] = .deleted
            case .modified, .renamed: result[site] = .modified
            }
        }
        return result
    }

    func publish(paths: [String], message: String) async throws -> PublishOutcome {
        let result = try await git.publish(paths: paths, message: message)
        return PublishOutcome(commit: result.commit, pushed: result.pushed, pushError: result.pushError)
    }

    func sync() async throws -> SyncOutcome {
        guard remote != nil, await unpushed() == 0 else { return SyncOutcome() }
        let before = try await git.head()
        let branch = try await git.currentBranch()
        try await git.run(["fetch", "origin", branch], allowFailure: true)
        let behind = Int(try await git.run(["rev-list", "--count", "HEAD..origin/\(branch)"], allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard behind > 0 else { return SyncOutcome() }
        do {
            try await git.run(["pull", "--rebase", "--autostash", "origin", branch])
        } catch {
            _ = try? await git.run(["rebase", "--abort"], allowFailure: true)
            throw error
        }
        let changed = try await git.run(["diff", "--name-only", before, "HEAD"]).split(separator: "\n").map(String.init)
        return SyncOutcome(updated: changed.compactMap { $0.hasPrefix(repoPrefix) ? String($0.dropFirst(repoPrefix.count)) : nil })
    }

    func discard(path: String) async throws { try await git.discard(path: path) }
    func conflicts() async -> [String] { [] }
    func resolve(path _: String, keepMine _: Bool) async throws {}
    func remoteVersion(of _: String) async throws -> String? { nil }
    func unpushed() async -> Int { remote == nil ? 0 : await git.unpushedCount() }
    func pushAgain() async throws { try await git.push() }

    func history(of path: String) async throws -> [Revision] {
        let out = try await git.run(["log", "--format=%H%x1f%an%x1f%aI%x1f%s", "-n", "50", "--", path])
        let iso = ISO8601DateFormatter()
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return Revision(id: parts[0], title: parts[3], author: parts[1], date: iso.date(from: parts[2]))
        }
    }

    func contents(of path: String, at revision: String) async throws -> String? {
        try? await git.run(["show", "\(revision):\(repoPrefix)\(path)"])
    }
}
