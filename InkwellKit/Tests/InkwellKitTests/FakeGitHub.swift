// The fake server reads its own well-formed requests, so force casts keep it short.
// swiftlint:disable force_cast force_try
import Foundation
@testable import InkwellGitHub
@testable import InkwellSync

/// A small in-memory GitHub: one repository with refs, commits, trees and blobs, the tarball endpoint, the
/// Git Data API used for publishing, and the device-flow login endpoints. Served through `URLProtocol`.
final class FakeGitHub: @unchecked Sendable {
    let lock = NSLock()
    var blobs: [String: Data] = [:]
    var trees: [String: [String: (mode: String, sha: String)]] = [:]
    var commits: [String: (tree: String, parents: [String], message: String)] = [:]
    var head: String = ""
    var requests: [String] = []
    var devicePolls = 0
    let owner = "octo", repo = "octo.github.io"

    init(files: [String: String]) {
        var entries: [String: (String, String)] = [:]
        for (path, text) in files {
            let data = Data(text.utf8)
            let sha = GitBlob.sha(data)
            blobs[sha] = data
            entries[path] = ("100644", sha)
        }
        let tree = storeTree(entries)
        head = storeCommit(tree: tree, parents: [], message: "init")
    }

    func storeTree(_ entries: [String: (mode: String, sha: String)]) -> String {
        let listing = entries.keys.sorted().map { "\($0) \(entries[$0]!.sha)" }.joined(separator: "\n")
        let sha = GitBlob.sha(Data(("tree\n" + listing).utf8))
        trees[sha] = entries
        return sha
    }

    func storeCommit(tree: String, parents: [String], message: String) -> String {
        let sha = GitBlob.sha(Data("commit \(tree) \(parents) \(message) \(UUID())".utf8))
        commits[sha] = (tree, parents, message)
        return sha
    }

    /// What GitHub's branch holds now.
    func files(at commit: String? = nil) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let tree = trees[commits[commit ?? head]!.tree]!
        return tree.mapValues { String(decoding: blobs[$0.sha]!, as: UTF8.self) }
    }

    /// Someone edits the site on github.com.
    func remoteEdit(_ changes: [String: String?], message: String = "web edit") {
        lock.lock()
        defer { lock.unlock() }
        var entries = trees[commits[head]!.tree]!
        for (path, text) in changes {
            if let text {
                let data = Data(text.utf8)
                let sha = GitBlob.sha(data)
                blobs[sha] = data
                entries[path] = ("100644", sha)
            } else {
                entries[path] = nil
            }
        }
        head = storeCommit(tree: storeTree(entries), parents: [head], message: message)
    }

    // MARK: Routing

    func respond(to request: URLRequest) -> (Int, Data, [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        requests.append("\(method) \(url.path)")
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let parts = url.path.split(separator: "/").map(String.init)

        if url.host == "github.com" {
            let form = String(decoding: body, as: UTF8.self)
            if url.path.hasSuffix("device/code") {
                return ok(["device_code": "dev", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
                           "expires_in": 900, "interval": 0])
            }
            if url.path.hasSuffix("access_token"), form.contains("device_code=dev") {
                devicePolls += 1
                return devicePolls < 2 ? ok(["error": "authorization_pending"]) : ok(["access_token": "gho_test", "token_type": "bearer"])
            }
            return (404, Data(), [:])
        }
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer good" {
            return (401, Data(#"{"message":"Bad credentials"}"#.utf8), [:])
        }
        guard parts.count >= 3, parts[0] == "repos" else {
            if url.path == "/user" { return ok(["login": owner, "name": "Octo"]) }
            return (404, Data(), [:])
        }
        let rest = Array(parts.dropFirst(3))
        switch (method, rest.first, rest.dropFirst().first) {
        case ("GET", "git", "ref"):
            return ok(["object": ["sha": head]])
        case ("GET", "git", "commits"):
            let sha = rest[2]
            return ok(["sha": sha, "tree": ["sha": commits[sha]!.tree]])
        case ("GET", "git", "trees"):
            let sha = rest[2]
            let entries = trees[sha]!.map { ["path": $0.key, "mode": $0.value.mode, "type": "blob", "sha": $0.value.sha,
                                             "size": blobs[$0.value.sha]!.count] as [String: Any] }
            return ok(["sha": sha, "tree": entries, "truncated": false])
        case ("GET", "git", "blobs"):
            return (200, blobs[rest[2]]!, [:])
        case ("GET", "tarball", _):
            return (200, tarball(commit: rest[1]), [:])
        case ("POST", "git", "blobs"):
            let data = Data(base64Encoded: json["content"] as! String)!
            let sha = GitBlob.sha(data)
            blobs[sha] = data
            return ok(["sha": sha])
        case ("POST", "git", "trees"):
            var entries = trees[json["base_tree"] as! String]!
            for item in json["tree"] as! [[String: Any]] {
                let path = item["path"] as! String
                if let sha = item["sha"] as? String { entries[path] = (item["mode"] as! String, sha) } else { entries[path] = nil }
            }
            return ok(["sha": storeTree(entries)])
        case ("POST", "git", "commits"):
            let sha = storeCommit(tree: json["tree"] as! String, parents: json["parents"] as! [String], message: json["message"] as! String)
            return ok(["sha": sha])
        case ("PATCH", "git", "refs"):
            let sha = json["sha"] as! String
            guard commits[sha]?.parents.contains(head) == true else {
                return (422, Data(#"{"message":"Update is not a fast forward"}"#.utf8), [:])
            }
            head = sha
            return ok(["object": ["sha": sha]])
        default:
            return (404, Data(#"{"message":"Not Found"}"#.utf8), [:])
        }
    }

    func ok(_ object: Any) -> (Int, Data, [String: String]) {
        (200, try! JSONSerialization.data(withJSONObject: object), ["Content-Type": "application/json"])
    }

    func tarball(commit: String) -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "fake-tar-\(UUID().uuidString)")
        let top = dir.appending(path: "\(owner)-\(repo)-\(commit.prefix(7))")
        for (path, entry) in trees[commits[commit]!.tree]! {
            let url = top.appending(path: path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? blobs[entry.sha]!.write(to: url)
        }
        let out = dir.appending(path: "out.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", out.path, "-C", dir.path, top.lastPathComponent]
        try? process.run()
        process.waitUntilExit()
        defer { try? fm.removeItem(at: dir) }
        return (try? Data(contentsOf: out)) ?? Data()
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    // MARK: Session

    nonisolated(unsafe) static var current: FakeGitHub?

    func session() -> URLSession {
        FakeGitHub.current = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHubProtocol.self]
        return URLSession(configuration: config)
    }

    func client(token: String = "good") -> GitHubClient {
        GitHubClient(token: token, session: session())
    }
}

final class FakeGitHubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = FakeGitHub.current else { return }
        let (status, data, headers) = server.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
