import Foundation
@testable import InkwellCore
import InkwellDesign
import InkwellTemplate
import XCTest

final class AlbumsTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-albums-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    let handWritten = """
    # Albums, in the order the photos page shows them.
    - id: japan-2025
      title: "Japan 2025"   # spring trip
      description: >
        Two weeks, mostly trains.
      cover: /assets/photos/2025/kyoto.jpg

    - id: family
      title: Family

    """

    // MARK: The data file

    func testAlbumsFileReadsAndRoundTrips() {
        let file = AlbumsFile(text: handWritten)
        XCTAssertEqual(file.text, handWritten, "reading and writing without changes keeps every byte")
        XCTAssertEqual(file.albums.map(\.id), ["japan-2025", "family"])
        XCTAssertEqual(file.albums[0].title, "Japan 2025")
        XCTAssertEqual(file.albums[0].description, "Two weeks, mostly trains.\n")
        XCTAssertEqual(file.albums[0].cover, "/assets/photos/2025/kyoto.jpg")
        XCTAssertEqual(file.albums[1].title, "Family")
        XCTAssertEqual(AlbumsFile(text: "- id: a\n  title: A").text, "- id: a\n  title: A", "no newline added at the end")
    }

    func testFieldEditsTouchOnlyTheirLines() {
        var file = AlbumsFile(text: handWritten)
        file.set("title", raw: YAMLFormat.quoted("Japan, spring 2025"), at: 0)
        file.set("cover", raw: nil, at: 0)
        file.set("order", raw: "oldest", at: 1)
        XCTAssertEqual(file.text, """
        # Albums, in the order the photos page shows them.
        - id: japan-2025
          title: "Japan, spring 2025"
          description: >
            Two weeks, mostly trains.

        - id: family
          title: Family
          order: oldest

        """)
        XCTAssertEqual(file.albums[1].oldestFirst, true)
        let before = file
        file.set("title", raw: "Family", at: 1)
        XCTAssertEqual(file, before, "an equal value changes nothing")
        file.set("id", raw: nil, at: 1)
        XCTAssertTrue(file.text.hasSuffix("- title: Family\n  order: oldest\n"), "the next field carries the dash")
    }

    func testReorderKeepsSpacingAndComments() {
        var file = AlbumsFile(text: handWritten)
        file.reorder(["family", "japan-2025"])
        XCTAssertEqual(file.text, """
        # Albums, in the order the photos page shows them.
        - id: family
          title: Family

        - id: japan-2025
          title: "Japan 2025"   # spring trip
          description: >
            Two weeks, mostly trains.
          cover: /assets/photos/2025/kyoto.jpg

        """)
        var tight = AlbumsFile(text: "- id: a\n  title: A\n- id: b\n  title: B\n")
        tight.reorder(["b"])
        XCTAssertEqual(tight.text, "- id: b\n  title: B\n- id: a\n  title: A\n")
    }

    func testIDsFromTitles() {
        XCTAssertEqual(Albums.newID(for: "Japan, Spring 2025!", taken: []), "japan-spring-2025")
        XCTAssertEqual(Albums.newID(for: "Japan", taken: ["japan", "japan-2"]), "japan-3")
        XCTAssertEqual(Albums.newID(for: "2025", taken: []), "album-2025", "a number alone would read as a number in YAML")
        XCTAssertEqual(Albums.newID(for: "  ", taken: []), "album")
        XCTAssertEqual(Albums.ids(in: YAML.parse("albums: [a, b]\nalbum: c")), ["a", "b", "c"])
        XCTAssertEqual(Albums.ids(in: YAML.parse("albums:\n  - a\n  - b")), ["a", "b"])
        XCTAssertEqual(Albums.ids(in: YAML.parse("album: a")), ["a"])
        XCTAssertEqual(Albums.ids(in: YAML.parse("albums: a\nalbum: a")), ["a"])
    }

    // MARK: Library

    func photo(_ name: String, _ extra: String = "") -> AlbumLibrary.PhotoFile {
        let date = "2026-01-0\(name.count % 9)"
        let text = "---\nimage: /assets/photos/\(name).jpg\ncaption: \"\(name)\"\ndate: \(date)\(extra)\n---\n"
        return .init(path: "_photos/\(name).md", text: text)
    }

    func testCreateRenameAndDescribe() throws {
        var library = AlbumLibrary(albumsText: nil, photos: [])
        let (id, edits) = library.create(title: "Japan 2025", description: "Two weeks, mostly trains.")
        XCTAssertEqual(id, "japan-2025")
        XCTAssertEqual(edits.map(\.path), ["_data/albums.yml", "albums/japan-2025.md"])
        XCTAssertEqual(edits[0].newText, "- id: japan-2025\n  title: \"Japan 2025\"\n  description: \"Two weeks, mostly trains.\"\n")
        let page = "---\nlayout: album\ntitle: \"Japan 2025\"\nalbum: japan-2025\npermalink: /albums/japan-2025/\n---\n"
        XCTAssertEqual(edits[1].newText, page)

        let second = library.create(title: "Japan 2025")
        XCTAssertEqual(second.id, "japan-2025-2", "ids are unique")

        let renamed = library.rename("japan-2025", to: "Japan, spring")
        XCTAssertEqual(renamed.map(\.path), ["_data/albums.yml", "albums/japan-2025.md"], "the id and the address stay")
        XCTAssertTrue(try XCTUnwrap(renamed[0].newText).hasPrefix("- id: japan-2025\n  title: \"Japan, spring\"\n  description:"))
        XCTAssertEqual(renamed[1].newText, page.replacingOccurrences(of: "Japan 2025", with: "Japan, spring"))
        XCTAssertEqual(library.rename("japan-2025", to: "Japan, spring"), [], "the same title changes nothing")
        XCTAssertEqual(library.rename("japan-2025", to: " "), [], "an album keeps a title")

        let described = library.setDescription("japan-2025", to: "")
        XCTAssertFalse(try XCTUnwrap(described.first?.newText).contains("description"))
        let covered = library.setCover("japan-2025-2", image: "/assets/photos/a.jpg")
        let coveredText = try XCTUnwrap(covered.first?.newText)
        XCTAssertTrue(coveredText.hasSuffix("- id: japan-2025-2\n  title: \"Japan 2025\"\n  cover: /assets/photos/a.jpg\n"))
        XCTAssertEqual(library.albums.map(\.cover), ["", "/assets/photos/a.jpg"])
    }

    func testAddingAndRemovingPhotosChangesOnlyThatField() throws {
        let photos = [photo("a"), photo("bb", "\nlocation: \"Kyoto\"\nhidden: true"), photo("ccc", "\nalbum: family")]
        var library = AlbumLibrary(albumsText: handWritten, photos: photos)
        let added = library.add(["_photos/a.md", "_photos/bb.md", "_photos/ccc.md"], to: "japan-2025")
        XCTAssertEqual(added.map(\.path), ["_photos/a.md", "_photos/bb.md", "_photos/ccc.md"])
        XCTAssertEqual(added[0].newText, "---\nimage: /assets/photos/a.jpg\ncaption: \"a\"\ndate: 2026-01-01\nalbums: [japan-2025]\n---\n")
        XCTAssertEqual(added[1].newText,
                       "---\nimage: /assets/photos/bb.jpg\ncaption: \"bb\"\ndate: 2026-01-02\nlocation: \"Kyoto\"\n"
                           + "albums: [japan-2025]\nhidden: true\n---\n")
        XCTAssertEqual(library.photoPaths(in: "japan-2025"), ["_photos/a.md", "_photos/bb.md", "_photos/ccc.md"])
        XCTAssertEqual(library.photoPaths(in: "family"), ["_photos/ccc.md"], "a single album: still counts")
        XCTAssertEqual(library.add(["_photos/a.md"], to: "japan-2025"), [], "adding twice changes nothing")
        XCTAssertEqual(library.add(["_photos/ccc.md"], to: "family"), [])

        _ = library.add(["_photos/a.md"], to: "family")
        let removed = library.remove(["_photos/a.md", "_photos/ccc.md"], from: "family")
        XCTAssertEqual(removed.map(\.path), ["_photos/a.md", "_photos/ccc.md"])
        XCTAssertTrue(try XCTUnwrap(removed[0].newText).contains("albums: [japan-2025]\n"))
        XCTAssertEqual(removed[1].newText,
                       "---\nimage: /assets/photos/ccc.jpg\ncaption: \"ccc\"\ndate: 2026-01-03\nalbums: [japan-2025]\n---\n")
        _ = library.remove(["_photos/a.md"], from: "japan-2025")
        XCTAssertEqual(library.photos[0].text, photos[0].text, "removing the last album removes the field")
        XCTAssertEqual(library.photoPathsWithoutAlbum, ["_photos/a.md"])
    }

    func testDeleteKeepsPhotos() throws {
        var library = AlbumLibrary(albumsText: handWritten, photos: [photo("a", "\nalbums: [japan-2025, family]"), photo("bb")],
                                   pages: ["albums/japan-2025.md": Albums.pageText(id: "japan-2025", title: "Japan 2025")])
        let edits = library.delete("japan-2025")
        XCTAssertEqual(edits.map(\.path), ["_data/albums.yml", "albums/japan-2025.md", "_photos/a.md"])
        XCTAssertEqual(edits[0].newText, "# Albums, in the order the photos page shows them.\n- id: family\n  title: Family\n")
        XCTAssertNil(edits[1].newText, "the album page goes")
        XCTAssertTrue(try XCTUnwrap(edits[2].newText).contains("albums: [family]\n"))
        XCTAssertEqual(library.photos.count, 2, "photos stay")

        var only = AlbumLibrary(albumsText: "- id: x\n  title: X\n", photos: [])
        XCTAssertEqual(only.delete("x"), [ContentEdit(path: "_data/albums.yml", newText: nil)], "an empty list removes the file")
        let edits2 = [ContentEdit(path: "a", newText: "1"), ContentEdit(path: "b", newText: nil), ContentEdit(path: "a", newText: "2")]
        XCTAssertEqual(edits2.merged, [ContentEdit(path: "a", newText: "2"), ContentEdit(path: "b", newText: nil)])
    }

    // MARK: Photos page and site files

    func testPhotoFilesJoinAlbumsAndPhotosPageShowsThem() throws {
        let date = try XCTUnwrap(SiteDate.parse("2026-02-03", timeZone: TimeZone(identifier: "UTC")!))
        let edit = PhotoStream.file(for: .init(image: "/assets/photos/x.jpg", date: date, albums: ["japan-2025"]), existing: [],
                                    timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(edit.newText, "---\nimage: /assets/photos/x.jpg\ndate: 2026-02-03\nalbums: [japan-2025]\n---\n")

        let old = "---\nlayout: default\ntitle: Photos\n---\n\nIntro.\n\n"
            + "<div class=\"photo-stream\">\n{% assign photos = site.photos %}\n</div>\n"
        try old.write(to: temp.appending(path: "photos.md"), atomically: true, encoding: .utf8)
        let page = try XCTUnwrap(PhotoStream.albumsOnPhotosPage(siteRoot: temp))
        XCTAssertEqual(page.newText, old.replacingOccurrences(of: "Intro.\n\n", with: "Intro.\n\n{% include inkwell/albums.html %}\n\n"))
        try page.apply(to: temp)
        XCTAssertNil(PhotoStream.albumsOnPhotosPage(siteRoot: temp), "added once")
    }

    func testHeadTagsGoBeforeHeadEnd() throws {
        let edit = try XCTUnwrap(Albums.headTagsEdit(siteRoot: temp, tags: ElementKit.headTags))
        XCTAssertEqual(edit.path, "_layouts/default.html")
        let text = try XCTUnwrap(edit.newText)
        XCTAssertTrue(text.contains("""
            <link rel="stylesheet" href="{{ '/assets/css/style.css' | relative_url }}">
            <link rel="stylesheet" href="{{ '/assets/css/inkwell-blocks.css' | relative_url }}">
            <script src="{{ '/assets/js/inkwell-blocks.js' | relative_url }}" defer></script>
        </head>
        """))
        try edit.apply(to: temp)
        XCTAssertNil(Albums.headTagsEdit(siteRoot: temp, tags: ElementKit.headTags))
        XCTAssertTrue(ElementKit.isLoaded(siteRoot: temp))
    }

    /// The kit's album layout and includes, rendered by the preview the way Jekyll would build them.
    func testAlbumPagesRender() throws {
        for (path, text) in ElementKit.files where Albums.kitFiles.contains(path) {
            try ContentEdit(path: path, newText: text).apply(to: temp)
        }
        for path in Albums.kitFiles { XCTAssertNotNil(ElementKit.files[path], path) }
        var config = ConfigEditing(text: try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8))
        config.addCollection("photos", output: false)
        try ContentEdit(path: "_config.yml", newText: config.text).apply(to: temp)
        func file(_ name: String, _ fields: String) -> AlbumLibrary.PhotoFile {
            .init(path: "_photos/\(name).md", text: "---\n\(fields)\n---\n")
        }
        let photos = [
            file("2026-01-01-snow", "image: /assets/photos/snow.jpg\ncaption: \"Snow <day>\"\nalt: \"A street\"\ndate: 2026-01-01"),
            file("2026-01-05-harbour", "image: /assets/photos/harbour.jpg\ncaption: \"Harbour\"\ndate: 2026-01-05\nlocation: \"Tallinn\""),
            file("2026-01-09-other", "image: /assets/photos/other.jpg\ndate: 2026-01-09"),
            file("2026-01-10-hidden", "image: /assets/photos/hidden.jpg\ndate: 2026-01-10\nalbum: estonia\nhidden: true"),
        ]
        var library = AlbumLibrary(albumsText: nil, photos: photos)
        var edits = library.create(title: "Estonia", description: "Winter, mostly.").edits
        edits += library.add(["_photos/2026-01-01-snow.md", "_photos/2026-01-05-harbour.md"], to: "estonia")
        edits += library.create(title: "Empty").edits
        for photo in photos { try ContentEdit(path: photo.path, newText: photo.text).apply(to: temp) }
        for edit in edits.merged { try edit.apply(to: temp) }
        try PhotoStream.setupPlan(siteRoot: temp, timeZone: .current).forEach { try $0.edit.apply(to: temp) }

        let site = try SiteLoader.load(temp)
        let builder = PreviewBuilder(site: site)
        let pageText = try String(contentsOf: temp.appending(path: "albums/estonia.md"), encoding: .utf8)
        let html = builder.render(text: pageText, relativePath: "albums/estonia.md", url: "/albums/estonia/").html
        XCTAssertTrue(html.contains("<h1 class=\"inkwell-album-title\">Estonia</h1>"), html)
        XCTAssertTrue(html.contains("<p class=\"inkwell-album-description\">Winter, mostly.</p>"))
        XCTAssertTrue(html.contains("2 photos"))
        XCTAssertTrue(html.contains("<nav class=\"main-nav\">"), "inside the site's own default layout")
        let harbour = try XCTUnwrap(html.range(of: "/assets/photos/harbour.jpg"))
        let snow = try XCTUnwrap(html.range(of: "/assets/photos/snow.jpg"))
        XCTAssertLessThan(harbour.lowerBound, snow.lowerBound, "newest first")
        XCTAssertFalse(html.contains("other.jpg") || html.contains("hidden.jpg"), "only the album's visible photos")
        XCTAssertTrue(html.contains("<figcaption>Snow &lt;day&gt;</figcaption>"))
        XCTAssertTrue(html.contains("href=\"#album-estonia-1\""))
        XCTAssertTrue(html.contains("<div class=\"inkwell-lightbox\" id=\"album-estonia-2\" role=\"dialog\" aria-label=\"Photo 2 of 2\">"))
        XCTAssertTrue(html.contains("aria-label=\"Previous photo\"") && html.contains("Tallinn · <time"))

        _ = library.setOldestFirst("estonia", true)
        try library.file.text.write(to: temp.appending(path: Albums.dataPath), atomically: true, encoding: .utf8)
        let oldest = PreviewBuilder(site: try SiteLoader.load(temp))
            .render(text: pageText, relativePath: "albums/estonia.md", url: "/albums/estonia/").html
        XCTAssertLessThan(try XCTUnwrap(oldest.range(of: "snow.jpg")).lowerBound, try XCTUnwrap(oldest.range(of: "harbour.jpg")).lowerBound)

        let photosPage = try XCTUnwrap(builder.page(at: "/photos/")).html
        let index = try XCTUnwrap(photosPage.range(of: "<section class=\"inkwell-albums\""))
        let stream = try XCTUnwrap(photosPage.range(of: "<div class=\"photo-stream\">"))
        XCTAssertLessThan(index.lowerBound, stream.lowerBound, "albums first, then the stream")
        XCTAssertTrue(photosPage.contains("href=\"/albums/estonia/\""))
        XCTAssertTrue(photosPage.contains("<span class=\"inkwell-albums-count\">2 photos</span>"))
        let cover = "<img src=\"/assets/photos/harbour.jpg\" alt=\"\" loading=\"lazy\">"
        XCTAssertTrue(photosPage.contains(cover), "the newest photo is the cover")
        XCTAssertTrue(photosPage.contains("<span class=\"inkwell-albums-count\">0 photos</span>"))

        let post = "---\ntitle: x\n---\n\nBefore.\n\n\(Albums.include("estonia", style: "strip"))\n\nAfter.\n"
        let inPost = builder.render(text: post, relativePath: "_notes/2026-01-01-x.md", url: "/notes/x/").html
        XCTAssertTrue(inPost.contains("<div class=\"inkwell-album inkwell-album--strip\">"))
        XCTAssertTrue(inPost.contains("<p>After.</p>"))
        XCTAssertFalse(inPost.contains("<p><li"), "the include stays one HTML block")
    }
}
