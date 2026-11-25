import Foundation
@testable import InkwellCore
@testable import InkwellMarkdown
@testable import InkwellTemplate
import XCTest

/// A site with hundreds of posts and images, to keep the work done on open, on save and on each keystroke bounded.
/// The limits are generous, so the test only fails when something becomes much slower than it should be.
final class PerformanceTests: XCTestCase {
    nonisolated(unsafe) static var root: URL!
    static let posts = 600
    static let images = 300

    override class func setUp() {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "inkwell-large-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.copyItem(at: fixtureSite(), to: root)
        try? fm.createDirectory(at: root.appending(path: "assets/images"), withIntermediateDirectories: true)
        let pixel = Data(repeating: 0xFF, count: 40000)
        for i in 0 ..< images { try? pixel.write(to: root.appending(path: "assets/images/picture-\(i).jpg")) }
        let paragraph = "Writing for the web should feel like writing a note, with **bold**, *italic*, `code` and [a link](/notes/post-1/). "
        for i in 0 ..< posts {
            let body = (0 ..< 12).map { _ in paragraph }.joined(separator: "\n\n")
            let text = "---\ntitle: \"Post \(i)\"\ndate: 2025-01-\(String(format: "%02d", i % 28 + 1))\ntags: [one, two]\n---\n\n"
                + body + "\n\n![Picture \(i)](/assets/images/picture-\(i % images).jpg)\n"
            try? text.write(to: root.appending(path: "_notes/2025-01-\(String(format: "%02d", i % 28 + 1))-post-\(i).md"), atomically: true, encoding: .utf8)
        }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func time(_ label: String, limit: Double, _ work: () throws -> Void) rethrows {
        let start = Date()
        try work()
        let seconds = Date().timeIntervalSince(start)
        print("perf: \(label) \(String(format: "%.3f", seconds)) s")
        XCTAssertLessThan(seconds, limit, label)
    }

    func testLargeSite() throws {
        var site: Site!
        try time("load \(Self.posts) posts", limit: 3) { site = try SiteLoader.load(Self.root) }
        XCTAssertGreaterThanOrEqual(site.documents.count, Self.posts)
        time("health", limit: 4) { _ = SiteHealth.check(site) }
        time("media library", limit: 4) {
            let pictures = MediaLibrary.scan(siteRoot: Self.root).filter { $0.path.hasPrefix("assets/images/picture") }
            XCTAssertEqual(pictures.count, Self.images)
            XCTAssertTrue(pictures.allSatisfy { !$0.usedBy.isEmpty })
        }
        time("preview builder", limit: 4) {
            let builder = PreviewBuilder(site: site, timeZone: site.config.timeZone)
            _ = builder.page(at: "/notes/post-10/")
        }
    }

    func testLongPostScan() {
        let paragraph = "A *long* post with **bold**, `code`, [links](/x/), ~~strike~~ and {{ liquid }} in every paragraph.[^1]\n\n"
        let text = String(repeating: paragraph, count: 1500) + "[^1]: A note.\n"
        time("scan \(text.count / 1000)k characters", limit: 1.5) { _ = MarkdownScanner.scan(text) }
        time("tables and images", limit: 1) {
            _ = MarkdownTable.ranges(in: text)
            _ = ImageLines.find(in: text)
        }
    }
}
