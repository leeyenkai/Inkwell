import Foundation
@testable import InkwellCore
import XCTest

final class ContentToolsTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-content-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testRenameKeepsOldAddressAndFixesLinks() throws {
        // Another post links to the essay three ways.
        let second = temp.appending(path: "_notes/2025-12-01-second-note.md")
        let links = "See [the essay](/notes/sample-essay/), [again](/notes/sample-essay#x) and <a href=\"/notes/sample-essay/\">here</a>.\n"
        try ("---\ntitle: \"Second note\"\ndate: 2025-12-01\n---\n\n" + links).write(to: second, atomically: true, encoding: .utf8)
        let site = try SiteLoader.load(temp)
        let essay = try XCTUnwrap(site.documents.first { $0.relativePath == "_notes/2026-06-20-sample-essay.md" })
        let text = try String(contentsOf: essay.fileURL, encoding: .utf8)
        let config = try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8)
        let plan = MovePlanner.plan(document: essay, text: text, newPath: "_notes/2026-06-20-on-essays.md", keepOldAddress: true, site: site,
                                    configText: config)
        XCTAssertEqual(plan.newURL, "/notes/on-essays/")
        XCTAssertEqual(plan.updatedLinks, ["_notes/2025-12-01-second-note.md"])
        for edit in plan.edits { try edit.apply(to: temp) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: essay.fileURL.path))
        let moved = try String(contentsOf: temp.appending(path: "_notes/2026-06-20-on-essays.md"), encoding: .utf8)
        XCTAssertEqual(FrontMatterDocument(text: moved).value("redirect_from"), .list([.string("/notes/sample-essay/")]))
        let linked = try String(contentsOf: second, encoding: .utf8)
        XCTAssertTrue(linked.contains("[the essay](/notes/on-essays/)"))
        XCTAssertTrue(linked.contains("[again](/notes/on-essays/#x)") || linked.contains("[again](/notes/on-essays#x)"))
        XCTAssertTrue(linked.contains("href=\"/notes/on-essays/\""))
        let newConfig = try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8)
        XCTAssertTrue(newConfig.contains("  - jekyll-sitemap\n  - jekyll-redirect-from\n"), newConfig)
        XCTAssertEqual(SiteConfig(yaml: YAML.parse(newConfig)).plugins.last, "jekyll-redirect-from")
    }

    func testMoveToAnotherSection() throws {
        let site = try SiteLoader.load(temp)
        let note = try XCTUnwrap(site.documents.first { $0.relativePath == "_notes/2025-12-01-second-note.md" })
        let plan = MovePlanner.plan(document: note, text: try String(contentsOf: note.fileURL, encoding: .utf8),
                                    newPath: "_sidenotes/2025-12-01-second-note.md", keepOldAddress: false, site: site, configText: nil)
        XCTAssertEqual(plan.newURL, "/sidenotes/second-note/")
        XCTAssertFalse(plan.edits.contains { $0.path == "_config.yml" })
    }

    func testConfigListAppend() {
        var flow = ConfigEditing(text: "title: x\nplugins: [jekyll-feed]\n")
        XCTAssertTrue(flow.appendToList("plugins", item: "jekyll-redirect-from"))
        XCTAssertEqual(flow.text, "title: x\nplugins: [jekyll-feed, jekyll-redirect-from]\n")
        XCTAssertFalse(flow.appendToList("plugins", item: "jekyll-feed"))
        var none = ConfigEditing(text: "title: x\n")
        none.appendToList("plugins", item: "jekyll-redirect-from")
        XCTAssertEqual(none.text, "title: x\n\nplugins:\n  - jekyll-redirect-from\n")
    }

    func testTagsRenameAndMerge() {
        let block = "---\ntitle: \"A\"\ntags:\n  - ethics\n  - politics\n---\nBody\n"
        let flow = "---\ntitle: \"B\"\ntags: [politics, travel]\n---\nBody\n"
        let index = TagIndex.build([("a.md", block), ("b.md", flow)])
        XCTAssertEqual(index["politics"], ["a.md", "b.md"])
        XCTAssertEqual(TagIndex.rename("politics", to: "ethics", in: block), "---\ntitle: \"A\"\ntags: [ethics]\n---\nBody\n")
        XCTAssertEqual(TagIndex.rename("travel", to: "trips", in: flow), "---\ntitle: \"B\"\ntags: [politics, trips]\n---\nBody\n")
        XCTAssertEqual(TagIndex.rename("travel", to: nil, in: flow), "---\ntitle: \"B\"\ntags: [politics]\n---\nBody\n")
        XCTAssertNil(TagIndex.rename("absent", to: "x", in: flow))
        XCTAssertEqual(TagIndex.tags(in: "---\ntags: one two\n---\n"), ["one", "two"])
    }

    func testLineDiff() {
        let diff = TextDiff.lines(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        XCTAssertEqual(diff, [.same("a"), .removed("b"), .added("B"), .same("c"), .added("d"), .same("")])
    }
}
