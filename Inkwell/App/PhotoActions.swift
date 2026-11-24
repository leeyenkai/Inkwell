import AppKit
import ImageIO
import InkwellKit

/// Small images for grids, made with ImageIO and kept in memory.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, size: CGFloat = 360) -> NSImage? {
        let key = "\(Int(size)) \(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
              ] as CFDictionary) else { return NSImage(contentsOf: url) }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Replacing a picture is rare, so every size of every picture is dropped.
    func forget(_: URL) { cache.removeAllObjects() }
}

struct PhotoEntry: Identifiable, Hashable {
    var doc: SiteDocument
    var image: String
    var caption: String
    var alt: String
    var location: String
    var hidden: Bool
    var id: String { doc.id }
}

extension AppModel {
    var photosSetUp: Bool { site.map(PhotoStream.isSetUp) ?? false }
    var showsPhotoGrid: Bool { sidebarSelection == .section(PhotoStream.collection) && photosSetUp }

    /// The photos collection's entries, newest first.
    var photos: [PhotoEntry] {
        guard let site else { return [] }
        return site.documents(in: PhotoStream.collection).compactMap { doc in
            guard let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { return nil }
            let values = FrontMatterDocument(text: text).values
            return PhotoEntry(doc: doc, image: values["image"]?.string ?? "", caption: values["caption"]?.string ?? "",
                              alt: values["alt"]?.string ?? "", location: values["location"]?.string ?? "", hidden: values["hidden"]?.bool ?? false)
        }
    }

    /// A site path such as `/assets/photos/x.jpg` (with or without baseurl or Liquid) as a file on this Mac.
    func fileURL(forSitePath path: String) -> URL? {
        guard let site else { return nil }
        var plain = ContentChecks.plainPath(path)
        if !site.config.baseurl.isEmpty, plain.hasPrefix(site.config.baseurl) { plain = String(plain.dropFirst(site.config.baseurl.count)) }
        guard !plain.hasPrefix("http") else { return nil }
        let url = site.root.appending(path: String(plain.drop { $0 == "/" }))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setUpPhotos() -> [(edit: ContentEdit, reason: String)] {
        guard let site else { return [] }
        return PhotoStream.setupPlan(siteRoot: site.root, timeZone: site.config.timeZone)
    }

    func applyPhotoSetup(_ plan: [(edit: ContentEdit, reason: String)]) {
        guard let site else { return }
        do {
            for step in plan { try step.edit.apply(to: site.root) }
        } catch {
            errorMessage = String(localized: "Photos could not be set up: \(error.localizedDescription)")
        }
        design?.reload()
        sidebarSelection = .section(PhotoStream.collection)
        reloadSite()
    }

    // MARK: Adding photos

    struct PendingPhoto: Identifiable {
        let id = UUID()
        var image: ImportedImage
        var date: Date
        var caption = ""
        var alt = ""
        var location = ""
    }

    /// Copies pictures into `assets/photos/<year>/`, cleaned like post images, then asks for captions.
    func importPhotos(_ urls: [URL]) {
        guard let site else { return }
        let root = site.root
        Task {
            let imported: [PendingPhoto] = await Task.detached {
                urls.compactMap { url in
                    let date = ImageImport.dateTaken(url) ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    var importer = ImageImport.app
                    importer.folder = "assets/photos/\(Calendar.current.component(.year, from: date))"
                    let base = Slug.make(url.deletingPathExtension().lastPathComponent, maxWords: 5)
                    guard let image = try? importer.importImage(at: url, siteRoot: root, slug: base == "untitled" ? "photo" : base) else { return nil }
                    return PendingPhoto(image: image, date: date)
                }
            }.value
            let failed = urls.count - imported.count
            if failed > 0 { errorMessage = String(localized: "\(failed) of the files could not be read as pictures.") }
            if !imported.isEmpty { pendingPhotos = imported }
        }
    }

    func savePendingPhotos(_ pending: [PendingPhoto]) {
        guard let site else { return }
        var taken = Set(site.documents(in: PhotoStream.collection).map(\.relativePath))
        for photo in pending {
            let edit = PhotoStream.file(for: .init(image: photo.image.sitePath, caption: photo.caption, alt: photo.alt, date: photo.date,
                                                   location: photo.location), existing: taken, timeZone: site.config.timeZone)
            taken.insert(edit.path)
            try? edit.apply(to: site.root)
        }
        pendingPhotos = nil
        reloadSite()
    }

    func cancelPendingPhotos() {
        for photo in pendingPhotos ?? [] { try? FileManager.default.removeItem(at: photo.image.fileURL) }
        pendingPhotos = nil
    }

    func updatePhoto(_ entry: PhotoEntry, key: String, value: String?) {
        guard var doc = (try? String(contentsOf: entry.doc.fileURL, encoding: .utf8)).map(FrontMatterDocument.init) else { return }
        let raw: String? = switch key {
        case "hidden": value == "true" ? "true" : nil
        case "date": value
        default: value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : YAMLFormat.quoted($0) }
        }
        doc.set(key, raw: raw, order: ["image", "caption", "alt", "date", "location", "hidden"])
        try? Data(doc.text.utf8).write(to: entry.doc.fileURL, options: .atomic)
        reloadSite()
    }

    /// Removes the photo's file, and its picture when nothing else uses it.
    func deletePhoto(_ entry: PhotoEntry) {
        guard let site else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete this photo?")
        alert.informativeText = String(localized: "It leaves the photo stream when you next publish. GitHub keeps its history.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: entry.doc.fileURL)
        if let image = fileURL(forSitePath: entry.image) {
            let relative = String(image.standardizedFileURL.path.dropFirst(site.root.standardizedFileURL.path.count + 1))
            if MediaLibrary.scan(siteRoot: site.root).first(where: { $0.path == relative })?.usedBy.isEmpty == true {
                try? FileManager.default.removeItem(at: image)
            }
        }
        selectedPhotoID = nil
        reloadSite()
    }

    // MARK: Galleries

    /// Several pictures for a post at once become a gallery block, after alt text for each.
    func importGallery(_ urls: [URL], at location: Int) {
        guard let site, let editor else { return }
        let slug = Filename.parse(editor.document.filename).slug
        let root = site.root
        Task {
            let images = await Task.detached {
                urls.compactMap { try? ImageImport.app.importImage(at: $0, siteRoot: root, slug: slug == "untitled" ? "image" : slug) }
            }.value
            guard !images.isEmpty else { return }
            pendingGallery = PendingGallery(images: images, alts: images.map { _ in "" }, insertAt: location)
        }
    }

    struct PendingGallery: Identifiable {
        let id = UUID()
        var images: [ImportedImage]
        var alts: [String]
        var insertAt: Int
    }

    func insertGallery(_ gallery: PendingGallery) {
        var html = "<div class=\"gallery\">\n"
        for (image, alt) in zip(gallery.images, gallery.alts) {
            let escaped = alt.replacingOccurrences(of: "\"", with: "&quot;")
            html += "  <img src=\"{{ '\(image.sitePath)' | relative_url }}\" alt=\"\(escaped)\" loading=\"lazy\">\n"
        }
        html += "</div>"
        textView?.insertBlock(html, at: gallery.insertAt)
        pendingGallery = nil
        refreshChanges()
    }

    func cancelGallery() {
        for image in pendingGallery?.images ?? [] { try? FileManager.default.removeItem(at: image.fileURL) }
        pendingGallery = nil
    }
}
