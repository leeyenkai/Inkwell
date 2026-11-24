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

    private let site: Site
    private weak var model: AppModel?
    private var lastSaved: String
    private var saveTask: Task<Void, Never>?

    init(document: SiteDocument, site: Site, model: AppModel) {
        self.document = document
        self.site = site
        self.model = model
        let text = (try? String(contentsOf: document.fileURL, encoding: .utf8)) ?? ""
        frontMatter = FrontMatterDocument(text: text)
        lastSaved = text
        fields = document.isPage ? [] : model.schema(for: document.sectionID)
        validate()
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

    func date(_ key: String) -> Date? {
        frontMatter.value(key)?.string.flatMap { SiteDate.parse($0) }
    }

    func setDate(_ key: String, _ date: Date?) {
        frontMatter.set(key, raw: date.map { YAMLFormat.date($0) }, order: fieldOrder)
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
        let known = Set(fields.map(\.key)).union(["layout"])
        return frontMatter.keys.filter { !known.contains($0) }
    }

    var title: String {
        get { string("title") }
        set { setString("title", newValue) }
    }

    var displayURL: String {
        Permalink.display(currentURL, config: site.config)
    }

    var currentURL: String {
        guard let collection = document.relativePath.hasPrefix("_") ? String(document.relativePath.dropFirst().prefix { $0 != "/" }) : nil else {
            return document.url
        }
        return Permalink.url(collection: collection, filename: document.filename, date: date("date"), config: site.config)
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
        guard text != lastSaved else { return }
        do {
            try Data(text.utf8).write(to: document.fileURL, options: .atomic)
            lastSaved = text
        } catch {
            model?.errorMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        if document.origin == .localDraft {
            renameDraftIfNeeded()
        } else {
            model?.documentSaved(document)
        }
    }

    private func renameDraftIfNeeded() {
        guard let model, let collection = document.relativePath.hasPrefix("_") ? String(document.relativePath.dropFirst().prefix { $0 != "/" }) : nil
        else { return }
        let date = date("date") ?? Date()
        let slug = Slug.make(title)
        let wanted = Filename.make(date: date, slug: slug)
        guard wanted != document.filename,
              let free = model.freeDraftFilename(collection: collection, date: date, slug: slug, current: document.fileURL),
              free != document.filename,
              let target = model.draftURL(collection: collection, filename: free) else {
            model.documentSaved(document)
            return
        }
        do {
            try FileManager.default.moveItem(at: document.fileURL, to: target)
            let old = document
            document.fileURL = target
            document.relativePath = "_\(collection)/\(free)"
            document.id = "draft:\(target.path)"
            validate()
            model.draftRenamed(from: old, to: target)
        } catch {
            model.documentSaved(document)
        }
    }
}
