import CoreGraphics
import Foundation
import ImageIO
@testable import InkwellCore
@testable import InkwellDesign
@testable import InkwellMedia
import UniformTypeIdentifiers
import XCTest

/// Fixes from the release audit of design, content and media: unused-media detection, config and menu edits that must
/// not lose data, moves that keep links working, theme switches that keep the person's colours, and media replacement.
final class AuditFixTests2: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inkwell-audit2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    // MARK: Unused media (1, 2)

    func testMediaReferencesAreFoundHoweverTheyAreWritten() throws {
        for name in ["logo@2x.png", "logo@3x.png", "p(1).jpg", "my photo.jpg", "shot.png", "cat.jpg", "icon-192.png", "draft-only.jpg",
                     "favicon.png", "apple-touch-icon.png", "nobody.jpg", "en%20coded.png"] {
            try write("assets/images/\(name)", "x")
        }
        try write("guide/shot.png", "x")
        try write("index.html", #"<img srcset="/assets/images/logo@2x.png 2x, /assets/images/logo@3x.png 3x" src="/assets/images/p(1).jpg">"#)
        try write("about.html", #"<img src="/assets/images/my photo.jpg"><img src="/assets/images/en%20coded.png">"#)
        try write("guide/index.html", #"<img src="shot.png">"#)
        try write("_posts/2026-01-01-a.md", "---\nimage: cat.jpg\n---\nHi")
        try write("site.webmanifest", #"{"icons": [{"src": "/assets/images/icon-192.png"}]}"#)
        let items = MediaLibrary.scan(siteRoot: root, extraTexts: [(label: "_posts/2026-02-02-draft.md", text: "![a](/assets/images/draft-only.jpg)")])
        func item(_ path: String) throws -> MediaLibrary.Item { try XCTUnwrap(items.first { $0.path == path }) }
        for used in ["logo@2x.png", "logo@3x.png", "p(1).jpg", "my photo.jpg", "cat.jpg", "icon-192.png", "draft-only.jpg"] {
            XCTAssertFalse(try item("assets/images/\(used)").isUnused, used)
        }
        XCTAssertFalse(try item("guide/shot.png").isUnused, "a relative reference counts")
        XCTAssertEqual(try item("assets/images/draft-only.jpg").usedBy, ["_posts/2026-02-02-draft.md"])
        XCTAssertFalse(try item("assets/images/favicon.png").isUnused, "browsers ask for icons by name")
        XCTAssertFalse(try item("assets/images/apple-touch-icon.png").isUnused)
        XCTAssertTrue(try item("assets/images/nobody.jpg").isUnused)
    }

    // MARK: Settings and config (3, 10)

    func testAMappingIsNeverReplacedByOneValue() {
        let text = "title: Site\nauthor:\n  name: Jane\n  avatar: /a.png\n  links:\n    - x\n"
        var config = ConfigDocument(text: text)
        config.set("author", raw: "\"Jane Doe\"")
        XCTAssertEqual(config.text, text, "author keeps its mapping")
        config.set("author", raw: nil)
        XCTAssertEqual(config.text, text)
        config.set("author.name", raw: "\"Jane Doe\"")
        XCTAssertEqual(config.text, text.replacingOccurrences(of: "name: Jane", with: "name: \"Jane Doe\""))
    }

    func testConfigEditsKeepCommentsUseTheLastKeyAndLeaveInlineMapsAlone() {
        var config = ConfigDocument(text: "title: Old # my site\n")
        config.set("title", raw: "\"New\"")
        XCTAssertEqual(config.text, "title: \"New\" # my site\n")

        var inline = ConfigDocument(text: "inkwell: { theme: essayist, footer: hi }\n")
        inline.set("inkwell.theme", raw: "\"minimal\"")
        XCTAssertEqual(inline.text, "inkwell: { theme: essayist, footer: hi }\n", "an inline map is not rewritten")

        var twice = ConfigDocument(text: "title: First\ndescription: x\ntitle: Second\n")
        XCTAssertEqual(twice.value("title")?.string, "Second", "Jekyll reads the last one")
        twice.set("title", raw: "\"Third\"")
        XCTAssertEqual(twice.text, "title: First\ndescription: x\ntitle: \"Third\"\n")
    }

    // MARK: Navigation (4)

    func testOnlyAPlainMenuListIsEditable() {
        XCTAssertTrue(NavigationDocument(text: "").isEditable)
        XCTAssertTrue(NavigationDocument(text: "# Menu\n- title: Home\n  url: /\n- title: About\n  url: /about\n").isEditable)
        XCTAssertFalse(NavigationDocument(text: "main:\n  - title: Home\n    url: /\ndocs:\n  - title: A\n    url: /a\n").isEditable)
        XCTAssertFalse(NavigationDocument(text: "- title: Docs\n  url: /docs\n  children:\n    - title: A\n      url: /a\n").isEditable)
        XCTAssertFalse(NavigationDocument(text: "- title: More\n- title: Home\n  url: /\n").isEditable, "an item without an address")
        XCTAssertFalse(NavigationDocument(text: "- title: Home\n  url: /\n# later\n- title: A\n  url: /a\n").isEditable)
    }

    // MARK: Photos setup (5)

    func testPhotosSetupLeavesNamedMenusAloneAndKeepsTheConfigValid() throws {
        try write("_config.yml", "title: X\ncollections: [notes, travel]\n")
        try write("_data/navigation.yml", "main:\n  - title: Home\n    url: /\n")
        let plan = PhotoStream.setupPlan(siteRoot: root, timeZone: .gmt)
        XCTAssertNil(plan.first { $0.edit.path == "_data/navigation.yml" }, "a file of named menus is not appended to")
        let config = try XCTUnwrap(plan.first { $0.edit.path == "_config.yml" }?.edit.newText)
        let collections = YAML.parse(config)["collections"]
        XCTAssertEqual(collections?["notes"]?["output"]?.bool, false)
        XCTAssertEqual(collections?["travel"]?["output"]?.bool, false)
        XCTAssertNotNil(collections?["photos"])

        try write("_data/navigation.yml", "- title: Home\n  url: /\n")
        let listPlan = PhotoStream.setupPlan(siteRoot: root, timeZone: .gmt)
        let nav = try XCTUnwrap(listPlan.first { $0.edit.path == "_data/navigation.yml" }?.edit.newText)
        XCTAssertTrue(nav.hasSuffix("- title: Photos\n  url: /photos\n"), nav)
    }

    func testANewCollectionFollowsTheFilesIndentation() {
        var config = ConfigEditing(text: "collections:\n    notes:\n        output: true\n")
        XCTAssertTrue(config.addCollection("photos", output: false))
        XCTAssertEqual(config.text, "collections:\n    notes:\n        output: true\n    photos:\n        output: false\n")
        XCTAssertNotNil(YAML.parse(config.text)["collections"]?["photos"])
    }

    // MARK: Lists in _config.yml (6)

    func testAppendingToAListKeepsTheConfigValid() {
        var multi = ConfigEditing(text: "plugins: [\n  jekyll-feed,\n  jekyll-seo-tag\n]\ntitle: X\n")
        XCTAssertTrue(multi.appendToList("plugins", item: "jekyll-redirect-from"))
        XCTAssertEqual(YAML.parse(multi.text)["plugins"]?.list?.compactMap(\.string), ["jekyll-feed", "jekyll-seo-tag", "jekyll-redirect-from"])
        XCTAssertEqual(YAML.parse(multi.text)["title"]?.string, "X")

        var scalar = ConfigEditing(text: "plugins: jekyll-feed\ntitle: X\n")
        XCTAssertTrue(scalar.appendToList("plugins", item: "jekyll-redirect-from"))
        XCTAssertEqual(scalar.text, "plugins:\n  - jekyll-feed\n  - jekyll-redirect-from\ntitle: X\n")

        var block = ConfigEditing(text: "plugins:\n  - jekyll-feed\n")
        XCTAssertTrue(block.appendToList("plugins", item: "jekyll-sitemap"))
        XCTAssertEqual(block.text, "plugins:\n  - jekyll-feed\n  - jekyll-sitemap\n")
        XCTAssertFalse(block.appendToList("plugins", item: "jekyll-sitemap"))
    }

    // MARK: Moving posts (7, 8)

    func testLinksAndFileTagsFollowAMovedPost() {
        let text = """
        <a href='/notes/foo/'>a</a> [b]({{ site.baseurl }}/notes/foo/) [c](/notes/foo.html) \
        {{ '/notes/foo/' | absolute_url }} {% post_url 2020-01-01-foo %} {%- link _posts/2020-01-01-foo.md -%}
        """
        let links = MovePlanner.rewriteLinks(in: text, from: "/notes/foo/", to: "/notes/bar/", baseurl: "")
        XCTAssertTrue(links.contains("href='/notes/bar/'"), links)
        XCTAssertTrue(links.contains("({{ site.baseurl }}/notes/bar/)"), links)
        XCTAssertTrue(links.contains("[c](/notes/bar/)"), links)
        XCTAssertTrue(links.contains("{{ '/notes/bar/' | absolute_url }}"), links)

        let renamed = MovePlanner.rewriteFileTags(in: text, from: "_posts/2020-01-01-foo.md", to: "_posts/2020-01-01-bar.md")
        XCTAssertTrue(renamed.contains("{% post_url 2020-01-01-bar %}"), renamed)
        XCTAssertTrue(renamed.contains("{%- link _posts/2020-01-01-bar.md -%}"), renamed)
        let moved = MovePlanner.rewriteFileTags(in: text, from: "_posts/2020-01-01-foo.md", to: "_notes/2020-01-01-foo.md")
        XCTAssertTrue(moved.contains("{% link _notes/2020-01-01-foo.md %}"), "post_url cannot reach another collection: \(moved)")
    }

    func testAMoveRewritesDraftsAndKnowsWhenRedirectsCannotWork() throws {
        try write("_config.yml", "title: X\ncollections:\n  notes:\n    output: true\n    permalink: /notes/:title/\n")
        try write("_notes/foo.md", "---\ntitle: Foo\n---\nHi")
        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"jekyll\"\n")
        // Built by its own Jekyll workflow, so only the Gemfile's gems load.
        try write(".github/workflows/pages.yml", "jobs:\n  build:\n    steps:\n      - run: bundle exec jekyll build\n"
            + "      - uses: actions/upload-pages-artifact@v3\n")
        let draftURL = root.appending(path: "draft.md")
        try Data("See [foo](/notes/foo/).".utf8).write(to: draftURL)
        let site = try SiteLoader.load(root)
        let doc = try XCTUnwrap(site.documents.first { $0.relativePath == "_notes/foo.md" })
        let draft = SiteDocument(id: "draft:x", sectionID: "notes", origin: .localDraft, fileURL: draftURL, relativePath: "_notes/draft.md",
                                 title: "D", date: nil, publishedFlag: true, url: "", modified: Date(), excerpt: "")
        let plan = MovePlanner.plan(document: doc, text: try read("_notes/foo.md"), newPath: "_notes/bar.md", keepOldAddress: true, site: site,
                                    configText: try read("_config.yml"), drafts: [draft])
        XCTAssertEqual(plan.draftEdits.first?.newText, "See [foo](/notes/bar/).")
        XCTAssertTrue(plan.redirectUnavailable, "the Gemfile has no jekyll-redirect-from")
        XCTAssertNil(plan.edits.first { $0.path == "_config.yml" }, "no plugin the build cannot load")

        XCTAssertFalse(Plugins.usable("jekyll-feed", siteRoot: root))
        try write("Gemfile", "gem \"github-pages\", group: :jekyll_plugins\n")
        XCTAssertTrue(Plugins.usable("jekyll-feed", siteRoot: root))
        try FileManager.default.removeItem(at: root.appending(path: "Gemfile"))
        XCTAssertTrue(Plugins.usable("jekyll-feed", siteRoot: root), "GitHub's own build has the common plugins")
    }

    // MARK: Theme switches (9)

    func testSwitchingThemesKeepsTheColoursThePersonChanged() throws {
        let first = try XCTUnwrap(ThemeManifest.named("essayist")), second = try XCTUnwrap(ThemeManifest.named("minimal"))
        try write("_config.yml", "title: X\n")
        try ThemeApplier.plan(theme: first, siteRoot: root).apply(to: root)
        let shared = Set(CSSTokenDocument(text: first.stylesheet).tokens.map(\.name))
            .intersection(CSSTokenDocument(text: second.stylesheet).tokens.map(\.name))
        let name = try XCTUnwrap(shared.sorted().first { $0.contains("accent") } ?? shared.sorted().first)
        var css = CSSTokenDocument(text: try read("assets/css/inkwell.css"))
        css.set(name, to: "#123456")
        try write("assets/css/inkwell.css", css.text)

        let plan = ThemeApplier.plan(theme: second, siteRoot: root)
        let change = try XCTUnwrap(plan.changes.first { $0.path == "assets/css/inkwell.css" })
        XCTAssertEqual(CSSTokenDocument(text: change.newText ?? "").value(name), "#123456")
        XCTAssertTrue(change.reason.contains("kept"), change.reason)
        // Untouched settings take the new theme's values.
        let firstDefaults = CSSTokenDocument(text: first.stylesheet), secondDefaults = CSSTokenDocument(text: second.stylesheet)
        let other = try XCTUnwrap(shared.sorted().first { $0 != name && secondDefaults.value($0) != firstDefaults.value($0) })
        XCTAssertEqual(CSSTokenDocument(text: change.newText ?? "").value(other), CSSTokenDocument(text: second.stylesheet).value(other))
    }

    // MARK: CSS values (11)

    func testSemicolonsInsideQuotesAndBracketsStayInTheValue() {
        let text = ":root {\n  --icon: url(\"data:image/svg+xml;utf8,<svg></svg>\");\n  --font: \"A;B\", serif;\n  --gap: 4px\n}\n"
        var doc = CSSTokenDocument(text: text)
        XCTAssertEqual(doc.value("--icon"), "url(\"data:image/svg+xml;utf8,<svg></svg>\")")
        XCTAssertEqual(doc.value("--font"), "\"A;B\", serif")
        XCTAssertEqual(doc.value("--gap"), "4px")
        doc.set("--icon", to: "none")
        XCTAssertEqual(doc.text, ":root {\n  --icon: none;\n  --font: \"A;B\", serif;\n  --gap: 4px\n}\n")
    }

    // MARK: Media replace (12)

    func image(_ name: String, type: UTType, alpha: UInt8) throws -> URL {
        let url = root.appending(path: name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: CGFloat(alpha) / 255))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testReplacingRefusesWhatWouldDegradeThePicture() throws {
        let gif = root.appending(path: "anim.gif")
        try Data("GIF89a".utf8).write(to: gif)
        let jpeg = try image("photo.jpg", type: .jpeg, alpha: 255)
        let opaque = try image("opaque.png", type: .png, alpha: 255)
        let clear = try image("clear.png", type: .png, alpha: 0)
        XCTAssertThrowsError(try ImageImport().replace(gif, with: opaque)) { error in
            guard case ImageImportError.cannotReplace = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ImageImport().replace(jpeg, with: clear)) { error in
            guard case ImageImportError.wouldLoseTransparency = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try ImageImport().replace(jpeg, with: opaque), "an opaque picture with an alpha channel is fine")
    }
}
