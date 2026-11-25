import Foundation
import InkwellKit
import Observation

/// The open post: its front matter (edited through Properties) and body (edited in the text view).
/// Changes are saved shortly after typing stops: drafts to the draft folder, published posts to the site folder,
/// where they stay as an unpublished edit until Update.
@Observable
final class EditorDocument {
    var document: SiteDocument
    private(set) var frontMatter: FrontMatterDocument
    let fields: [FieldSpec]
    private(set) var issues: [Issue] = []
    var focusTitle = false
    /// Bumped when the text changes from outside the text view (Source toggle, reload), so the view reloads it.
    private(set) var revision = 0

    /// Set when the file could not be read; the editor then shows the error and never saves.
    private(set) var loadError: String?
    /// Set when the file changed on disk while there were unsaved edits here.
    private(set) var diskConflict: String?

    private let site: Site
    private weak var model: AppModel?
    private var lastSaved: String
    private var saveTask: Task<Void, Never>?
    private var retired = false

    init(document: SiteDocument, site: Site, model: AppModel) {
        self.document = document
        self.site = site
        self.model = model
        var text = ""
        do {
            text = try String(contentsOf: document.fileURL, encoding: .utf8)
        } catch {
            loadError = String(localized: "“\(document.filename)” could not be opened: \(error.localizedDescription)")
        }
        frontMatter = FrontMatterDocument(text: text)
        lastSaved = text
        fields = document.isPage ? [] : model.schema(for: document.sectionID)
        validate()
    }

    /// Stops all saving, for an editor whose file is being published, moved or deleted.
    func retire() {
        saveTask?.cancel()
        retired = true
    }

    /// Picks up a change made outside the editor (a sync, another app). Unsaved edits here are never overwritten.
    func reloadIfChangedOnDisk() {
        guard !retired, loadError == nil, let disk = try? String(contentsOf: document.fileURL, encoding: .utf8), disk != lastSaved else { return }
        if frontMatter.text == lastSaved {
            frontMatter = FrontMatterDocument(text: disk)
            lastSaved = disk
            validate()
            revision += 1
        } else {
            diskConflict = disk
        }
    }

    func resolveDiskConflict(keepMine: Bool) {
        guard let disk = diskConflict else { return }
        diskConflict = nil
        if keepMine {
            lastSaved = disk
            saveNow()
        } else {
            frontMatter = FrontMatterDocument(text: disk)
            lastSaved = disk
            validate()
            revision += 1
        }
    }

    /// True when the file changed elsewhere and the text here differs from both that version and the last save, so
    /// closing the editor now would lose one of them.
    var conflictNeedsChoice: Bool {
        guard let disk = diskConflict else { return false }
        return frontMatter.text != disk && frontMatter.text != lastSaved
    }

    /// Settles a conflict that loses nothing: the text here already matches the other version, or was never edited.
    func resolveConflictIfTrivial() {
        guard let disk = diskConflict, !conflictNeedsChoice else { return }
        resolveDiskConflict(keepMine: frontMatter.text == disk)
    }

    var body: String {
        get { frontMatter.body }
        set {
            guard newValue != frontMatter.body else { return }
            frontMatter.body = newValue
            changed()
        }
    }

    var fullText: String { frontMatter.text }

    func setFullText(_ text: String) {
        guard text != frontMatter.text else { return }
        frontMatter = FrontMatterDocument(text: text)
        changed()
    }

    var isCollectionPost: Bool { !document.isPage }

    // MARK: Fields

    var fieldOrder: [String] { fields.map(\.key) }

    func string(_ key: String) -> String {
        guard let value = frontMatter.value(key) else { return "" }
        if case let .list(items) = value { return items.compactMap(\.string).joined(separator: ", ") }
        return value.string ?? ""
    }

    func setString(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let keepEmpty = key == "title"
        frontMatter.set(key, raw: trimmed.isEmpty && !keepEmpty ? nil : YAMLFormat.quoted(value), order: fieldOrder)
        changed()
    }

    /// A plain value (a site path, for example) written as it is, or removed with nil.
    func setRaw(_ key: String, _ raw: String?) {
        frontMatter.set(key, raw: raw, order: fieldOrder)
        changed()
    }

    func date(_ key: String) -> Date? {
        frontMatter.value(key)?.string.flatMap { SiteDate.parse($0, timeZone: site.config.timeZone) }
    }

    var timeZone: TimeZone { site.config.timeZone }
    var publishesFutureNow: Bool { Schedule.publishesFutureNow(site.config) }

    /// Whether the value carries a time of day, which is kept when the date changes.
    func hasTime(_ key: String) -> Bool {
        frontMatter.value(key)?.string?.contains(":") ?? false
    }

    func setDate(_ key: String, _ date: Date?, withTime: Bool? = nil) {
        let zone = site.config.timeZone
        let timed = withTime ?? hasTime(key)
        frontMatter.set(key, raw: date.map { timed ? YAMLFormat.dateTime($0, timeZone: zone) : YAMLFormat.date($0, timeZone: zone) }, order: fieldOrder)
        changed()
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        frontMatter.value(key)?.bool ?? fallback
    }

    func setBool(_ key: String, _ value: Bool) {
        frontMatter.set(key, raw: YAMLFormat.bool(value), order: fieldOrder)
        changed()
    }

    func tags(_ key: String) -> [String] {
        frontMatter.value(key)?.list?.compactMap(\.string) ?? []
    }

    func setTags(_ key: String, _ text: String) {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        frontMatter.set(key, raw: items.isEmpty ? nil : YAMLFormat.list(items), order: fieldOrder)
        changed()
    }

    /// Fields in the file that the section's schema does not know, kept exactly as written.
    var otherKeys: [String] {
        let known = Set(fields.map(\.key)).union(["layout", "description", "image"])
        return frontMatter.keys.filter { !known.contains($0) }
    }

    var title: String {
        get { string("title") }
        set { setString("title", newValue) }
    }

    var displayURL: String {
        Permalink.display(currentURL, config: site.config)
    }

    /// The address as Jekyll will build it from the current fields (permalink, categories, slug, date).
    var currentURL: String {
        guard document.relativePath.hasPrefix("_") else { return document.url }
        let values = frontMatter.values
        let date = SiteLoader.date(values: values, filename: document.filename, config: site.config) ?? date("date")
        return SiteLoader.url(relativePath: document.relativePath, values: values, date: date, config: site.config)
    }

    var wordCount: Int { ContentChecks.wordCount(frontMatter.body) }
    var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }

    // MARK: Saving

    private func changed() {
        validate()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func reloadFromView() {
        revision += 1
    }

    private func validate() {
        issues = Validation.frontMatter(frontMatter, filename: document.filename, inCollection: isCollectionPost)
    }

    func saveNow() {
        saveTask?.cancel()
        let text = frontMatter.text
        guard !retired, loadError == nil, diskConflict == nil, text != lastSaved else { return }
        // A sync may have written GitHub's version since the last save: never write over it unseen.
        if let disk = try? String(contentsOf: document.fileURL, encoding: .utf8), disk != lastSaved, disk != text {
            diskConflict = disk
            return
        }
        do {
            try Data(text.utf8).write(to: document.fileURL, options: .atomic)
            lastSaved = text
        } catch {
            model?.errorMessage = String(localized: "Could not save: \(error.localizedDescription)")
            return
        }
        if document.origin == .localDraft {
            renameDraftIfNeeded()
        } else {
            model?.documentSaved(document, text: text)
        }
    }

    private func renameDraftIfNeeded() {
        guard let model, let collection = document.relativePath.hasPrefix("_") ? String(document.relativePath.dropFirst().prefix { $0 != "/" }) : nil
        else { return }
        let date = date("date") ?? Date()
        let slug = Slug.make(title)
        let wanted = Filename.make(date: date, slug: slug, timeZone: timeZone)
        guard wanted != document.filename,
              let free = model.freeDraftFilename(collection: collection, date: date, slug: slug, current: document.fileURL),
              free != document.filename,
              let target = model.draftURL(collection: collection, filename: free) else {
            model.documentSaved(document, text: frontMatter.text)
            return
        }
        do {
            try FileManager.default.moveItem(at: document.fileURL, to: target)
            document.fileURL = target
            document.relativePath = "_\(collection)/\(free)"
            document.id = "draft:\(target.path)"
            validate()
            model.draftRenamed(to: target, editor: self)
        } catch {
            model.documentSaved(document, text: frontMatter.text)
        }
    }
}
