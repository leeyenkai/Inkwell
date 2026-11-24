import CryptoKit
import Foundation
import InkwellGitHub

/// Which repository and folder a site lives in.
public struct SiteRef: Codable, Hashable, Sendable {
    public var owner: String
    public var name: String
    public var branch: String
    /// The folder GitHub Pages builds from: "" for the repository root, or "docs".
    public var sitePath: String

    public init(owner: String, name: String, branch: String, sitePath: String = "") {
        self.owner = owner
        self.name = name
        self.branch = branch
        self.sitePath = sitePath
    }

    public var fullName: String { "\(owner)/\(name)" }
    /// Stable key for things kept per site, such as drafts.
    public var key: String { "\(owner)-\(name)".lowercased() }
}

public struct SyncState: Codable, Sendable {
    public var ref: SiteRef
    public var baseCommit: String
    public var baseTree: String
    /// Git blob SHA of every file at `baseCommit`, by repository path.
    public var files: [String: String]
    public var modes: [String: String]
    /// Paths changed both here and on GitHub, with the GitHub blob (nil when GitHub deleted it).
    public var conflicts: [String: String?]
    public var updated: Date
    /// Commits this copy has already moved past. GitHub can briefly report an older branch head after a push;
    /// a head in this list is stale, not a change.
    public var passed: [String]?

    mutating func pass(_ commit: String) {
        var list = passed ?? []
        list.removeAll { $0 == commit }
        list.append(commit)
        passed = Array(list.suffix(64))
    }
}

public enum ChangeKind: String, Sendable, Codable {
    case added
    case modified
    case deleted
}

public enum SyncError: Error, LocalizedError, Sendable, Equatable {
    case notDownloaded
    case conflict([String])
    case nothingToPublish
    case extractFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDownloaded: "The site has not been downloaded yet."
        case let .conflict(paths): "Changed here and on GitHub: \(paths.joined(separator: ", ")). Choose which version to keep first."
        case .nothingToPublish: "There is nothing new to publish."
        case let .extractFailed(message): "The site could not be unpacked: \(message)"
        }
    }
}

public struct PullOutcome: Sendable, Equatable {
    public var updated: [String] = []
    public var conflicts: [String] = []
    public var changedRemotely: Bool { !updated.isEmpty || !conflicts.isEmpty }
}

public enum GitBlob {
    /// The SHA-1 git gives a file's contents (`git hash-object`).
    public static func sha(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Inkwell's own copy of a site, kept in Application Support and synced with GitHub through the API.
/// Publishing makes one commit with exactly the named files; pulling brings in GitHub's changes without
/// overwriting local edits (those become conflicts to resolve).
public actor WorkingCopy {
    public nonisolated let ref: SiteRef
    public nonisolated let root: URL
    let stateURL: URL
    private(set) var state: SyncState?
    private var hashCache: [String: (size: Int, modified: Date, sha: String)] = [:]

    static let ignoredNames: Set = [".DS_Store", ".git", "_site", ".jekyll-cache", ".sass-cache", ".jekyll-metadata", "Thumbs.db"]

    public init(ref: SiteRef, container: URL) {
        self.ref = ref
        let folder = container.appending(path: ref.owner, directoryHint: .isDirectory).appending(path: ref.name, directoryHint: .isDirectory)
        root = folder.appending(path: "files", directoryHint: .isDirectory)
        stateURL = folder.appending(path: "state.json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved
        }
    }

    public var isDownloaded: Bool { state != nil && FileManager.default.fileExists(atPath: root.path) }
    public nonisolated var siteRoot: URL { ref.sitePath.isEmpty ? root : root.appending(path: ref.sitePath, directoryHint: .isDirectory) }
    public var baseCommit: String? { state?.baseCommit }
    public var conflicts: [String] { state.map { Array($0.conflicts.keys).sorted() } ?? [] }

    /// Repository path for a path relative to the site folder.
    public nonisolated func repoPath(_ sitePath: String) -> String {
        ref.sitePath.isEmpty ? sitePath : "\(ref.sitePath)/\(sitePath)"
    }

    // MARK: Download

    public func download(client: GitHubClient, progress: @Sendable (String) async -> Void = { _ in }) async throws {
        await progress("Finding the latest version…")
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        let commit = try await client.commit(ref.owner, ref.name, sha: head)
        let tree = try await client.tree(ref.owner, ref.name, sha: commit.tree.sha)
        await progress("Downloading the site…")
        let archive = try await client.tarball(ref.owner, ref.name, ref: head)
        await progress("Unpacking…")
        let fm = FileManager.default
        let staging = root.deletingLastPathComponent().appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tarFile = staging.appending(path: "site.tar.gz")
        try archive.write(to: tarFile)
        let unpacked = staging.appending(path: "x", directoryHint: .isDirectory)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.untar(tarFile, into: unpacked)
        let top = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        let content = top.count == 1 ? top[0] : unpacked
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: content, to: root)

        var files: [String: String] = [:]
        var modes: [String: String] = [:]
        for entry in tree.tree where entry.type == "blob" {
            files[entry.path] = entry.sha
            modes[entry.path] = entry.mode
        }
        state = SyncState(ref: ref, baseCommit: head, baseTree: commit.tree.sha, files: files, modes: modes, conflicts: [:], updated: Date())
        hashCache = [:]
        try saveState()
    }

    static func untar(_ archive: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", folder.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SyncError.extractFailed(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    // MARK: Changes

    /// Local changes against the last synced version, by repository path.
    public func changes() throws -> [String: ChangeKind] {
        guard let state else { throw SyncError.notDownloaded }
        var result: [String: ChangeKind] = [:]
        var seen = Set<String>()
        for (path, url) in localFiles() {
            seen.insert(path)
            let tracked = state.files[path]
            if tracked == nil, isIgnored(path) { continue }
            guard let sha = try? hash(path: path, url: url) else { continue }
            if let tracked {
                if tracked != sha { result[path] = .modified }
            } else {
                result[path] = .added
            }
        }
        for path in state.files.keys where !seen.contains(path) && state.modes[path] != "160000" {
            result[path] = .deleted
        }
        return result
    }

    func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").contains { Self.ignoredNames.contains(String($0)) }
    }

    func localFiles() -> [(String, URL)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        let base = root.standardizedFileURL.path
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            files.append((path, url))
        }
        return files
    }

    func contents(_ url: URL) throws -> Data {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) { return Data(target.utf8) }
        return try Data(contentsOf: url)
    }

    func hash(path: String, url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? -1, modified = values.contentModificationDate ?? .distantPast
        if let cached = hashCache[path], cached.size == size, cached.modified == modified { return cached.sha }
        let sha = try GitBlob.sha(contents(url))
        hashCache[path] = (size, modified, sha)
        return sha
    }

    // MARK: Publish

    /// Commits exactly `paths` (repository paths, added, changed or deleted) as one commit and moves the branch to it.
    public func publish(paths: [String], message: String, client: GitHubClient) async throws -> String {
        guard state != nil else { throw SyncError.notDownloaded }
        for attempt in 0 ..< 3 {
            let outcome = try await pull(client: client)
            let blocked = Set(outcome.conflicts + conflicts).intersection(paths)
            if !blocked.isEmpty { throw SyncError.conflict(blocked.sorted()) }
            do {
                return try await commit(paths: paths, message: message, client: client)
            } catch GitHubError.notFastForward where attempt < 2 {
                continue
            }
        }
        throw GitHubError.notFastForward
    }

    private func commit(paths: [String], message: String, client: GitHubClient) async throws -> String {
        guard var state else { throw SyncError.notDownloaded }
        var entries: [TreeEntryChange] = []
        var newFiles = state.files
        for path in Set(paths).sorted() {
            let url = root.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                let data = try contents(url)
                let sha = GitBlob.sha(data)
                guard sha != state.files[path] else { continue }
                let uploaded = try await client.createBlob(ref.owner, ref.name, data: data)
                let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
                entries.append(TreeEntryChange(path: path, sha: uploaded, mode: isLink ? "120000" : state.modes[path] ?? "100644"))
                newFiles[path] = uploaded
            } else if state.files[path] != nil {
                entries.append(TreeEntryChange(path: path, sha: nil))
                newFiles[path] = nil
            }
        }
        guard !entries.isEmpty else { throw SyncError.nothingToPublish }
        let tree = try await client.createTree(ref.owner, ref.name, base: state.baseTree, entries: entries)
        let commit = try await client.createCommit(ref.owner, ref.name, message: message, tree: tree, parents: [state.baseCommit])
        try await client.updateBranch(ref.owner, ref.name, branch: ref.branch, to: commit)
        state.pass(state.baseCommit)
        state.baseCommit = commit
        state.baseTree = tree
        state.files = newFiles
        for entry in entries { state.modes[entry.path] = entry.sha == nil ? nil : entry.mode }
        state.updated = Date()
        self.state = state
        try saveState()
        return commit
    }

    // MARK: Pull

    /// Brings in commits made elsewhere. Files changed only on GitHub are updated; files changed in both places are left
    /// as they are here and reported as conflicts.
    @discardableResult
    public func pull(client: GitHubClient) async throws -> PullOutcome {
        guard var state else { throw SyncError.notDownloaded }
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        guard head != state.baseCommit, !(state.passed ?? []).contains(head) else { return PullOutcome() }
        let commit = try await client.commit(ref.owner, ref.name, sha: head)
        let tree = try await client.tree(ref.owner, ref.name, sha: commit.tree.sha)
        var remote: [String: String] = [:]
        var remoteModes: [String: String] = [:]
        for entry in tree.tree where entry.type == "blob" {
            remote[entry.path] = entry.sha
            remoteModes[entry.path] = entry.mode
        }
        let local = try changes()
        var outcome = PullOutcome()
        for path in Set(state.files.keys).union(remote.keys).sorted() {
            let old = state.files[path], new = remote[path]
            guard old != new else { continue }
            if local[path] != nil {
                let url = root.appending(path: path)
                let localSHA = (try? contents(url)).map(GitBlob.sha)
                if localSHA == new {
                    state.files[path] = new
                } else {
                    state.conflicts[path] = .some(new)
                    outcome.conflicts.append(path)
                }
                continue
            }
            try await write(path: path, sha: new, client: client)
            state.files[path] = new
            outcome.updated.append(path)
        }
        state.modes = remoteModes
        state.pass(state.baseCommit)
        state.baseCommit = head
        state.baseTree = commit.tree.sha
        state.updated = Date()
        self.state = state
        try saveState()
        return outcome
    }

    private func write(path: String, sha: String?, client: GitHubClient) async throws {
        let url = root.appending(path: path)
        let fm = FileManager.default
        if let sha {
            let data = try await client.blob(ref.owner, ref.name, sha: sha)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        hashCache[path] = nil
    }

    // MARK: Conflicts and discarding

    /// Settles a conflict: keep this Mac's version (it publishes over GitHub's) or take GitHub's.
    public func resolve(path: String, keepMine: Bool, client: GitHubClient) async throws {
        guard var state, let remote = state.conflicts[path] else { return }
        if !keepMine { try await write(path: path, sha: remote, client: client) }
        state.files[path] = remote
        state.conflicts[path] = nil
        self.state = state
        try saveState()
    }

    /// GitHub's version of a conflicted file, for comparing.
    public func remoteVersion(of path: String, client: GitHubClient) async throws -> Data? {
        guard let state, let entry = state.conflicts[path], let sha = entry else { return nil }
        return try await client.blob(ref.owner, ref.name, sha: sha)
    }

    /// Puts a file back as it was at the last sync (or removes it if it is new).
    public func discard(path: String, client: GitHubClient) async throws {
        guard let state else { throw SyncError.notDownloaded }
        try await write(path: path, sha: state.files[path], client: client)
    }

    func saveState() throws {
        guard let state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
