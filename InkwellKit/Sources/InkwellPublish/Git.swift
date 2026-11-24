import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var command: String
    public var output: String

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("Authentication failed") || detail.contains("could not read Username") {
            return "GitHub did not accept the saved sign-in for this repository. Push once from Terminal to save it, then try again."
        }
        if detail.contains("rejected") || detail.contains("non-fast-forward") {
            return "The site changed on GitHub since it was last fetched, and the changes could not be combined automatically."
        }
        return detail.isEmpty ? "git \(command) failed." : detail
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
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        self.root = root
        executable = URL(fileURLWithPath: path)
    }

    @discardableResult
    public func run(_ arguments: [String], allowFailure: Bool = false) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        environment["LC_ALL"] = "C"
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
    }

    /// Commits exactly `paths` (added, changed or removed) with `message`, brings in remote changes, and pushes.
    public func publish(paths: [String], message: String, push: Bool = true) async throws -> PublishResult {
        precondition(!paths.isEmpty)
        try await run(["add", "--all", "--"] + paths)
        try await run(["commit", "-m", message, "--only", "--"] + paths)
        let branch = try await currentBranch()
        var pushed = false
        if push, await remoteURL() != nil {
            try await run(["fetch", "origin", branch], allowFailure: true)
            let behind = try await run(["rev-list", "--count", "HEAD..origin/\(branch)"], allowFailure: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(behind), n > 0 {
                try await run(["pull", "--rebase", "--autostash", "origin", branch])
            }
            try await run(["push", "origin", "HEAD:\(branch)"])
            pushed = true
        }
        return try await PublishResult(commit: head(), branch: branch, pushed: pushed)
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
