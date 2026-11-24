import Foundation

public enum GitHubError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case notFound(String)
    case rateLimited(reset: Date?)
    case notFastForward
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub did not accept the sign-in. Sign in again."
        case let .notFound(what): "GitHub could not find \(what), or this account cannot see it."
        case let .rateLimited(reset):
            if let reset { "GitHub’s rate limit was reached. Try again after \(reset.formatted(date: .omitted, time: .shortened))." }
            else { "GitHub’s rate limit was reached. Try again in a few minutes." }
        case .notFastForward: "The site changed on GitHub while publishing."
        case let .http(status, message): "GitHub answered \(status): \(message)"
        case let .network(message): "Could not reach GitHub: \(message)"
        case let .decoding(message): "GitHub sent something unexpected: \(message)"
        }
    }
}

/// The GitHub REST calls Inkwell needs, with the signed-in person's token. Uses URLSession only.
public struct GitHubClient: Sendable {
    public var token: String
    public var baseURL: URL
    var session: URLSession

    public init(token: String, baseURL: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Transport

    public func data(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable & Sendable)? = nil,
                     accept: String = "application/vnd.github+json") async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Inkwell", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.network("No HTTP response.") }
        guard (200 ..< 300).contains(http.statusCode) else { throw Self.error(for: http, data: data, path: path) }
        return (data, http)
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String, query: [String: String] = [:],
                                   body: (any Encodable & Sendable)? = nil) async throws -> T {
        let (data, _) = try await self.data(method, path, query: query, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding("\(path): \(error)")
        }
    }

    static func error(for http: HTTPURLResponse, data: Data, path: String) -> GitHubError {
        let message = (try? JSONDecoder().decode(APIMessage.self, from: data))?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch http.statusCode {
        case 401: return .unauthorized
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                return .rateLimited(reset: reset)
            }
            return .http(status: http.statusCode, message: message)
        case 404: return .notFound(path)
        case 409 where message.localizedCaseInsensitiveContains("empty"): return .notFound("the repository’s files (it is empty)")
        case 422 where message.localizedCaseInsensitiveContains("fast forward"): return .notFastForward
        default: return .http(status: http.statusCode, message: message)
        }
    }

    struct APIMessage: Decodable { var message: String }

    // MARK: Account and repositories

    public func user() async throws -> GitHubUser {
        try await json(GitHubUser.self, "GET", "user")
    }

    /// Scopes granted to a classic or OAuth token, from the `x-oauth-scopes` header (empty for fine-grained tokens).
    public func scopes() async throws -> [String] {
        let (_, http) = try await data("GET", "user")
        return (http.value(forHTTPHeaderField: "x-oauth-scopes") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Every repository the person owns or collaborates on, newest push first.
    public func repositories() async throws -> [GitHubRepo] {
        var all: [GitHubRepo] = []
        for page in 1 ... 10 {
            let batch = try await json([GitHubRepo].self, "GET", "user/repos", query: [
                "per_page": "100", "page": "\(page)", "sort": "pushed", "affiliation": "owner,collaborator",
            ])
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    public func repository(_ owner: String, _ name: String) async throws -> GitHubRepo {
        try await json(GitHubRepo.self, "GET", "repos/\(owner)/\(name)")
    }

    public func createRepository(name: String, description: String, isPrivate: Bool) async throws -> GitHubRepo {
        try await json(GitHubRepo.self, "POST", "user/repos", body: CreateRepo(name: name, description: description, private: isPrivate, auto_init: true))
    }

    struct CreateRepo: Encodable { var name: String; var description: String; var `private`: Bool; var auto_init: Bool }

    // MARK: Pages

    /// The Pages site for a repository, or nil when Pages is not turned on.
    public func pages(_ owner: String, _ name: String) async throws -> GitHubPages? {
        do {
            return try await json(GitHubPages.self, "GET", "repos/\(owner)/\(name)/pages")
        } catch GitHubError.notFound {
            return nil
        }
    }

    public func enablePages(_ owner: String, _ name: String, branch: String, path: String = "/") async throws -> GitHubPages {
        try await json(GitHubPages.self, "POST", "repos/\(owner)/\(name)/pages", body: EnablePages(source: .init(branch: branch, path: path)))
    }

    struct EnablePages: Encodable {
        struct Source: Encodable { var branch: String; var path: String }
        var source: Source
    }

    public func updatePages(_ owner: String, _ name: String, cname: String?, httpsEnforced: Bool?) async throws {
        _ = try await data("PUT", "repos/\(owner)/\(name)/pages", body: UpdatePages(cname: cname, https_enforced: httpsEnforced))
    }

    struct UpdatePages: Encodable { var cname: String?; var https_enforced: Bool? }

    public func workflowRuns(_ owner: String, _ name: String, headSHA: String) async throws -> [GitHubWorkflowRun] {
        try await json(WorkflowRuns.self, "GET", "repos/\(owner)/\(name)/actions/runs", query: ["head_sha": headSHA, "per_page": "20"]).workflow_runs
    }

    struct WorkflowRuns: Decodable { var workflow_runs: [GitHubWorkflowRun] }

    // MARK: Git data

    public func branchHead(_ owner: String, _ name: String, branch: String) async throws -> String {
        try await json(GitRef.self, "GET", "repos/\(owner)/\(name)/git/ref/heads/\(branch)").object.sha
    }

    public func commit(_ owner: String, _ name: String, sha: String) async throws -> GitCommit {
        try await json(GitCommit.self, "GET", "repos/\(owner)/\(name)/git/commits/\(sha)")
    }

    public func tree(_ owner: String, _ name: String, sha: String) async throws -> GitTree {
        try await json(GitTree.self, "GET", "repos/\(owner)/\(name)/git/trees/\(sha)", query: ["recursive": "1"])
    }

    public func blob(_ owner: String, _ name: String, sha: String) async throws -> Data {
        try await data("GET", "repos/\(owner)/\(name)/git/blobs/\(sha)", accept: "application/vnd.github.raw+json").0
    }

    /// The repository's files at `ref` as a gzipped tarball.
    public func tarball(_ owner: String, _ name: String, ref: String) async throws -> Data {
        try await data("GET", "repos/\(owner)/\(name)/tarball/\(ref)").0
    }

    public func createBlob(_ owner: String, _ name: String, data blob: Data) async throws -> String {
        try await json(SHAOnly.self, "POST", "repos/\(owner)/\(name)/git/blobs",
                       body: NewBlob(content: blob.base64EncodedString(), encoding: "base64")).sha
    }

    struct NewBlob: Encodable { var content: String; var encoding: String }

    /// A new tree on top of `base`. Entries with a nil sha delete the path.
    public func createTree(_ owner: String, _ name: String, base: String, entries: [TreeEntryChange]) async throws -> String {
        try await json(SHAOnly.self, "POST", "repos/\(owner)/\(name)/git/trees", body: NewTree(base_tree: base, tree: entries)).sha
    }

    struct NewTree: Encodable { var base_tree: String; var tree: [TreeEntryChange] }

    public func createCommit(_ owner: String, _ name: String, message: String, tree: String, parents: [String]) async throws -> String {
        try await json(SHAOnly.self, "POST", "repos/\(owner)/\(name)/git/commits", body: NewCommit(message: message, tree: tree, parents: parents)).sha
    }

    struct NewCommit: Encodable { var message: String; var tree: String; var parents: [String] }

    /// Moves the branch to `sha` only if that is a fast-forward; otherwise throws `notFastForward`.
    public func updateBranch(_ owner: String, _ name: String, branch: String, to sha: String) async throws {
        _ = try await data("PATCH", "repos/\(owner)/\(name)/git/refs/heads/\(branch)", body: UpdateRef(sha: sha, force: false))
    }

    struct UpdateRef: Encodable { var sha: String; var force: Bool }

    struct SHAOnly: Decodable { var sha: String }
}

// MARK: Models

public struct GitHubUser: Decodable, Sendable, Equatable {
    public var login: String
    public var name: String?
    public var avatar_url: String?
}

public struct GitHubRepo: Decodable, Sendable, Equatable, Identifiable {
    public struct Owner: Decodable, Sendable, Equatable { public var login: String }

    public var id: Int
    public var name: String
    public var full_name: String
    public var owner: Owner
    public var `private`: Bool
    public var has_pages: Bool?
    public var default_branch: String?
    public var pushed_at: String?
    public var description: String?
    public var permissions: Permissions?

    public struct Permissions: Decodable, Sendable, Equatable { public var push: Bool? }

    public var isUserSite: Bool { name.lowercased() == "\(owner.login.lowercased()).github.io" }
    public var canPush: Bool { permissions?.push ?? true }
}

public struct GitHubPages: Decodable, Sendable, Equatable {
    public struct Source: Decodable, Sendable, Equatable {
        public var branch: String
        public var path: String
    }

    public var html_url: String?
    public var status: String?
    public var cname: String?
    public var build_type: String?
    public var https_enforced: Bool?
    public var source: Source?

    /// The folder the site is built from: "" for the repository root, "docs" for /docs.
    public var sitePath: String {
        let path = source?.path ?? "/"
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct GitHubWorkflowRun: Decodable, Sendable, Equatable {
    public var name: String?
    public var status: String
    public var conclusion: String?
    public var html_url: String?
}

public struct GitRef: Decodable, Sendable {
    public struct Object: Decodable, Sendable { public var sha: String }
    public var object: Object
}

public struct GitCommit: Decodable, Sendable {
    public struct TreeRef: Decodable, Sendable { public var sha: String }
    public var sha: String
    public var tree: TreeRef
}

public struct GitTree: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var path: String
        public var mode: String
        public var type: String
        public var sha: String
        public var size: Int?
    }

    public var sha: String
    public var tree: [Entry]
    public var truncated: Bool
}

public struct TreeEntryChange: Encodable, Sendable, Equatable {
    public var path: String
    public var mode: String
    public var type: String
    public var sha: String?

    public init(path: String, sha: String?, mode: String = "100644") {
        self.path = path
        self.mode = mode
        type = "blob"
        self.sha = sha
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(mode, forKey: .mode)
        try c.encode(type, forKey: .type)
        // A null sha deletes the path; it has to be sent explicitly.
        if let sha { try c.encode(sha, forKey: .sha) } else { try c.encodeNil(forKey: .sha) }
    }

    enum CodingKeys: String, CodingKey { case path, mode, type, sha }
}
