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
    /// Ids of the albums the photo is in.
    var albums: [String]
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
                              alt: values["alt"]?.string ?? "", location: values["location"]?.string ?? "",
                              hidden: values["hidden"]?.bool ?? false, albums: Albums.ids(in: values))
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

    /// The photo stream, and the site files its page needs to show albums, as one reviewable list.
    func setUpPhotos() -> [(edit: ContentEdit, reason: String)] {
        guard let site else { return [] }
        let plan = PhotoStream.setupPlan(siteRoot: site.root, timeZone: site.config.timeZone)
        let planned = Set(plan.map(\.edit.path))
        return plan + albumSiteChanges().filter { !planned.contains($0.edit.path) }
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
                    importer.folder = "assets/photos/\(String(Calendar(identifier: .gregorian).component(.year, from: date)))"
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
                                                   location: photo.location, albums: albumFilter.albumID.map { [$0] } ?? []),
                                        existing: taken, timeZone: site.config.timeZone)
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

    // MARK: Albums

    /// The albums in the order the site shows them, from `_data/albums.yml`.
    var albums: [Album] {
        guard let site else { return [] }
        return AlbumsFile(text: try? String(contentsOf: site.root.appending(path: Albums.dataPath), encoding: .utf8)).albums
    }

    /// The photos the grid shows for the chosen album, newest first.
    func shownPhotos(_ all: [PhotoEntry]) -> [PhotoEntry] {
        switch albumFilter {
        case .all: all
        case let .album(id): all.filter { $0.albums.contains(id) }
        case .none: all.filter(\.albums.isEmpty)
        }
    }

    /// The chosen photos: several after ⌘- or ⇧-clicks, otherwise the one last clicked (which may have been chosen elsewhere).
    var photoSelection: Set<String> {
        guard let anchor = selectedPhotoID else { return [] }
        return selectedPhotoIDs.contains(anchor) ? selectedPhotoIDs : [anchor]
    }

    /// A click on a photo: on its own it chooses that photo, ⌘ adds or removes it, ⇧ extends the choice to it.
    func clickPhoto(_ id: String, in shown: [PhotoEntry], modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        var selection = photoSelection
        if modifiers.contains(.command) {
            if selection.remove(id) == nil {
                selection.insert(id)
                selectedPhotoID = id
            } else if selectedPhotoID == id {
                selectedPhotoID = shown.first { selection.contains($0.id) }?.id
            }
        } else if modifiers.contains(.shift), let anchor = selectedPhotoID,
                  let a = shown.firstIndex(where: { $0.id == anchor }), let b = shown.firstIndex(where: { $0.id == id }) {
            selection.formUnion(shown[min(a, b) ... max(a, b)].map(\.id))
        } else {
            selection = [id]
            selectedPhotoID = id
        }
        selectedPhotoIDs = selection
    }

    func selectAllPhotos(_ shown: [PhotoEntry]) {
        selectedPhotoIDs = Set(shown.map(\.id))
        if !selectedPhotoIDs.contains(selectedPhotoID ?? "") { selectedPhotoID = shown.first?.id }
    }

    func clearPhotoSelection() {
        selectedPhotoIDs = []
        selectedPhotoID = nil
    }

    func showAlbum(_ filter: AlbumFilter) {
        guard filter != albumFilter else { return }
        albumFilter = filter
        clearPhotoSelection()
    }

    /// Site paths of the chosen photos, for album changes and dragging.
    func selectedPhotoPaths(_ all: [PhotoEntry]) -> [String] {
        let chosen = photoSelection
        return all.filter { chosen.contains($0.id) }.map(\.doc.relativePath)
    }

    /// Site files albums need that the site does not have yet, or has from an older Inkwell: the album layout and includes,
    /// the stylesheet and script, the tags that load them on a site with its own layouts, and the album list on the photos page.
    func albumSiteChanges() -> [(edit: ContentEdit, reason: String)] {
        guard let site else { return [] }
        let reasons = [
            "_layouts/album.html": String(localized: "The page each album gets: its title, description and photos."),
            "_includes/inkwell/album.html": String(localized: "Shows an album’s photos, on its own page or in any post."),
            "_includes/inkwell/albums.html": String(localized: "The list of albums at the top of the photos page."),
            ElementKit.stylesheet: String(localized: "Styles for albums and page elements."),
            ElementKit.script: String(localized: "Opens album photos large, with the keyboard and on phones."),
        ]
        var steps = ElementKit.changes(siteRoot: site.root).compactMap { change -> (edit: ContentEdit, reason: String)? in
            reasons[change.path].map { (ContentEdit(path: change.path, newText: change.newText), $0) }
        }
        if !ElementKit.isLoaded(siteRoot: site.root), let head = Albums.headTagsEdit(siteRoot: site.root, tags: ElementKit.headTags) {
            steps.append((head, String(localized: "Loads those styles and the script on every page.")))
        }
        if let page = PhotoStream.albumsOnPhotosPage(siteRoot: site.root) {
            steps.append((page, String(localized: "Shows the albums above the photo stream.")))
        }
        return steps
    }

    /// Writes album changes into the site; they stay unpublished until the next publish, like other edits.
    func applyAlbumEdits(_ edits: [ContentEdit]) {
        guard let site, !edits.isEmpty else { return }
        do {
            for edit in edits.merged { try edit.apply(to: site.root) }
        } catch {
            errorMessage = String(localized: "The album could not be saved: \(error.localizedDescription)")
        }
        mediaRevision += 1
        reloadSite()
    }

    func changeAlbums(_ change: (inout AlbumLibrary) -> [ContentEdit]) {
        guard let site else { return }
        var library = AlbumLibrary.load(siteRoot: site.root)
        applyAlbumEdits(change(&library))
    }

    /// A new album with its page and the site files it needs, holding `paths` if any. Returns its id.
    @discardableResult
    func createAlbum(title: String, description: String, adding paths: [String] = []) -> String? {
        guard let site else { return nil }
        var library = AlbumLibrary.load(siteRoot: site.root)
        let (id, created) = library.create(title: title, description: description)
        let added = library.add(paths, to: id)
        applyAlbumEdits(albumSiteChanges().map(\.edit) + created + added)
        albumFilter = .album(id)
        if paths.isEmpty { clearPhotoSelection() }
        return id
    }

    func addPhotos(_ paths: [String], to id: String) {
        changeAlbums { $0.add(paths, to: id) }
    }

    func removePhotos(_ paths: [String], from id: String) {
        changeAlbums { $0.remove(paths, from: id) }
        if albumFilter == .album(id) { clearPhotoSelection() }
    }

    /// Asks first, and says the photos are kept.
    func deleteAlbum(_ album: Album) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the album “\(album.title)”?")
        alert.informativeText = String(localized: """
            The photos stay in your photo stream. The album and its page leave the site when you next publish.
            """)
        alert.addButton(withTitle: String(localized: "Delete Album"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeAlbums { $0.delete(album.id) }
        if albumFilter == .album(album.id) { showAlbum(.all) }
    }

    /// Moves an album to just before another one, or to the end.
    func moveAlbum(_ id: String, before target: String?) {
        var ids = albums.map(\.id).filter { $0 != id }
        ids.insert(id, at: target.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
        changeAlbums { $0.reorder(ids) }
    }

    /// The picture that stands for an album: its cover, or its newest photo.
    func coverURL(for album: Album, photos: [PhotoEntry]) -> URL? {
        let image = album.cover.isEmpty ? photos.first { $0.albums.contains(album.id) }?.image : album.cover
        return image.flatMap(fileURL(forSitePath:))
    }

    /// The album's page as the site will show it, from the preview's Liquid and layouts.
    func albumPreview(_ album: Album) -> PreviewPage? {
        guard let site, let builder = previewBuilder else { return nil }
        let text = (try? String(contentsOf: site.root.appending(path: album.pagePath), encoding: .utf8))
            ?? Albums.pageText(id: album.id, title: album.title)
        return builder.render(text: text, relativePath: album.pagePath, url: site.config.baseurl + album.url)
    }

    /// The include that shows an album, in place of a gallery of dropped pictures, with the site files it needs.
    func insertAlbum(_ id: String, replacing gallery: PendingGallery) {
        applyAlbumEdits(albumSiteChanges().map(\.edit))
        textView?.insertBlock(Albums.include(id), at: gallery.insertAt)
        cancelGallery()
        refreshChanges()
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

enum AlbumFilter: Hashable {
    case all
    case album(String)
    /// Photos in no album.
    case none

    var albumID: String? {
        if case let .album(id) = self { return id }
        return nil
    }
}

struct NewAlbumRequest: Identifiable {
    let id = UUID()
    /// Photos the new album starts with.
    var photoPaths: [String] = []
}
