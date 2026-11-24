import AppKit
import InkwellKit
import Observation
import SwiftUI

enum DocumentStatus: Equatable {
    case published
    case draft
    case edited
    case notCommitted
    case hidden

    var symbol: String {
        switch self {
        case .published: "circle"
        case .draft, .notCommitted: "circle.lefthalf.filled"
        case .edited: "pencil.circle.fill"
        case .hidden: "eye.slash.circle"
        }
    }

    var label: String {
        switch self {
        case .published: "Published"
        case .draft: "Draft"
        case .edited: "Edited"
        case .notCommitted: "Not published"
        case .hidden: "Hidden"
        }
    }

    var color: Color {
        switch self {
        case .published: .secondary
        case .draft, .notCommitted: .orange
        case .edited: .accentColor
        case .hidden: .secondary
        }
    }
}

enum SidebarSelection: Hashable {
    case section(String)
    case drafts
}

@Observable
final class AppModel {
    var site: Site?
    var loadError: String?
    var drafts: [SiteDocument] = []
    var gitStatus: [String: FileStatus] = [:]
    var lastCommitDates: [String: Date] = [:]
    var hasGit = false
    var remote: String?

    var sidebarSelection: SidebarSelection? = .section("notes")
    var selectedDocumentID: String?
    var editor: EditorDocument?
    var searchText = ""

    var showPreview = false
    var showSource = false
    var showProperties = true
    var previewWidth: PreviewWidth = .desktop
    var publishSheet: PublishSession?
    var pendingImage: PendingImage?
    var errorMessage: String?

    private(set) var previewBuilder: PreviewBuilder?
    weak var textView: InkwellTextView?
    private var draftStore: DraftStore?
    private var statusTask: Task<Void, Never>?

    static let recentSiteKey = "RecentSitePath"

    enum PreviewWidth: String, CaseIterable {
        case desktop = "Desktop"
        case phone = "Phone"
    }

    // MARK: Loading

    func openSitePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your site’s folder: the one with _config.yml in it."
        panel.prompt = "Open Site"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ root: URL) {
        do {
            let site = try SiteLoader.load(root)
            self.site = site
            loadError = nil
            UserDefaults.standard.set(root.path, forKey: Self.recentSiteKey)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Inkwell/Drafts", directoryHint: .isDirectory)
            draftStore = DraftStore(base: support, siteRoot: root)
            previewBuilder = PreviewBuilder(site: site)
            reloadDrafts()
            if let first = site.sections.first(where: { $0.collectionName != nil }) ?? site.sections.first {
                if case let .section(id)? = sidebarSelection, site.section(id) != nil {} else { sidebarSelection = .section(first.id) }
            }
            refreshGit()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reloadSite() {
        guard let root = site?.root else { return }
        let selected = selectedDocumentID
        if let site = try? SiteLoader.load(root) {
            self.site = site
            previewBuilder = PreviewBuilder(site: site)
        }
        reloadDrafts()
        selectedDocumentID = selected
        refreshGit()
    }

    func reloadDrafts() {
        guard let site, let draftStore else { return }
        drafts = draftStore.drafts(for: site)
    }

    func refreshGit() {
        guard let root = site?.root, let git = Git(root: root) else { return }
        statusTask?.cancel()
        statusTask = Task {
            guard await git.isRepository() else {
                hasGit = false
                return
            }
            let status = (try? await git.status()) ?? [:]
            let dates = await git.lastCommitDates(in: ".")
            let remote = await git.remoteURL()
            guard !Task.isCancelled else { return }
            hasGit = true
            gitStatus = status
            lastCommitDates = dates
            self.remote = remote
        }
    }

    // MARK: Documents

    var allDocuments: [SiteDocument] { (site?.documents ?? []) + drafts }

    func document(_ id: String?) -> SiteDocument? {
        guard let id else { return nil }
        return allDocuments.first { $0.id == id }
    }

    func documents(for selection: SidebarSelection?) -> [SiteDocument] {
        guard let site else { return [] }
        var docs: [SiteDocument] = switch selection {
        case let .section(id)?:
            site.documents(in: id) + drafts.filter { $0.sectionID == id }
        case .drafts?:
            drafts + site.documents.filter { !$0.publishedFlag || gitStatus[$0.relativePath] == .untracked }
        case nil:
            []
        }
        docs.sort { a, b in
            let da = a.origin == .localDraft ? a.modified : (a.date ?? .distantPast)
            let db = b.origin == .localDraft ? b.modified : (b.date ?? .distantPast)
            if (a.origin == .localDraft) != (b.origin == .localDraft) { return a.origin == .localDraft }
            return da > db
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            docs = docs.filter { doc in
                if doc.title.localizedCaseInsensitiveContains(query) || doc.excerpt.localizedCaseInsensitiveContains(query) { return true }
                let text = (try? String(contentsOf: doc.fileURL, encoding: .utf8)) ?? ""
                return text.localizedCaseInsensitiveContains(query)
            }
        }
        return docs
    }

    func status(of doc: SiteDocument) -> DocumentStatus {
        if doc.origin == .localDraft { return .draft }
        switch gitStatus[doc.relativePath] {
        case .untracked?, .added?: return .notCommitted
        case .modified?, .renamed?: return .edited
        default: break
        }
        return doc.publishedFlag ? .published : .hidden
    }

    func count(for sectionID: String) -> Int {
        (site?.documents(in: sectionID).count ?? 0) + drafts.filter { $0.sectionID == sectionID }.count
    }

    var pendingChanges: Int {
        allDocuments.filter { [.edited, .notCommitted].contains(status(of: $0)) }.count
    }

    func select(_ id: String?) {
        editor?.saveNow()
        selectedDocumentID = id
        guard let doc = document(id), let site else {
            editor = nil
            return
        }
        editor = EditorDocument(document: doc, site: site, model: self)
        showSource = false
    }

    // MARK: New and save

    func newPost() {
        guard let site, let draftStore else { return }
        var sectionID: String?
        if case let .section(id)? = sidebarSelection, site.section(id)?.collectionName != nil { sectionID = id }
        let section = site.section(sectionID ?? "") ?? site.sections.first { $0.collectionName == "notes" }
            ?? site.sections.first { $0.collectionName != nil }
        guard let section, let collection = section.collectionName else { return }
        let fields = schema(for: section.id)
        var lines: [(String, String)] = [("title", YAMLFormat.quoted(""))]
        let today = Date()
        for field in fields where field.isUniversal && field.key != "title" {
            switch field.kind {
            case .date: lines.append((field.key, YAMLFormat.date(today)))
            case .toggle: lines.append((field.key, YAMLFormat.bool(field.defaultBool ?? true)))
            default: break
            }
        }
        if !lines.contains(where: { $0.0 == "date" }) { lines.insert(("date", YAMLFormat.date(today)), at: 1) }
        let text = FrontMatterDocument(fields: lines, body: "\n").text
        do {
            let url = try draftStore.create(collection: collection, title: "", date: today, text: text, siteRoot: site.root)
            reloadDrafts()
            sidebarSelection = .section(section.id)
            if let doc = drafts.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
                select(doc.id)
                editor?.focusTitle = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func schema(for sectionID: String) -> [FieldSpec] {
        guard let site else { return [] }
        let docs = site.documents(in: sectionID).compactMap { try? String(contentsOf: $0.fileURL, encoding: .utf8) }.map(FrontMatterDocument.init)
        return SchemaInference.infer(docs)
    }

    /// A local draft's file follows its title and date, so it is published under the right name.
    func draftRenamed(from old: SiteDocument, to url: URL) {
        reloadDrafts()
        if let doc = drafts.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            selectedDocumentID = doc.id
            editor?.document = doc
        }
        _ = old
    }

    func freeDraftFilename(collection: String, date: Date, slug: String, current: URL) -> String? {
        guard let site else { return nil }
        return draftStore?.freeFilename(collection: collection, date: date, slug: slug, siteRoot: site.root, current: current)
    }

    func draftURL(collection: String, filename: String) -> URL? {
        draftStore?.url(collection: collection, filename: filename)
    }

    func documentSaved(_ doc: SiteDocument) {
        if doc.origin == .localDraft {
            reloadDrafts()
        } else if let site {
            if let index = self.site?.documents.firstIndex(where: { $0.id == doc.id }),
               let updated = SiteLoader.document(at: doc.fileURL, relativePath: doc.relativePath, sectionID: doc.sectionID,
                                                 config: site.config, url: doc.isPage ? doc.url : nil) {
                self.site?.documents[index] = updated
            }
            refreshGit()
        }
    }

    func deleteDraft(_ doc: SiteDocument) {
        guard doc.origin == .localDraft else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(doc.title.isEmpty ? "Untitled" : doc.title)”?"
        alert.informativeText = "The draft is moved to the Trash. It was never published."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if selectedDocumentID == doc.id {
            editor = nil
            selectedDocumentID = nil
        }
        try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
        reloadDrafts()
    }

    func revealInFinder(_ doc: SiteDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
    }

    // MARK: Publish

    var canPublish: Bool {
        guard let doc = editor?.document else { return false }
        return [.draft, .edited, .notCommitted].contains(status(of: doc)) && hasGit
    }

    var publishTitle: String {
        guard let doc = editor?.document else { return "Publish" }
        return status(of: doc) == .edited ? "Update" : "Publish"
    }

    func beginPublish() {
        guard let editor, let site, canPublish else { return }
        editor.saveNow()
        publishSheet = PublishSession(document: editor.document, text: editor.fullText, site: site, model: self)
    }

    func liveURL(for doc: SiteDocument) -> URL? {
        guard let site else { return nil }
        return URL(string: site.config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + doc.url)
    }

    /// Moves a published draft into the site and selects its new file.
    func adoptPublished(relativePath: String) {
        reloadSite()
        if let doc = site?.documents.first(where: { $0.relativePath == relativePath }) {
            select(doc.id)
        }
    }

    // MARK: Images

    struct PendingImage: Identifiable {
        let id = UUID()
        var image: ImportedImage
        var insertAt: Int
        var alt = ""
        var caption = ""
    }

    func importImages(_ urls: [URL], at location: Int) {
        guard let site, let editor else { return }
        let slug = Filename.parse(editor.document.filename).slug
        for url in urls.prefix(1) {
            do {
                let image = try ImageImport().importImage(at: url, siteRoot: site.root, slug: slug == "untitled" ? "image" : slug)
                pendingImage = PendingImage(image: image, insertAt: location)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if urls.count > 1 {
            errorMessage = "Add images one at a time for now, so each gets its own alt text."
        }
    }

    func insertPendingImage() {
        guard let pending = pendingImage else { return }
        let alt = pending.alt.trimmingCharacters(in: .whitespaces)
        var markdown = pending.image.markdown(alt: alt, useRelativeURL: true)
        let caption = pending.caption.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty { markdown += "\n*\(caption)*" }
        textView?.insertBlock(markdown, at: pending.insertAt)
        pendingImage = nil
        refreshGit()
    }

    func cancelPendingImage() {
        if let pending = pendingImage { try? FileManager.default.removeItem(at: pending.image.fileURL) }
        pendingImage = nil
    }
}
