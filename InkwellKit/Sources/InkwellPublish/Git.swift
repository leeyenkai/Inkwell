import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var command: String
    public var output: String

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("Authentication failed") || detail.contains("could not read Username") {
            return localized("GitHub did not accept the saved sign-in for this repository. Push once from Terminal to save it, then try again.")
        }
        if detail.contains("rejected") || detail.contains("non-fast-forward") {
            return localized("The site changed on GitHub since it was last fetched, and the changes could not be combined automatically.")
        }
        return detail.isEmpty ? localized("git \(command) failed.") : detail
    }
}

public enum FileStatus: Sendable, Hashable {
    case modified
    case added
    case untracked
    case deleted
    case renamed
}

/// The git commands Inkwell needs, run with the person's own git and credentials. Publishing always names the files
/// it commits, so other uncommitted work in the clone is never swept into a publish.
public struct Git: Sendable {
    public let root: URL
    public let executable: URL

    public init?(root: URL) {
        // /usr/bin/git is only a stub that offers to install the developer tools unless they are present.
        let toolsInstalled = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"] + (toolsInstalled ? ["/usr/bin/git"] : [])
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        self.root = root
        executable = URL(fileURLWithPath: path)
    }

    @discardableResult
    public func run(_ arguments: [String], allowFailure: Bool = false, timeout: TimeInterval = 120) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        environment["LC_ALL"] = "C"
        // Background status checks must not take the index lock while a publish is committing.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { output.append(data) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = String(decoding: output.data, as: UTF8.self)
                if finished.terminationStatus == 0 || allowFailure {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: GitError(command: arguments.first ?? "", output: text))
                }
            }
            do {
                try process.run()
                // A credential or passphrase prompt would wait forever; stop it instead.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                    if process.isRunning { process.terminate() }
                }
            } catch {
                continuation.resume(throwing: GitError(command: arguments.first ?? "", output: error.localizedDescription))
            }
        }
    }

    public func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "true"
    }

    /// Status by path relative to the root.
    public func status() async throws -> [String: FileStatus] {
        let out = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        var result: [String: FileStatus] = [:]
        var entries = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst(), entry.count > 3 {
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            switch code {
            case "??": result[path] = .untracked
            case _ where code.contains("R"):
                result[path] = .renamed
                _ = entries.popFirst()
            case _ where code.contains("D"): result[path] = .deleted
            case _ where code.contains("A"): result[path] = .added
            default: result[path] = .modified
            }
        }
        return result
    }

    public func currentBranch() async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func head() async throws -> String {
        try await run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func remoteURL() async -> String? {
        let url = try? await run(["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return url?.isEmpty == false ? url : nil
    }

    /// The last commit date for each file, for the "edited 2h ago" line. One git call for the whole folder.
    public func lastCommitDates(in folder: String) async -> [String: Date] {
        guard let out = try? await run(["log", "--format=%x00%ct", "--name-only", "--", folder]) else { return [:] }
        var result: [String: Date] = [:]
        for chunk in out.components(separatedBy: "\0") where !chunk.isEmpty {
            let lines = chunk.split(separator: "\n").map(String.init)
            guard let stamp = lines.first.flatMap(TimeInterval.init) else { continue }
            for path in lines.dropFirst() where result[path] == nil { result[path] = Date(timeIntervalSince1970: stamp) }
        }
        return result
    }

    public struct PublishResult: Sendable {
        public var commit: String
        public var branch: String
        public var pushed: Bool
        /// Why the push failed, when the commit was made but could not be pushed.
        public var pushError: String?
    }

    /// Commits exactly `paths` (added, changed or removed) with `message`, then tries to push. A failed push does not
    /// throw: the commit is kept and `pushError` says why, so the app can offer to push again.
    public func publish(paths: [String], message: String, push: Bool = true) async throws -> PublishResult {
        precondition(!paths.isEmpty)
        let earlierUnpushed = await unpushedCount()
        // A file git could not merge still holds conflict markers; publishing it would put them live.
        let here = await prefix()
        let unmerged = Set(await unmerged()).intersection(paths.map { here + $0 })
        guard unmerged.isEmpty else {
            let names = unmerged.sorted().joined(separator: ", ")
            throw GitError(command: "commit", output: localized("These files still have unresolved git conflicts: \(names). Settle them with git first."))
        }
        try await run(["add", "--all", "--"] + paths)
        do {
            try await run(["commit", "-m", message, "--only", "--"] + paths)
        } catch {
            _ = try? await run(["reset", "-q", "--"] + paths, allowFailure: true)
            throw error
        }
        let branch = try await currentBranch()
        var pushed = false
        var pushError: String?
        // Pushing sends every commit not yet on GitHub. Commits made here outside the app (work in progress, say) must
        // not go live with a post, so those wait for an explicit Push.
        if push, earlierUnpushed > 0 {
            pushError = localized("""
                \(earlierUnpushed) earlier commits in this folder are not on GitHub yet, so nothing was pushed. \
                Push when they are ready to go live.
                """)
        } else if push, await remoteURL() != nil {
            do {
                try await self.push()
                pushed = true
            } catch {
                pushError = error.localizedDescription
            }
        }
        return try await PublishResult(commit: head(), branch: branch, pushed: pushed, pushError: pushError)
    }

    /// Brings in remote commits (rebasing local ones on top) and pushes. A rebase that stops on a conflict is
    /// undone, so the folder is never left half-way through one.
    public func push() async throws {
        let branch = try await currentBranch()
        try await run(["fetch", "origin", branch], allowFailure: true)
        let behind = try await run(["rev-list", "--count", "HEAD..origin/\(branch)"], allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(behind), n > 0 {
            try await refuseOverlap(branch: branch)
            do {
                try await run(["pull", "--rebase", "--autostash", "origin", branch])
            } catch {
                _ = try? await run(["rebase", "--abort"], allowFailure: true)
                throw GitError(command: "pull", output: "rejected: the site changed on GitHub in the same files. \(error.localizedDescription)")
            }
        }
        try await run(["push", "origin", "HEAD:\(branch)"])
    }

    /// Uncommitted edits in files GitHub also changed would come back from the autostash as conflict markers, and the
    /// next publish would put those live. Such a pull is refused, leaving everything as it is.
    public func refuseOverlap(branch: String) async throws {
        let incoming = try await run(["diff", "--name-only", "-z", "HEAD...origin/\(branch)"])
            .split(separator: "\0").map { String($0) }
        // Both lists are relative to the top of the repository.
        let dirty = try await status().keys
        let both = Set(incoming).intersection(dirty).sorted()
        guard both.isEmpty else {
            let names = both.joined(separator: ", ")
            throw GitError(command: "pull", output: localized("""
                Changed here and on GitHub: \(names). Publish or discard those edits, or settle them with git, then try again.
                """))
        }
    }

    /// Files git could not merge, with conflict markers in them.
    public func unmerged() async -> [String] {
        let out = (try? await run(["diff", "--name-only", "-z", "--diff-filter=U"], allowFailure: true)) ?? ""
        return out.split(separator: "\0").map(String.init)
    }

    /// Commits made here that are not on the remote yet.
    public func unpushedCount() async -> Int {
        guard let branch = try? await currentBranch(),
              let out = try? await run(["rev-list", "--count", "origin/\(branch)..HEAD"], allowFailure: true) else { return 0 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The folder's path inside the repository ("" at the top, "docs/" for a site in /docs).
    public func prefix() async -> String {
        (try? await run(["rev-parse", "--show-prefix"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    /// Puts a file back as it was in the last commit, or removes it if it was never committed.
    public func discard(path: String) async throws {
        let tracked = (try? await run(["ls-files", "--error-unmatch", "--", path])) != nil
        if tracked {
            try await run(["checkout", "HEAD", "--", path])
        } else {
            try FileManager.default.removeItem(at: root.appending(path: path))
        }
    }

    /// `owner/repo` when the remote is on GitHub.
    public static func gitHubRepository(from remote: String) -> (owner: String, name: String)? {
        let patterns = [#"github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: remote, range: NSRange(location: 0, length: (remote as NSString).length)) else { continue }
            let ns = remote as NSString
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
        }
        return nil
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
