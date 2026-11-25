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

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decode(String.self, forKey: .branch)
        sitePath = try c.decodeIfPresent(String.self, forKey: .sitePath) ?? ""
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

    public init(ref: SiteRef, baseCommit: String, baseTree: String, files: [String: String], modes: [String: String],
                conflicts: [String: String?], updated: Date, passed: [String]? = nil) {
        self.ref = ref
        self.baseCommit = baseCommit
        self.baseTree = baseTree
        self.files = files
        self.modes = modes
        self.conflicts = conflicts
        self.updated = updated
        self.passed = passed
    }

    /// Fields added after the first release are optional here, so a newer build still reads an older copy's state.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(SiteRef.self, forKey: .ref)
        baseCommit = try c.decode(String.self, forKey: .baseCommit)
        baseTree = try c.decode(String.self, forKey: .baseTree)
        files = try c.decode([String: String].self, forKey: .files)
        modes = try c.decodeIfPresent([String: String].self, forKey: .modes) ?? [:]
        conflicts = try c.decodeIfPresent([String: String?].self, forKey: .conflicts) ?? [:]
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        passed = try c.decodeIfPresent([String].self, forKey: .passed)
    }

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
    case tooLarge
    /// GitHub did not answer whether the branch moved. Nothing is undone here, since the publish may be live.
    case unconfirmed

    public var errorDescription: String? {
        switch self {
        case .notDownloaded: localized("The site has not been downloaded yet.")
        case let .conflict(paths): localized("Changed here and on GitHub: \(paths.joined(separator: ", ")). Choose which version to keep first.")
        case .nothingToPublish: localized("There is nothing new to publish.")
        case let .extractFailed(message): localized("The site could not be unpacked: \(message)")
        case .tooLarge: localized("The repository has more files than GitHub lists in one answer, so Inkwell cannot keep it in step.")
        case .unconfirmed: localized("GitHub did not confirm the publish. Check GitHub for changes in a moment to see whether it went through.")
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
    /// Downloads, pulls, publishes and conflict fixes take turns: each reads the state, waits on the network and writes it
    /// back, so two at once would undo each other.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

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

    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: Download

    public func download(client: GitHubClient, progress: @Sendable (String) async -> Void = { _ in }) async throws {
        try await exclusive { try await downloadNow(client: client, progress: progress) }
    }

    private func downloadNow(client: GitHubClient, progress: @Sendable (String) async -> Void) async throws {
        await progress(localized("Finding the latest version…"))
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        let commit = try await client.commit(ref.owner, ref.name, sha: head)
        let tree = try await client.tree(ref.owner, ref.name, sha: commit.tree.sha)
        guard !tree.truncated else { throw SyncError.tooLarge }
        await progress(localized("Downloading the site…"))
        let archive = try await client.tarball(ref.owner, ref.name, ref: head)
        await progress(localized("Unpacking…"))
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
        if fm.fileExists(atPath: root.path) {
            // A copy without readable state may still hold unpublished edits: keep it beside the new one, never delete it.
            let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            try fm.moveItem(at: root, to: root.deletingLastPathComponent().appending(path: "files-before-\(stamp)", directoryHint: .isDirectory))
        }
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

        // The archive can differ from the tree (export-ignore, export-subst): fetch those files one by one, so a fresh
        // copy never shows changes that publishing would then send. State is saved only once this has worked; otherwise
        // the fresh copy (which holds no edits yet) is removed and the next open downloads again.
        do {
            for (path, kind) in try changes().sorted(by: { $0.key < $1.key }) {
                let url = root.appending(path: path)
                guard isInside(url) else { continue }
                if kind == .added {
                    try? fm.removeItem(at: url)
                } else if let sha = files[path], modes[path] != "120000" {
                    let data = try await client.blob(ref.owner, ref.name, sha: sha)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                }
            }
            hashCache = [:]
            try saveState()
        } catch {
            state = nil
            hashCache = [:]
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Whether a file's folder, with links followed, is still inside the copy. A link committed to the repository
    /// must never let a sync write elsewhere on the Mac.
    func isInside(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return folder.hasPrefix(base)
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
        try await exclusive { try await publishNow(paths: paths, message: message, client: client) }
    }

    private func publishNow(paths: [String], message: String, client: GitHubClient) async throws -> String {
        guard state != nil else { throw SyncError.notDownloaded }
        for attempt in 0 ..< 3 {
            let outcome = try await pullNow(client: client)
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
        do {
            try await client.updateBranch(ref.owner, ref.name, branch: ref.branch, to: commit)
        } catch GitHubError.notFastForward {
            throw GitHubError.notFastForward
        } catch {
            // The answer can be lost after GitHub moved the branch, and GitHub can report the old head for a moment.
            // Ask again a few times; without an answer either way, nothing may be rolled back.
            var head: String?
            for attempt in 0 ..< 4 {
                head = try? await client.branchHead(ref.owner, ref.name, branch: ref.branch)
                if head == commit { break }
                if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
            }
            // GitHub answered with the old head: the publish was refused (a protected branch, a limit), so it is undone.
            // Only no answer at all leaves the outcome open.
            if head != commit { throw head == nil ? SyncError.unconfirmed : error }
        }
        state.pass(state.baseCommit)
        state.baseCommit = commit
        state.baseTree = tree
        state.files = newFiles
        for entry in entries { state.modes[entry.path] = entry.sha == nil ? nil : entry.mode }
        state.updated = Date()
        self.state = state
        // The branch has moved: a state file that cannot be written now is written by the next pull, and must not
        // make the caller undo a publish that is live.
        try? saveState()
        return commit
    }

    // MARK: Pull

    /// Brings in commits made elsewhere. Files changed only on GitHub are updated; files changed in both places are left
    /// as they are here and reported as conflicts.
    @discardableResult
    public func pull(client: GitHubClient) async throws -> PullOutcome {
        try await exclusive { try await pullNow(client: client) }
    }

    private func pullNow(client: GitHubClient) async throws -> PullOutcome {
        guard var state else { throw SyncError.notDownloaded }
        try await settleStaleConflicts(client: client)
        state = self.state ?? state
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        // An older head shortly after moving the branch is GitHub's lag. Long after, it is a real change: someone
        // reset the branch to an earlier commit.
        let lagging = (state.passed ?? []).contains(head) && Date().timeIntervalSince(state.updated) < 120
        guard head != state.baseCommit, !lagging else { return PullOutcome() }
        let commit = try await client.commit(ref.owner, ref.name, sha: head)
        let tree = try await client.tree(ref.owner, ref.name, sha: commit.tree.sha)
        // A partial list would read as files deleted on GitHub.
        guard !tree.truncated else { throw SyncError.tooLarge }
        var remote: [String: String] = [:]
        var remoteModes: [String: String] = [:]
        for entry in tree.tree where entry.type == "blob" {
            remote[entry.path] = entry.sha
            remoteModes[entry.path] = entry.mode
        }
        let local = try changes()
        var outcome = PullOutcome()
        // Removals first: on a disk that ignores case, a file renamed only in case on GitHub is the same file here,
        // and removing the old name after writing the new one would delete it.
        let paths = Set(state.files.keys).union(remote.keys).sorted { (remote[$0] != nil ? 1 : 0, $0) < (remote[$1] != nil ? 1 : 0, $1) }
        for path in paths {
            let old = state.files[path], new = remote[path]
            guard old != new else { continue }
            if local[path] != nil {
                let url = root.appending(path: path)
                let localSHA = (try? contents(url)).map(GitBlob.sha)
                if localSHA == new {
                    state.files[path] = new
                    state.conflicts[path] = nil
                } else {
                    state.conflicts[path] = .some(new)
                    outcome.conflicts.append(path)
                }
                continue
            }
            // The editor may have saved this file while GitHub's version was downloading: check again just before
            // writing, with no wait in between, and keep the edit as a conflict if so.
            var data: Data?
            if let new { data = try await client.blob(ref.owner, ref.name, sha: new) }
            hashCache[path] = nil
            let current = (try? contents(root.appending(path: path))).map(GitBlob.sha)
            if current != old, current != new {
                state.conflicts[path] = .some(new)
                outcome.conflicts.append(path)
                continue
            }
            try place(path: path, data: data)
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

    /// Conflicts that settled themselves: the file here now matches GitHub's, or the file here is gone and was never on
    /// GitHub before (a draft whose publish stopped on the conflict), so GitHub's version simply comes in.
    private func settleStaleConflicts(client: GitHubClient) async throws {
        guard var state, !state.conflicts.isEmpty else { return }
        for (path, remote) in state.conflicts {
            let url = root.appending(path: path)
            let localSHA = (try? contents(url)).map(GitBlob.sha)
            if localSHA == remote {
                state.files[path] = remote
                state.conflicts[path] = nil
            } else if localSHA == nil, state.files[path] == nil {
                try await write(path: path, sha: remote, client: client)
                state.files[path] = remote
                state.conflicts[path] = nil
            }
        }
        self.state = state
        try saveState()
    }

    private func write(path: String, sha: String?, client: GitHubClient) async throws {
        var data: Data?
        if let sha { data = try await client.blob(ref.owner, ref.name, sha: sha) }
        try place(path: path, data: data)
    }

    /// Writes GitHub's version of a file (or removes it when `data` is nil).
    private func place(path: String, data: Data?) throws {
        let url = root.appending(path: path)
        let fm = FileManager.default
        guard isInside(url) else { throw SyncError.extractFailed(path) }
        if let data {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fm.removeItem(at: url)
        }
        hashCache[path] = nil
    }

    // MARK: Conflicts and discarding

    /// Settles a conflict: keep this Mac's version (it publishes over GitHub's) or take GitHub's.
    public func resolve(path: String, keepMine: Bool, client: GitHubClient) async throws {
        try await exclusive { try await resolveNow(path: path, keepMine: keepMine, client: client) }
    }

    private func resolveNow(path: String, keepMine: Bool, client: GitHubClient) async throws {
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
    /// A conflicted file is put back to GitHub's version, which settles the conflict.
    public func discard(path: String, client: GitHubClient) async throws {
        try await exclusive {
            guard var state else { throw SyncError.notDownloaded }
            if let remote = state.conflicts[path] {
                try await write(path: path, sha: remote, client: client)
                state.files[path] = remote
                state.conflicts[path] = nil
                self.state = state
                try saveState()
            } else {
                try await write(path: path, sha: state.files[path], client: client)
            }
        }
    }

    func saveState() throws {
        guard let state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
