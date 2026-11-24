import Foundation
@testable import InkwellGitHub
@testable import InkwellSync
import XCTest

/// Read-only checks against real GitHub. Skipped unless INKWELL_LIVE_TOKEN and INKWELL_LIVE_REPO (owner/name) are set.
final class LiveGitHubTests: XCTestCase {
    func testDownloadIsCleanAndPullIsANoOp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["INKWELL_LIVE_TOKEN"], let repo = env["INKWELL_LIVE_REPO"]?.split(separator: "/"), repo.count == 2 else {
            throw XCTSkip("Set INKWELL_LIVE_TOKEN and INKWELL_LIVE_REPO to run.")
        }
        let client = GitHubClient(token: token)
        let user = try await client.user()
        XCTAssertFalse(user.login.isEmpty)
        let info = try await client.repository(String(repo[0]), String(repo[1]))
        let pages = try await client.pages(String(repo[0]), String(repo[1]))
        let container = FileManager.default.temporaryDirectory.appending(path: "inkwell-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        let ref = SiteRef(owner: String(repo[0]), name: String(repo[1]), branch: pages?.source?.branch ?? info.default_branch ?? "main",
                          sitePath: pages?.sitePath ?? "")
        let copy = WorkingCopy(ref: ref, container: container)
        try await copy.download(client: client)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.siteRoot.appending(path: "_config.yml").path))
        let changes = try await copy.changes()
        XCTAssertEqual(changes, [:], "a fresh download has no changes")
        let pull = try await copy.pull(client: client)
        XCTAssertFalse(pull.changedRemotely)
        print("live: \(user.login) \(ref.fullName) branch \(ref.branch) pages \(pages?.html_url ?? "off") build \(pages?.build_type ?? "-")")
    }
}
