import Foundation
@testable import InkwellCore
import XCTest

final class PhotosTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-photos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testSetupTurnsHandWrittenPageIntoLoop() throws {
        let page = """
        ---
        layout: default
        title: Photos
        ---

        # Photos

        Some I like.

        <div class="photo-stream">
        <!-- <div class="photo-item"><img src="/commented.jpg"></div> -->
        <div class="photo-item">
          <img src="/assets/images/harbour.jpg" alt="A harbour">
          <p class="photo-caption">Morning in the harbour</p>
          <time>Jan 14, 2026</time>
        </div>
        </div>

        """
        try page.write(to: temp.appending(path: "photos.md"), atomically: true, encoding: .utf8)
        let tz = TimeZone(identifier: "UTC")!
        let plan = PhotoStream.setupPlan(siteRoot: temp, timeZone: tz)
        XCTAssertEqual(plan.map(\.edit.path), ["_config.yml", "photos.md", "_photos/2026-01-14-harbour.md"], "the menu already lists photos")
        for step in plan { try step.edit.apply(to: temp) }

        let config = SiteConfig(yaml: YAML.parse(try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8)))
        XCTAssertEqual(config.collections.last?.name, "photos")
        XCTAssertEqual(config.collections.last?.output, false)
        let newPage = try String(contentsOf: temp.appending(path: "photos.md"), encoding: .utf8)
        let expected = "---\nlayout: default\ntitle: Photos\n---\n\n# Photos\n\nSome I like.\n\n<div class=\"photo-stream\">\n{% assign photos"
        XCTAssertTrue(newPage.hasPrefix(expected))
        let photo = FrontMatterDocument(text: try String(contentsOf: temp.appending(path: "_photos/2026-01-14-harbour.md"), encoding: .utf8))
        XCTAssertEqual(photo.value("image"), .string("/assets/images/harbour.jpg"))
        XCTAssertEqual(photo.value("caption"), .string("Morning in the harbour"))
        XCTAssertEqual(photo.value("alt"), .string("A harbour"))
        XCTAssertEqual(PhotoStream.setupPlan(siteRoot: temp, timeZone: tz).count, 0, "setting up twice changes nothing")
        XCTAssertTrue(PhotoStream.isSetUp(site: try SiteLoader.load(temp)))
    }

    func testPhotoFilesAndCollectionsBlock() {
        let date = SiteDate.parse("2026-02-03", timeZone: TimeZone(identifier: "UTC")!)!
        let edit = PhotoStream.file(for: .init(image: "/assets/photos/2026/Tallinn Snow.jpg", caption: "Snow \"day\"", date: date, location: "Tallinn"),
                                    existing: ["_photos/2026-02-03-tallinn-snow.md"], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(edit.path, "_photos/2026-02-03-tallinn-snow-2.md")
        XCTAssertEqual(edit.newText,
                       "---\nimage: /assets/photos/2026/Tallinn Snow.jpg\ncaption: \"Snow \\\"day\\\"\"\ndate: 2026-02-03\nlocation: \"Tallinn\"\n---\n")
        var config = ConfigEditing(text: "title: x\ncollections:\n  notes:\n    output: true\n\nlang: en\n")
        XCTAssertTrue(config.addCollection("photos", output: false))
        XCTAssertEqual(config.text, "title: x\ncollections:\n  notes:\n    output: true\n  photos:\n    output: false\n\nlang: en\n")
        XCTAssertFalse(config.addCollection("notes", output: true))
    }

    func testMediaLibraryFindsUses() throws {
        try Data([0xFF, 0xD8, 0xFF]).write(to: temp.appending(path: "assets/images/test.jpg"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: temp.appending(path: "assets/images/orphan.jpg"))
        let items = MediaLibrary.scan(siteRoot: temp)
        XCTAssertEqual(items.first { $0.path == "assets/images/test.jpg" }?.usedBy, ["_notes/2026-06-20-sample-essay.md"])
        XCTAssertEqual(items.first { $0.path == "assets/images/orphan.jpg" }?.usedBy, [])
    }
}
