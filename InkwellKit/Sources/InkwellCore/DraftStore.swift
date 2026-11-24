import CryptoKit
import Foundation

/// Drafts live outside the site's repository until they are published, so a public repository never shows them.
/// Layout: `<base>/<site key>/<collection>/<YYYY-MM-DD-slug>.md`, where the filename is the one the post will get.
public struct DraftStore: Sendable {
    public let root: URL

    /// Drafts for a site in a local folder, keyed by the folder.
    public init(base: URL, siteRoot: URL) {
        let digest = SHA256.hash(data: Data(siteRoot.standardizedFileURL.path.utf8))
        let key = siteRoot.lastPathComponent + "-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        root = base.appending(path: key, directoryHint: .isDirectory)
    }

    /// Drafts for a site on GitHub, keyed by the repository, so they survive a fresh download.
    public init(base: URL, key: String) {
        root = base.appending(path: key, directoryHint: .isDirectory)
    }

    public func drafts(for site: Site) -> [SiteDocument] {
        let fm = FileManager.default
        var result: [SiteDocument] = []
        for section in site.sections {
            guard let collection = section.collectionName else { continue }
            let folder = root.appending(path: collection, directoryHint: .isDirectory)
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "md" {
                if let doc = SiteLoader.document(at: file, relativePath: "_\(collection)/\(file.lastPathComponent)", sectionID: section.id,
                                                 config: site.config, origin: .localDraft) {
                    result.append(doc)
                }
            }
        }
        return result
    }

    public func url(collection: String, filename: String) -> URL {
        root.appending(path: collection, directoryHint: .isDirectory).appending(path: filename)
    }

    /// Writes a new draft, choosing a filename that is free both here and in the site.
    public func create(collection: String, title: String, date: Date, text: String, siteRoot: URL, timeZone: TimeZone = .current) throws -> URL {
        let folder = root.appending(path: collection, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = freeFilename(collection: collection, date: date, slug: Slug.make(title), siteRoot: siteRoot, timeZone: timeZone)
        let url = folder.appending(path: filename)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    public func freeFilename(collection: String, date: Date, slug: String, siteRoot: URL, current: URL? = nil,
                             timeZone: TimeZone = .current) -> String {
        let fm = FileManager.default
        var candidate = Filename.make(date: date, slug: slug, timeZone: timeZone)
        var n = 2
        while true {
            let draft = url(collection: collection, filename: candidate)
            let published = siteRoot.appending(path: "_\(collection)").appending(path: candidate)
            let takenHere = fm.fileExists(atPath: draft.path) && draft.standardizedFileURL != current?.standardizedFileURL
            if !takenHere, !fm.fileExists(atPath: published.path) { return candidate }
            candidate = Filename.make(date: date, slug: "\(slug)-\(n)", timeZone: timeZone)
            n += 1
        }
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
