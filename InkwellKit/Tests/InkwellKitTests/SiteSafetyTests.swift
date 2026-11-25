import Foundation
@testable import InkwellCore
@testable import InkwellDesign
@testable import InkwellMarkdown
@testable import InkwellTemplate
import XCTest

/// Scheduling tells the truth about GitHub Pages, and the element kit never replaces a site's own files.
final class ScheduleConfigTests: XCTestCase {
    func testFutureFalseIsAddedLineByLine() throws {
        let text = "# Site settings\ntitle: Notes   # shown in tabs\nplugins:\n  - jekyll-feed\n"
        let held = try XCTUnwrap(Schedule.configHoldingFuturePosts(text))
        XCTAssertEqual(held, text + "future: false\n")
        XCTAssertFalse(Schedule.publishesFutureNow(SiteConfig(yaml: YAML.parse(held))))
        XCTAssertNil(Schedule.configHoldingFuturePosts(held), "already set")
        XCTAssertNil(Schedule.configHoldingFuturePosts("future: true\n"), "an explicit choice stays")
        XCTAssertEqual(Schedule.configHoldingFuturePosts(""), "future: false\n")
        XCTAssertEqual(Schedule.configHoldingFuturePosts("title: x"), "title: x\nfuture: false")
    }

    func testExplicitFutureTrueIsTheOnlyChoiceLeftAlone() {
        XCTAssertTrue(Schedule.futureTurnedOn(SiteConfig(yaml: YAML.parse("future: true"))))
        XCTAssertFalse(Schedule.futureTurnedOn(SiteConfig(yaml: YAML.parse("title: x"))))
        XCTAssertFalse(Schedule.futureTurnedOn(SiteConfig(yaml: YAML.parse("future: false"))))
    }

    func testWorkflowNeedsTheDefaultBranchRootAndLegacyBuilds() {
        XCTAssertNil(Schedule.workflowBlocker(sitePath: "", branch: "main", defaultBranch: "main", buildType: "legacy"))
        XCTAssertNil(Schedule.workflowBlocker(sitePath: "", branch: "main", defaultBranch: nil, buildType: nil), "a local folder")
        XCTAssertEqual(Schedule.workflowBlocker(sitePath: "", branch: "gh-pages", defaultBranch: "main", buildType: "legacy"),
                       .notDefaultBranch(site: "gh-pages", default: "main"))
        let folder = Schedule.workflowBlocker(sitePath: "docs", branch: "main", defaultBranch: "main", buildType: "legacy")
        XCTAssertEqual(folder, .siteInFolder)
        let actions = Schedule.workflowBlocker(sitePath: "", branch: "main", defaultBranch: "main", buildType: "workflow")
        XCTAssertEqual(actions, .builtByWorkflow)
        let message = Schedule.WorkflowBlocker.notDefaultBranch(site: "gh-pages", default: "main").message
        XCTAssertTrue(message.contains("gh-pages") && message.contains("main"), message)
    }

    func testWorkflowPinsCheckoutToACommit() throws {
        let line = try XCTUnwrap(Schedule.workflow.split(separator: "\n").first { $0.contains("actions/checkout@") })
        XCTAssertNotNil(line.range(of: #"actions/checkout@[0-9a-f]{40} # v\d"#, options: .regularExpression), String(line))
    }
}

final class ThemeRobustnessTests: XCTestCase {
    /// An author written as a hash shows its name, and a home page whose collection has no posts still builds.
    func testHashAuthorAndMissingCollection() throws {
        for theme in ThemeManifest.bundled() {
            let root = FileManager.default.temporaryDirectory.appending(path: "robust-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: root)
            let configURL = root.appending(path: "_config.yml")
            var config = ConfigDocument(text: try String(contentsOf: configURL, encoding: .utf8))
            config.set("author", raw: nil)
            config.set("author.name", raw: "Sam Rivers")
            config.set("author.email", raw: "sam@example.com")
            config.set("inkwell.home_collection", raw: "nothing")
            try Data(config.text.utf8).write(to: configURL)
            let site = try SiteLoader.load(root)
            let builder = PreviewBuilder(site: site, timeZone: TimeZone(identifier: "UTC")!)
            let home = try XCTUnwrap(builder.page(at: "/"), theme.id).html
            XCTAssertTrue(home.contains("Nothing here yet."), "\(theme.id): empty home")
            XCTAssertFalse(home.contains("sam@example.com"), "\(theme.id): the author hash is not printed")
            XCTAssertTrue(home.contains("Sam Rivers"), "\(theme.id): footer names the author")
            let post = try XCTUnwrap(builder.page(at: "/2026/10/the-long-way-round-the-headland/"), theme.id).html
            XCTAssertFalse(post.contains("sam@example.com"), "\(theme.id): post")
            if theme.id == "magazine" { XCTAssertTrue(post.contains("By Sam Rivers"), "magazine byline") }
        }
    }

    func testButtonTextUsesTheBackgroundNotWhite() throws {
        let css = try XCTUnwrap(ElementKit.files[ElementKit.stylesheet])
        let start = try XCTUnwrap(css.range(of: ".ik-button, a.ik-button {"))
        let button = String(css[start.lowerBound...].prefix { $0 != "}" })
        XCTAssertTrue(button.contains("color: var(--accent-contrast, var(--bg, #fff))"), button)
        // Every theme's accent already reaches 4.5:1 on its background (ThemeGalleryTests), in light and dark.
        for theme in ThemeManifest.bundled() {
            for palette in DesignPresets.palettes(for: theme) {
                for dark in [false, true] {
                    let bg = palette.value("--bg", dark: dark) ?? "", accent = palette.value("--accent", dark: dark) ?? ""
                    let ratio = DesignPresets.contrast(bg, accent) ?? 0
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.id)/\(palette.id) \(dark ? "dark" : "light")")
                }
            }
        }
    }
}

final class ElementKitOwnershipTests: XCTestCase {
    func temporarySite() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appending(path: "own-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
        return temp
    }

    func testEveryKitFileIsAShippedVersion() {
        for (path, text) in ElementKit.files {
            XCTAssertTrue(ElementKit.isShipped(text), "add \(ElementKit.digest(text)) for \(path) to ElementKit.shippedVersions")
        }
    }

    func testTheSitesOwnFilesStay() throws {
        let temp = try temporarySite()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp.appending(path: "_layouts"), withIntermediateDirectories: true)
        let ownAlbum = "---\nlayout: default\n---\n<div class=\"my-album\">{{ content }}</div>\n"
        try Data(ownAlbum.utf8).write(to: temp.appending(path: "_layouts/album.html"))
        try AdoptionPlan(title: "", changes: ElementKit.changes(siteRoot: temp)).apply(to: temp)
        XCTAssertEqual(try String(contentsOf: temp.appending(path: "_layouts/album.html"), encoding: .utf8), ownAlbum)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appending(path: "_layouts/inkwell-slides.html").path))

        // A hand edit to the kit's stylesheet is the person's now.
        let css = temp.appending(path: ElementKit.stylesheet)
        let edited = try String(contentsOf: css, encoding: .utf8) + "\n.ik-button { border-radius: 0; }\n"
        try Data(edited.utf8).write(to: css)
        XCTAssertFalse(ElementKit.changes(siteRoot: temp).contains { $0.path == ElementKit.stylesheet })
        // So is a site's own slides layout, which Inkwell's slides no longer share a name with.
        XCTAssertEqual(PageTemplate.slides.layout, "inkwell-slides")
    }

    func testAnOlderInkwellVersionIsUpdated() throws {
        let temp = try temporarySite()
        defer { try? FileManager.default.removeItem(at: temp) }
        let path = "_includes/inkwell/recent.html"
        let current = try XCTUnwrap(ElementKit.files[path])
        // The first version of recent.html, before the guard for a section with no posts.
        let guarded = """
        {% comment %} A section with no posts yet is nil, and Jekyll's sort stops the build on nil. {% endcomment %}
        {% assign ik_items = site[ik_collection] %}
        {% if ik_items %}{% assign ik_items = ik_items | where_exp: "item", "item.published != false" | sort: 'date' | reverse %}{% endif %}
        """
        let unguarded = #"{% assign ik_items = site[ik_collection] | where_exp: "item", "item.published != false""#
            + #" | sort: 'date' | reverse %}"#
        let first = current.replacingOccurrences(of: guarded, with: unguarded)
        XCTAssertTrue(ElementKit.isShipped(first))
        try FileManager.default.createDirectory(at: temp.appending(path: "_includes/inkwell"), withIntermediateDirectories: true)
        try Data(first.utf8).write(to: temp.appending(path: path))
        let change = try XCTUnwrap(ElementKit.changes(siteRoot: temp).first { $0.path == path })
        XCTAssertEqual(change.newText, current)
    }

    func testListsRenderWhenTheCollectionIsMissing() throws {
        let temp = try temporarySite()
        defer { try? FileManager.default.removeItem(at: temp) }
        try AdoptionPlan(title: "", changes: ElementKit.changes(siteRoot: temp)).apply(to: temp)
        let site = try SiteLoader.load(temp)
        let body = "{% include inkwell/recent.html collection=\"nothing\" %}\n\n{% include inkwell/archive.html collection=\"nothing\" %}\n"
        let page = PreviewBuilder(site: site).render(text: "---\ntitle: T\nlayout: page\n---\n\n" + body, relativePath: "t.md", url: "/t/")
        XCTAssertTrue(page.html.contains("class=\"ik-recent\""))
        XCTAssertTrue(page.html.contains("class=\"ik-archive\""))
        XCTAssertFalse(page.html.contains("{%"))
    }
}
