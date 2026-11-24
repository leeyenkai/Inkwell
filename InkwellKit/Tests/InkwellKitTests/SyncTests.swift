import Foundation
@testable import InkwellGitHub
@testable import InkwellSync
import XCTest

final class GitHubClientTests: XCTestCase {
    func testBlobSHAMatchesGit() {
        XCTAssertEqual(GitBlob.sha(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertEqual(GitBlob.sha(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    func testDeletingTreeEntryEncodesNullSHA() throws {
        let json = String(decoding: try JSONEncoder().encode(TreeEntryChange(path: "a.md", sha: nil)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sha\":null"))
    }

    func testErrorsAreMapped() async {
        let fake = FakeGitHub(files: ["a.md": "x"])
        do {
            _ = try await fake.client(token: "bad").user()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? GitHubError, .unauthorized)
        }
        let user = try? await fake.client().user()
        XCTAssertEqual(user?.login, "octo")
    }

    func testDeviceFlow() async throws {
        let fake = FakeGitHub(files: [:])
        let flow = DeviceFlow(clientID: "client", session: fake.session())
        let code = try await flow.start()
        XCTAssertEqual(code.user_code, "ABCD-1234")
        let token = try await flow.waitForToken(code, minimumInterval: 0)
        XCTAssertEqual(token, "gho_test")
        XCTAssertEqual(fake.devicePolls, 2)
    }
}

final class WorkingCopyTests: XCTestCase {
    var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appending(path: "inkwell-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func make(_ files: [String: String]) async throws -> (FakeGitHub, WorkingCopy, GitHubClient) {
        let fake = FakeGitHub(files: files)
        let copy = WorkingCopy(ref: SiteRef(owner: fake.owner, name: fake.repo, branch: "main"), container: container)
        let client = fake.client()
        try await copy.download(client: client)
        return (fake, copy, client)
    }

    func write(_ copy: WorkingCopy, _ path: String, _ text: String) throws {
        let url = copy.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ copy: WorkingCopy, _ path: String) -> String? {
        try? String(contentsOf: copy.root.appending(path: path), encoding: .utf8)
    }

    func testDownloadAndDetectChanges() async throws {
        let (_, copy, _) = try await make(["_notes/a.md": "A\n", "index.md": "Home\n", ".nojekyll": ""])
        XCTAssertEqual(read(copy, "_notes/a.md"), "A\n")
        var changes = try await copy.changes()
        XCTAssertEqual(changes, [:])
        try write(copy, "_notes/a.md", "A changed\n")
        try write(copy, "_notes/b.md", "B\n")
        try write(copy, ".DS_Store", "junk")
        try FileManager.default.removeItem(at: copy.root.appending(path: "index.md"))
        changes = try await copy.changes()
        XCTAssertEqual(changes, ["_notes/a.md": .modified, "_notes/b.md": .added, "index.md": .deleted])
    }

    func testPublishCommitsOnlyNamedPaths() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n", "index.md": "Home\n"])
        try write(copy, "_notes/b.md", "New post\n")
        try write(copy, "assets/images/b.jpg", "jpeg")
        try write(copy, "index.md", "Home, edited but not published\n")
        let commit = try await copy.publish(paths: ["_notes/b.md", "assets/images/b.jpg"], message: "Publish: B", client: client)
        XCTAssertEqual(fake.head, commit)
        let remote = fake.files()
        XCTAssertEqual(remote["_notes/b.md"], "New post\n")
        XCTAssertEqual(remote["assets/images/b.jpg"], "jpeg")
        XCTAssertEqual(remote["index.md"], "Home\n")
        let changes = try await copy.changes()
        XCTAssertEqual(changes, ["index.md": .modified])
        do {
            _ = try await copy.publish(paths: ["_notes/b.md"], message: "again", client: client)
            XCTFail("expected nothing to publish")
        } catch {
            XCTAssertEqual(error as? SyncError, .nothingToPublish)
        }
    }

    func testDeletingAPublishedFile() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n", "index.md": "Home\n"])
        try FileManager.default.removeItem(at: copy.root.appending(path: "_notes/a.md"))
        _ = try await copy.publish(paths: ["_notes/a.md"], message: "Delete: A", client: client)
        XCTAssertNil(fake.files()["_notes/a.md"])
        XCTAssertEqual(fake.files()["index.md"], "Home\n")
    }

    func testPublishPullsOtherChangesFirst() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n", "index.md": "Home\n"])
        fake.remoteEdit(["index.md": "Home, edited on GitHub\n", "about.md": "About\n"])
        try write(copy, "_notes/a.md", "A, edited here\n")
        _ = try await copy.publish(paths: ["_notes/a.md"], message: "Update: A", client: client)
        let remote = fake.files()
        XCTAssertEqual(remote["_notes/a.md"], "A, edited here\n")
        XCTAssertEqual(remote["index.md"], "Home, edited on GitHub\n")
        XCTAssertEqual(read(copy, "index.md"), "Home, edited on GitHub\n")
        XCTAssertEqual(read(copy, "about.md"), "About\n")
        let changes = try await copy.changes()
        XCTAssertEqual(changes, [:])
    }

    func testConflictsMustBeResolved() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n"])
        fake.remoteEdit(["_notes/a.md": "A from GitHub\n"])
        try write(copy, "_notes/a.md", "A from this Mac\n")
        do {
            _ = try await copy.publish(paths: ["_notes/a.md"], message: "Update", client: client)
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? SyncError, .conflict(["_notes/a.md"]))
        }
        let conflicts = await copy.conflicts
        XCTAssertEqual(conflicts, ["_notes/a.md"])
        let theirs = try await copy.remoteVersion(of: "_notes/a.md", client: client)
        XCTAssertEqual(theirs.map { String(decoding: $0, as: UTF8.self) }, "A from GitHub\n")
        try await copy.resolve(path: "_notes/a.md", keepMine: true, client: client)
        _ = try await copy.publish(paths: ["_notes/a.md"], message: "Update", client: client)
        XCTAssertEqual(fake.files()["_notes/a.md"], "A from this Mac\n")
    }

    func testKeepTheirsAndDiscard() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n", "b.md": "B\n"])
        fake.remoteEdit(["_notes/a.md": "A from GitHub\n"])
        try write(copy, "_notes/a.md", "A from this Mac\n")
        let outcome = try await copy.pull(client: client)
        XCTAssertEqual(outcome.conflicts, ["_notes/a.md"])
        try await copy.resolve(path: "_notes/a.md", keepMine: false, client: client)
        XCTAssertEqual(read(copy, "_notes/a.md"), "A from GitHub\n")
        try write(copy, "b.md", "B edited\n")
        try write(copy, "c.md", "new\n")
        try await copy.discard(path: "b.md", client: client)
        try await copy.discard(path: "c.md", client: client)
        XCTAssertEqual(read(copy, "b.md"), "B\n")
        XCTAssertNil(read(copy, "c.md"))
        let changes = try await copy.changes()
        XCTAssertEqual(changes, [:])
    }

    func testStaleBranchHeadAfterPublishIsIgnored() async throws {
        let (fake, copy, client) = try await make(["_notes/a.md": "A\n", "index.md": "Home\n"])
        let before = fake.head
        try write(copy, "_notes/b.md", "B\n")
        _ = try await copy.publish(paths: ["_notes/b.md"], message: "Publish B", client: client)
        fake.staleHeadOnce = before
        let outcome = try await copy.pull(client: client)
        XCTAssertFalse(outcome.changedRemotely)
        XCTAssertEqual(read(copy, "_notes/b.md"), "B\n", "a stale head must not look like GitHub deleted the new post")
        let changes = try await copy.changes()
        XCTAssertEqual(changes, [:])
    }

    func testStateSurvivesRelaunch() async throws {
        let (fake, copy, _) = try await make(["a.md": "A\n"])
        let again = WorkingCopy(ref: copy.ref, container: container)
        let downloaded = await again.isDownloaded
        XCTAssertTrue(downloaded)
        let base = await again.baseCommit
        XCTAssertEqual(base, fake.head)
    }
}
