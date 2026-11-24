import Foundation
@testable import InkwellGitHub
@testable import InkwellSync
import XCTest

/// Writes to a real GitHub repository. Skipped unless INKWELL_LIVE_TOKEN and INKWELL_LIVE_WRITE_REPO (owner/name) are set.
/// Point it only at a throwaway repository: it adds, edits and deletes files there.
final class LivePublishTests: XCTestCase {
    var client: GitHubClient!
    var ref: SiteRef!
    var container: URL!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["INKWELL_LIVE_TOKEN"], let repo = env["INKWELL_LIVE_WRITE_REPO"]?.split(separator: "/"), repo.count == 2 else {
            throw XCTSkip("Set INKWELL_LIVE_TOKEN and INKWELL_LIVE_WRITE_REPO to run.")
        }
        client = GitHubClient(token: token)
        let info = try await client.repository(String(repo[0]), String(repo[1]))
        ref = SiteRef(owner: String(repo[0]), name: String(repo[1]), branch: info.default_branch ?? "main")
        container = FileManager.default.temporaryDirectory.appending(path: "inkwell-live-write-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        if let container { try? FileManager.default.removeItem(at: container) }
    }

    func write(_ copy: WorkingCopy, _ path: String, _ data: Data) throws {
        let url = copy.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ copy: WorkingCopy, _ path: String) -> String? {
        try? String(contentsOf: copy.root.appending(path: path), encoding: .utf8)
    }

    /// GitHub's current version of a file, or nil when it is not there.
    func remote(_ path: String) async throws -> String? {
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        let tree = try await client.tree(ref.owner, ref.name, sha: client.commit(ref.owner, ref.name, sha: head).tree.sha)
        guard let entry = tree.tree.first(where: { $0.path == path }) else { return nil }
        return try await String(decoding: client.blob(ref.owner, ref.name, sha: entry.sha), as: UTF8.self)
    }

    /// An edit made somewhere else (as if on github.com), straight through the API.
    func editOnGitHub(_ path: String, _ text: String) async throws {
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        let commit = try await client.commit(ref.owner, ref.name, sha: head)
        let blob = try await client.createBlob(ref.owner, ref.name, data: Data(text.utf8))
        let tree = try await client.createTree(ref.owner, ref.name, base: commit.tree.sha, entries: [TreeEntryChange(path: path, sha: blob)])
        let new = try await client.createCommit(ref.owner, ref.name, message: "Edit \(path) elsewhere", tree: tree, parents: [head])
        try await client.updateBranch(ref.owner, ref.name, branch: ref.branch, to: new)
    }

    func testFullPublishingCycle() async throws {
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let post = "_posts/2026-11-24-live-\(run).md"
        let image = "assets/images/live-\(run).png"
        let copy = WorkingCopy(ref: ref, container: container)
        try await copy.download(client: client)
        var changes = try await copy.changes()
        XCTAssertEqual(changes, [:])

        // 1. A small site, with a binary file, in one publish.
        try write(copy, "_config.yml", Data("title: \"Inkwell live test\"\npermalink: pretty\n".utf8))
        try write(copy, "index.md", Data("---\nlayout: default\ntitle: Home\n---\n\nRun \(run).\n".utf8))
        try write(copy, post, Data("---\ntitle: \"Live \(run)\"\ndate: 2026-11-24\n---\n\nFirst version.\n".utf8))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try write(copy, image, png)
        changes = try await copy.changes()
        let seeded = try await copy.publish(paths: changes.keys.sorted(), message: "Inkwell live test \(run): seed", client: client)
        let head = try await client.branchHead(ref.owner, ref.name, branch: ref.branch)
        XCTAssertEqual(head, seeded)
        let remotePost = try await remote(post)
        XCTAssertEqual(remotePost, "---\ntitle: \"Live \(run)\"\ndate: 2026-11-24\n---\n\nFirst version.\n")
        let remoteImage = try await client.tree(ref.owner, ref.name, sha: client.commit(ref.owner, ref.name, sha: head).tree.sha)
            .tree.first { $0.path == image }
        XCTAssertEqual(remoteImage?.sha, GitBlob.sha(png), "binary files arrive byte for byte")
        changes = try await copy.changes()
        XCTAssertEqual(changes, [:])

        // 2. Someone edits index.md on GitHub while a post is edited here: publishing the post brings that edit in.
        try await editOnGitHub("index.md", "---\nlayout: default\ntitle: Home\n---\n\nEdited on GitHub \(run).\n")
        try write(copy, post, Data("---\ntitle: \"Live \(run)\"\ndate: 2026-11-24\n---\n\nSecond version.\n".utf8))
        _ = try await copy.publish(paths: [post], message: "Inkwell live test \(run): update", client: client)
        XCTAssertEqual(read(copy, "index.md"), "---\nlayout: default\ntitle: Home\n---\n\nEdited on GitHub \(run).\n")
        let updated = try await remote(post)
        XCTAssertEqual(updated?.contains("Second version."), true)
        let index = try await remote("index.md")
        XCTAssertEqual(index?.contains("Edited on GitHub"), true, "the GitHub edit survived")

        // 3. The same post changed in both places is a conflict, never a silent overwrite.
        try await editOnGitHub(post, "---\ntitle: \"Live \(run)\"\ndate: 2026-11-24\n---\n\nGitHub's version.\n")
        try write(copy, post, Data("---\ntitle: \"Live \(run)\"\ndate: 2026-11-24\n---\n\nThis Mac's version.\n".utf8))
        do {
            _ = try await copy.publish(paths: [post], message: "Inkwell live test \(run): conflict", client: client)
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? SyncError, .conflict([post]))
        }
        let theirs = try await copy.remoteVersion(of: post, client: client)
        XCTAssertEqual(theirs.map { String(decoding: $0, as: UTF8.self).contains("GitHub's version.") }, true)
        try await copy.resolve(path: post, keepMine: true, client: client)
        _ = try await copy.publish(paths: [post], message: "Inkwell live test \(run): keep mine", client: client)
        let kept = try await remote(post)
        XCTAssertEqual(kept?.contains("This Mac's version."), true)

        // 4. Deleting.
        try FileManager.default.removeItem(at: copy.root.appending(path: post))
        try FileManager.default.removeItem(at: copy.root.appending(path: image))
        _ = try await copy.publish(paths: [post, image], message: "Inkwell live test \(run): delete", client: client)
        let gone = try await remote(post)
        XCTAssertNil(gone)
        changes = try await copy.changes()
        XCTAssertEqual(changes, [:])

        // 5. A second copy downloaded now matches exactly.
        let fresh = WorkingCopy(ref: ref, container: container.appending(path: "fresh", directoryHint: .isDirectory))
        try await fresh.download(client: client)
        let freshChanges = try await fresh.changes()
        XCTAssertEqual(freshChanges, [:])
        XCTAssertEqual(try String(contentsOf: fresh.root.appending(path: "index.md"), encoding: .utf8), read(copy, "index.md"))
    }
}
