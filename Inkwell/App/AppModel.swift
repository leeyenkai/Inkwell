import AppKit
import InkwellKit
import Observation
import SwiftUI

enum DocumentStatus: Equatable {
    case published
    case draft
    case edited
    case notPublished
    case hidden

    var symbol: String {
        switch self {
        case .published: "circle"
        case .draft, .notPublished: "circle.lefthalf.filled"
        case .edited: "pencil.circle.fill"
        case .hidden: "eye.slash.circle"
        }
    }

    var label: String {
        switch self {
        case .published: "Published"
        case .draft: "Draft"
        case .edited: "Edited"
        case .notPublished: "Not published"
        case .hidden: "Hidden"
        }
    }

    var color: Color {
        switch self {
        case .published, .hidden: .secondary
        case .draft, .notPublished: .orange
        case .edited: .accentColor
        }
    }
}

enum SidebarSelection: Hashable {
    case section(String)
    case drafts
    case design
    case navigation
    case settings

    var isDesign: Bool { [.design, .navigation, .settings].contains(self) }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case upToDate(Date)
    case offline(String)
}

/// Remembers the last site so Inkwell reopens it.
enum RecentSite {
    static let key = "RecentSite"

    static func save(github ref: SiteRef) {
        UserDefaults.standard.set(["kind": "github", "owner": ref.owner, "name": ref.name, "branch": ref.branch, "sitePath": ref.sitePath], forKey: key)
    }

    static func save(folder: URL) {
        UserDefaults.standard.set(["kind": "folder", "path": folder.path], forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static var saved: [String: String]? { UserDefaults.standard.dictionary(forKey: key) as? [String: String] }
}

@Observable
final class AppModel {
    let account = AccountModel()
    var site: Site?
    private(set) var backend: (any SiteBackend)?
    var loadError: String?
    var opening: String?
    var drafts: [SiteDocument] = []
    private(set) var changes: [String: ChangeKind] = [:]
    private(set) var conflicts: [String] = []
    private(set) var unpushed = 0
    private(set) var syncStatus: SyncStatus = .idle
    var pagesURL: URL?

    var sidebarSelection: SidebarSelection? = .section("notes")
    var selectedDocumentID: String?
    var editor: EditorDocument?
    var searchText = ""

    var showPreview = false
    var showSource = false
    var showProperties = true
    var previewWidth: PreviewWidth = .desktop
    var publishSheet: PublishSession?
    var showChanges = false
    var showConflicts = false
    var showSitePicker = false
    var showThemeGallery = false
    var pendingImage: PendingImage?
    var errorMessage: String?

    private(set) var previewBuilder: PreviewBuilder?
    private(set) var design: DesignModel?
    private var searchIndex: [String: String] = [:]
    weak var textView: InkwellTextView?
    private var draftStore: DraftStore?
    private var changesTask: Task<Void, Never>?
    private var syncLoop: Task<Void, Never>?

    enum PreviewWidth: String, CaseIterable {
        case desktop = "Desktop"
        case phone = "Phone"
    }

    // MARK: Opening sites

    func start() async {
        await account.restore()
        guard let saved = RecentSite.saved else { return }
        if saved["kind"] == "github", let owner = saved["owner"], let name = saved["name"], let branch = saved["branch"] {
            let ref = SiteRef(owner: owner, name: name, branch: branch, sitePath: saved["sitePath"] ?? "")
            let copy = WorkingCopy(ref: ref, container: GitHubBackend.container)
            if await copy.isDownloaded, let client = account.client {
                await attach(GitHubBackend(copy: copy, client: client))
            }
        } else if saved["kind"] == "folder", let path = saved["path"], FileManager.default.fileExists(atPath: path) {
            await openFolder(URL(fileURLWithPath: path))
        }
    }

    /// Opens a repository from the person's account, downloading it the first time.
    func open(repository repo: GitHubRepo) async {
        guard let client = account.client else { return }
        opening = "Looking at \(repo.full_name)…"
        loadError = nil
        do {
            let pages = try? await client.pages(repo.owner.login, repo.name)
            let branch = pages?.source?.branch ?? repo.default_branch ?? "main"
            let ref = SiteRef(owner: repo.owner.login, name: repo.name, branch: branch, sitePath: pages?.sitePath ?? "")
            let copy = WorkingCopy(ref: ref, container: GitHubBackend.container)
            if await !copy.isDownloaded {
                try await copy.download(client: client) { [weak self] message in
                    await MainActor.run { self?.opening = message }
                }
            }
            guard FileManager.default.fileExists(atPath: copy.siteRoot.appending(path: "_config.yml").path) else {
                throw SiteError.notASite(copy.siteRoot)
            }
            if let html = pages?.html_url { pagesURL = URL(string: html) }
            await attach(GitHubBackend(copy: copy, client: client))
            showSitePicker = false
        } catch {
            loadError = error.localizedDescription
        }
        opening = nil
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with a Jekyll site that you already publish with git."
        panel.prompt = "Open Site"
        if panel.runModal() == .OK, let url = panel.url { Task { await openFolder(url) } }
    }

    func openFolder(_ url: URL) async {
        guard let local = LocalGitBackend(siteRoot: url, client: account.client) else {
            loadError = "Using a local folder needs git. Install the command line tools (xcode-select --install), or sign in with GitHub instead."
            return
        }
        guard await local.prepare() else {
            loadError = "\(url.lastPathComponent) is not a git repository. Sign in with GitHub to open your site from there instead."
            return
        }
        await attach(local)
        showSitePicker = false
    }

    func attach(_ backend: any SiteBackend) async {
        let root = backend.siteRoot
        do {
            let site = try await Task.detached { try SiteLoader.load(root) }.value
            editor?.saveNow()
            editor = nil
            selectedDocumentID = nil
            self.backend = backend
            self.site = site
            loadError = nil
            if let github = backend as? GitHubBackend {
                RecentSite.save(github: github.copy.ref)
            } else {
                RecentSite.save(folder: root)
                pagesURL = URL(string: site.config.url)
            }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Inkwell/Drafts", directoryHint: .isDirectory)
            draftStore = DraftStore(base: support, key: backend.draftKey)
            design = DesignModel(root: root, model: self)
            reloadDrafts()
            if case let .section(id)? = sidebarSelection, site.section(id) != nil {} else {
                let first = site.sections.first { $0.collectionName != nil } ?? site.sections.first
                sidebarSelection = first.map { .section($0.id) }
            }
            rebuildDerived(site)
            refreshChanges()
            startSyncLoop()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func closeSite() {
        editor?.saveNow()
        syncLoop?.cancel()
        editor = nil
        selectedDocumentID = nil
        site = nil
        backend = nil
        pagesURL = nil
        changes = [:]
        RecentSite.clear()
        showSitePicker = true
    }

    /// The preview's site object and the search index, built off the main thread.
    private func rebuildDerived(_ site: Site) {
        Task {
            let docs = site.documents + drafts
            let (builder, index) = await Task.detached {
                var index: [String: String] = [:]
                for doc in docs { index[doc.id] = (try? String(contentsOf: doc.fileURL, encoding: .utf8))?.lowercased() }
                return (PreviewBuilder(site: site), index)
            }.value
            previewBuilder = builder
            searchIndex = index
        }
    }

    func reloadSite() {
        guard let root = backend?.siteRoot else { return }
        Task {
            guard let site = try? await Task.detached(operation: { try SiteLoader.load(root) }).value else { return }
            self.site = site
            reloadDrafts()
            rebuildDerived(site)
            refreshChanges()
        }
    }

    /// After a sync or discard, files may have changed under the Design panel too.
    func reloadDesign() {
        design?.reload()
    }

    func reloadDrafts() {
        guard let site, let draftStore else { return }
        drafts = draftStore.drafts(for: site)
    }

    // MARK: Sync

    func refreshChanges() {
        guard let backend else { return }
        changesTask?.cancel()
        changesTask = Task {
            let changes = (try? await backend.changes()) ?? [:]
            let conflicts = await backend.conflicts()
            let unpushed = await backend.unpushed()
            guard !Task.isCancelled else { return }
            self.changes = changes
            self.conflicts = conflicts
            self.unpushed = unpushed
        }
    }

    private func startSyncLoop() {
        syncLoop?.cancel()
        syncLoop = Task {
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Brings in changes made on GitHub (or by another tool). Never overwrites anything edited here.
    func sync() async {
        guard let backend, syncStatus != .syncing else { return }
        editor?.saveNow()
        syncStatus = .syncing
        do {
            let outcome = try await backend.sync()
            syncStatus = .upToDate(Date())
            if !outcome.updated.isEmpty {
                reloadSite()
                reloadDesign()
                editor?.reloadIfChangedOnDisk()
            }
            if !outcome.conflicts.isEmpty { showConflicts = true }
        } catch {
            syncStatus = .offline(error.localizedDescription)
        }
        refreshChanges()
    }

    func appBecameActive() {
        guard site != nil else { return }
        editor?.reloadIfChangedOnDisk()
        refreshChanges()
        Task { await sync() }
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
            drafts + site.documents.filter { !$0.publishedFlag || changes[$0.relativePath] == .added }
        case nil, .design?, .navigation?, .settings?:
            []
        }
        docs.sort { a, b in
            if (a.origin == .localDraft) != (b.origin == .localDraft) { return a.origin == .localDraft }
            let da = a.origin == .localDraft ? a.modified : (a.date ?? .distantPast)
            let db = b.origin == .localDraft ? b.modified : (b.date ?? .distantPast)
            return da > db
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            docs = docs.filter { $0.title.lowercased().contains(query) || searchIndex[$0.id]?.contains(query) == true }
        }
        return docs
    }

    func status(of doc: SiteDocument) -> DocumentStatus {
        if doc.origin == .localDraft { return .draft }
        switch changes[doc.relativePath] {
        case .added?: return .notPublished
        case .modified?: return .edited
        default: return doc.publishedFlag ? .published : .hidden
        }
    }

    func count(for sectionID: String) -> Int {
        (site?.documents(in: sectionID).count ?? 0) + drafts.filter { $0.sectionID == sectionID }.count
    }

    var pendingChanges: Int { changes.count }

    func select(_ id: String?) {
        guard id != selectedDocumentID || editor == nil else { return }
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
        let section = site.section(sectionID ?? "") ?? site.sections.first { $0.collectionName == "posts" }
            ?? site.sections.first { $0.collectionName == "notes" } ?? site.sections.first { $0.collectionName != nil }
        guard let section, let collection = section.collectionName else {
            errorMessage = "This site has no section for posts yet."
            return
        }
        let fields = schema(for: section.id)
        var lines: [(String, String)] = [("title", YAMLFormat.quoted(""))]
        let today = Date()
        for field in fields where field.isUniversal && field.key != "title" {
            switch field.kind {
            case .date: lines.append((field.key, YAMLFormat.date(today, timeZone: site.config.timeZone)))
            case .toggle: lines.append((field.key, YAMLFormat.bool(field.defaultBool ?? true)))
            default: break
            }
        }
        if !lines.contains(where: { $0.0 == "date" }) { lines.insert(("date", YAMLFormat.date(today, timeZone: site.config.timeZone)), at: 1) }
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

    private var schemaCache: [String: [FieldSpec]] = [:]

    func schema(for sectionID: String) -> [FieldSpec] {
        if let cached = schemaCache[sectionID] { return cached }
        guard let site else { return [] }
        let docs = site.documents(in: sectionID).compactMap { try? String(contentsOf: $0.fileURL, encoding: .utf8) }.map(FrontMatterDocument.init)
        let fields = SchemaInference.infer(docs)
        schemaCache[sectionID] = fields
        return fields
    }

    /// A draft's file follows its title and date. The editor stays the same; only the list entry moves.
    func draftRenamed(to url: URL, editor: EditorDocument) {
        reloadDrafts()
        if let doc = drafts.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            selectedDocumentID = doc.id
            editor.document = doc
        }
    }

    func freeDraftFilename(collection: String, date: Date, slug: String, current: URL) -> String? {
        guard let site else { return nil }
        return draftStore?.freeFilename(collection: collection, date: date, slug: slug, siteRoot: site.root, current: current)
    }

    func draftURL(collection: String, filename: String) -> URL? {
        draftStore?.url(collection: collection, filename: filename)
    }

    func documentSaved(_ doc: SiteDocument, text: String) {
        searchIndex[doc.id] = text.lowercased()
        if doc.origin == .localDraft {
            reloadDrafts()
        } else if let site, let index = self.site?.documents.firstIndex(where: { $0.id == doc.id }),
                  let updated = SiteLoader.document(at: doc.fileURL, relativePath: doc.relativePath, sectionID: doc.sectionID,
                                                    config: site.config, url: doc.isPage ? doc.url : nil) {
            self.site?.documents[index] = updated
            refreshChanges()
        }
    }

    func revealInFinder(_ doc: SiteDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
    }

    func liveURL(for doc: SiteDocument) -> URL? {
        let base = pagesURL?.absoluteString ?? site?.config.url ?? ""
        guard !base.isEmpty, let site else { return nil }
        let host = base.hasSuffix("/") ? String(base.dropLast()) : base
        let path = !site.config.baseurl.isEmpty && host.hasSuffix(site.config.baseurl) ? String(doc.url.dropFirst(site.config.baseurl.count)) : doc.url
        return URL(string: host + path)
    }

    // MARK: Publishing and other changes

    var canPublish: Bool {
        guard let doc = editor?.document, backend != nil else { return false }
        return [.draft, .edited, .notPublished].contains(status(of: doc))
    }

    var publishTitle: String {
        guard let doc = editor?.document else { return "Publish" }
        return status(of: doc) == .edited ? "Update" : "Publish"
    }

    func beginPublish() {
        guard let editor, let site, let backend, canPublish else { return }
        editor.saveNow()
        publishSheet = PublishSession.publish(document: editor.document, editor: editor, site: site, backend: backend, model: self)
    }

    func deleteFromSite(_ doc: SiteDocument) {
        guard let backend, doc.origin == .repository else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(doc.title)” from your site?"
        alert.informativeText = "It is removed from GitHub in one change, and the page stops working. GitHub keeps its history, so it can be brought back."
        alert.addButton(withTitle: "Delete from Site")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        retireEditor(for: doc)
        publishSheet = PublishSession.delete(document: doc, backend: backend, model: self)
    }

    func unpublish(_ doc: SiteDocument) {
        guard let backend, let draftStore, doc.origin == .repository, doc.relativePath.hasPrefix("_"),
              let folder = doc.relativePath.split(separator: "/").first else { return }
        let collection = String(folder.dropFirst())
        retireEditor(for: doc)
        publishSheet = PublishSession.unpublish(document: doc, draftURL: draftStore.url(collection: collection, filename: doc.filename),
                                                backend: backend, model: self)
    }

    func discardChanges(_ doc: SiteDocument) {
        guard let backend, changes[doc.relativePath] != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the unpublished changes to “\(doc.title)”?"
        alert.informativeText = changes[doc.relativePath] == .added
            ? "The file has never been published, so it is removed." : "It goes back to the version that is on your site."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        retireEditor(for: doc)
        Task {
            do {
                try await backend.discard(path: doc.relativePath)
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadSite()
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
        retireEditor(for: doc)
        try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
        reloadDrafts()
    }

    /// Stops the open editor writing to a file that is about to move or disappear.
    func retireEditor(for doc: SiteDocument) {
        guard let editor, editor.document.id == doc.id else { return }
        editor.saveNow()
        editor.retire()
        self.editor = nil
        selectedDocumentID = nil
    }

    func didPublish(selecting relativePath: String?) {
        Task {
            guard let root = backend?.siteRoot, let site = try? await Task.detached(operation: { try SiteLoader.load(root) }).value else { return }
            self.site = site
            reloadDrafts()
            rebuildDerived(site)
            refreshChanges()
            if let relativePath, let doc = site.documents.first(where: { $0.relativePath == relativePath }) {
                selectedDocumentID = nil
                select(doc.id)
            }
        }
    }

    func publishAll(paths: [String], message: String) {
        guard let backend else { return }
        editor?.saveNow()
        publishSheet = PublishSession.changes(paths: paths, message: message, backend: backend, model: self)
        showChanges = false
    }

    func pushAgain() {
        guard let backend else { return }
        Task {
            do {
                try await backend.pushAgain()
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshChanges()
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
        guard let site, let editor, let url = urls.first else { return }
        let slug = Filename.parse(editor.document.filename).slug
        let root = site.root
        Task {
            do {
                let image = try await Task.detached {
                    try ImageImport().importImage(at: url, siteRoot: root, slug: slug == "untitled" ? "image" : slug)
                }.value
                pendingImage = PendingImage(image: image, insertAt: location)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if urls.count > 1 { errorMessage = "Add images one at a time for now, so each gets its own alt text." }
    }

    func insertPendingImage() {
        guard let pending = pendingImage else { return }
        let alt = pending.alt.trimmingCharacters(in: .whitespaces)
        var markdown = pending.image.markdown(alt: alt, useRelativeURL: true)
        let caption = pending.caption.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty { markdown += "\n*\(caption)*" }
        textView?.insertBlock(markdown, at: pending.insertAt)
        pendingImage = nil
        refreshChanges()
    }

    func cancelPendingImage() {
        if let pending = pendingImage { try? FileManager.default.removeItem(at: pending.image.fileURL) }
        pendingImage = nil
    }
}
