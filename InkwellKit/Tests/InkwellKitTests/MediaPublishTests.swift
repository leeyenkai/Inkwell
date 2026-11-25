import CoreGraphics
import Foundation
import ImageIO
@testable import InkwellMedia
@testable import InkwellPublish
import UniformTypeIdentifiers
import XCTest

final class ImageImportTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func makePhoto(named name: String, width: Int, height: Int) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = temp.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 59.437, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 24.7536, kCGImagePropertyGPSLongitudeRef: "E"]
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6,
                                           kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImportStripsLocationResizesAndNames() throws {
        let photo = try makePhoto(named: "IMG_4821.jpg", width: 3200, height: 2000)
        XCTAssertTrue(ImageImport.hasLocation(photo))
        let site = temp.appending(path: "site", directoryHint: .isDirectory)
        let result = try ImageImport().importImage(at: photo, siteRoot: site, slug: "morality")
        XCTAssertEqual(result.sitePath, "/assets/images/morality.jpg")
        XCTAssertFalse(ImageImport.hasLocation(result.fileURL))
        XCTAssertTrue(result.removedLocation)
        // Orientation 6 turns the picture upright: the long edge is now the height.
        XCTAssertEqual(max(result.pixelWidth, result.pixelHeight), 2400)
        XCTAssertGreaterThan(result.pixelHeight, result.pixelWidth)
        XCTAssertEqual(result.markdown(alt: "Worm", useRelativeURL: true), "![Worm]({{ '/assets/images/morality.jpg' | relative_url }})")

        let second = try makePhoto(named: "Guinea Worm.jpg", width: 400, height: 300)
        let named = try ImageImport().importImage(at: second, siteRoot: site, slug: "morality")
        XCTAssertEqual(named.sitePath, "/assets/images/morality-guinea-worm.jpg")
        let again = try ImageImport().importImage(at: photo, siteRoot: site, slug: "morality")
        XCTAssertEqual(again.sitePath, "/assets/images/morality-2.jpg")
    }

    func testReplaceKeepsPathAndStripsLocation() throws {
        let site = temp.appending(path: "site", directoryHint: .isDirectory)
        let first = try ImageImport().importImage(at: makePhoto(named: "a.jpg", width: 400, height: 300), siteRoot: site, slug: "post")
        let replaced = try ImageImport().replace(first.fileURL, with: makePhoto(named: "b.jpg", width: 900, height: 600))
        XCTAssertEqual(replaced.fileURL, first.fileURL)
        XCTAssertEqual(max(replaced.pixelWidth, replaced.pixelHeight), 900)
        XCTAssertFalse(ImageImport.hasLocation(first.fileURL))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: first.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [first.fileURL.lastPathComponent])
    }

    func testDateTakenReadsCameraDate() throws {
        let url = temp.appending(path: "dated.jpg")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2025:12:01 14:30:00"]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let date = try XCTUnwrap(ImageImport.dateTaken(url))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day, .hour], from: date),
                       DateComponents(year: 2025, month: 12, day: 1, hour: 14))
    }
}

final class GitTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testPublishCommitsOnlyNamedFilesAndPushes() async throws {
        let remote = temp.appending(path: "remote.git"), work = temp.appending(path: "work")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let bare = try XCTUnwrap(Git(root: remote))
        try await bare.run(["init", "--bare", "-b", "main"])
        let git = try XCTUnwrap(Git(root: work))
        try await git.run(["init", "-b", "main"])
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["remote", "add", "origin", remote.path])
        try "base\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git.run(["add", "README.md"])
        try await git.run(["commit", "-m", "init"])
        try await git.run(["push", "-u", "origin", "main"])

        try FileManager.default.createDirectory(at: work.appending(path: "_notes"), withIntermediateDirectories: true)
        try "---\ntitle: \"New\"\n---\n".write(to: work.appending(path: "_notes/2026-06-20-new.md"), atomically: true, encoding: .utf8)
        try "unrelated edit\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let status = try await git.status()
        XCTAssertEqual(status["_notes/2026-06-20-new.md"], .untracked)
        XCTAssertEqual(status["README.md"], .modified)

        let result = try await git.publish(paths: ["_notes/2026-06-20-new.md"], message: "Publish: New")
        XCTAssertTrue(result.pushed)
        XCTAssertEqual(result.branch, "main")
        let files = try await git.run(["show", "--name-only", "--format=", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(files, "_notes/2026-06-20-new.md")
        let after = try await git.status()
        XCTAssertEqual(after["README.md"], .modified)
        XCTAssertNil(after["_notes/2026-06-20-new.md"])
        let remoteHead = try await bare.run(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteHead, result.commit)
    }

    func testEarlierLocalCommitsAreNotPushedWithAPost() async throws {
        let remote = temp.appending(path: "remote.git"), work = temp.appending(path: "work"), other = temp.appending(path: "other")
        for url in [remote, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let bare = try XCTUnwrap(Git(root: remote))
        try await bare.run(["init", "--bare", "-b", "main"])
        let git = try XCTUnwrap(Git(root: work))
        try await git.run(["init", "-b", "main"])
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["remote", "add", "origin", remote.path])
        try "base\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git.run(["add", "README.md"])
        try await git.run(["commit", "-m", "init"])
        try await git.run(["push", "-u", "origin", "main"])

        // Work in progress committed by hand stays here.
        try "wip\n".write(to: work.appending(path: "wip.md"), atomically: true, encoding: .utf8)
        try await git.run(["add", "wip.md"])
        try await git.run(["commit", "-m", "wip"])
        try "post\n".write(to: work.appending(path: "post.md"), atomically: true, encoding: .utf8)
        let result = try await git.publish(paths: ["post.md"], message: "Publish: post")
        XCTAssertFalse(result.pushed)
        XCTAssertNotNil(result.pushError)
        let remoteLog = try await bare.run(["log", "--format=%s", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteLog, "init")

        // An edit here to a file GitHub also changed is never pulled over.
        try await git.run(["push", "origin", "main"])
        let clone = try XCTUnwrap(Git(root: temp))
        try await clone.run(["clone", "-q", remote.path, other.path])
        let otherGit = try XCTUnwrap(Git(root: other))
        try await otherGit.run(["config", "user.email", "test@example.com"])
        try await otherGit.run(["config", "user.name", "Test"])
        try "from elsewhere\n".write(to: other.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await otherGit.run(["commit", "-qam", "remote edit"])
        try await otherGit.run(["push", "-q", "origin", "main"])
        try "edited here\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git.run(["fetch", "-q", "origin", "main"])
        do {
            try await git.refuseOverlap(branch: "main")
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertEqual(try String(contentsOf: work.appending(path: "README.md"), encoding: .utf8), "edited here\n")
    }

    func testGitHubRepositoryParsing() {
        XCTAssertEqual(Git.gitHubRepository(from: "https://github.com/leeyenkai/leeyenkai.github.io.git")?.name, "leeyenkai.github.io")
        XCTAssertEqual(Git.gitHubRepository(from: "git@github.com:owner/site.git")?.owner, "owner")
        XCTAssertNil(Git.gitHubRepository(from: "/tmp/remote.git"))
    }
}
