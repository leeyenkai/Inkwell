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
    case scheduled

    var symbol: String {
        switch self {
        case .published: "circle"
        case .draft, .notPublished: "circle.lefthalf.filled"
        case .edited: "pencil.circle.fill"
        case .hidden: "eye.slash.circle"
        case .scheduled: "clock"
        }
    }

    var label: String {
        switch self {
        case .published: String(localized: "Published")
        case .draft: String(localized: "Draft")
        case .edited: String(localized: "Edited")
        case .notPublished: String(localized: "Not published")
        case .hidden: String(localized: "Hidden")
        case .scheduled: String(localized: "Scheduled")
        }
    }

    var color: Color {
        switch self {
        case .published, .hidden: .secondary
        case .draft, .notPublished: .orange
        case .edited, .scheduled: .accentColor
        }
    }
}

enum SidebarSelection: Hashable {
    case section(String)
    case drafts
    case design
    case navigation
    case settings
    case code
    case tags
    case media
    case health

    var isDesign: Bool { [.design, .navigation, .settings, .code].contains(self) }
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
    let updates = Updates()
    var site: Site? {
        didSet { photoCache = nil }
    }

    /// The photo entries, read from their files once per site load rather than on every redraw of the grid.
    @ObservationIgnored var photoCache: [PhotoEntry]?
    private(set) var backend: (any SiteBackend)?
    var loadError: String?
    var opening: String?
    var drafts: [SiteDocument] = []
    private(set) var changes: [String: ChangeKind] = [:]
    private(set) var conflicts: [String] = []
    private(set) var unpushed = 0
    private(set) var syncStatus: SyncStatus = .idle
    var pagesURL: URL?
    /// The repository's default branch and how GitHub Pages builds the site ("legacy" or "workflow"), when known.
    /// Scheduling needs both: scheduled workflows run only on the default branch, and only legacy builds can be requested.
    private(set) var defaultBranch: String?
    private(set) var pagesBuildType: String?

    var sidebarSelection: SidebarSelection? = .section("notes")
    var selectedDocumentID: String?
    var editor: EditorDocument?
    var searchText = ""

    var showPreview = false
    var showSource = false
    var showProperties = true
    /// Clicking text or a picture in a hand-built page's preview edits it there (SPEC §4.12, W3).
    var editOnPage = false
    var showSharing = UserDefaults.standard.bool(forKey: "ShowSharing") {
        didSet { UserDefaults.standard.set(showSharing, forKey: "ShowSharing") }
    }
    var previewWidth: PreviewWidth = .desktop
    var publishSheet: PublishSession?
    var showChanges = false
    var showConflicts = false
    var showSitePicker = false
    var showThemeGallery = false
    var codeFile: CodeFile?
    var linkPick: LinkPick?
    var hideSyntax = UserDefaults.standard.object(forKey: "HideSyntax") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideSyntax, forKey: "HideSyntax") }
    }

    struct LinkPick: Identifiable {
        let id = UUID()
        var location: Int
    }
    var moveRequest: SiteDocument?
    var historyRequest: SiteDocument?
    var selectedTag: String?
    var showNewPage = false
    /// Tag → ids of the documents using it.
    private(set) var tagIndex: [String: [String]] = [:]
    var pendingImage: PendingImage?
    var pendingPhotos: [PendingPhoto]?
    var tableEdit: TableEdit?
    var pageLinkEdit: PageLinkEdit?
    var showMoveToJekyll = false
    var elementEdit: ElementEdit?
    var showElementPicker = false
    var health: SiteHealth.Report?
    var externalLinkIssues: [SiteHealth.Issue] = []
    var externalCheck: ExternalCheck = .never
    var selectedIssueID: String?
    var pendingGallery: PendingGallery?
    var selectedPhotoID: String?
    var showPhotoSetup = false

    // MARK: Photo albums (see PhotoActions.swift)

    /// Which photos the grid shows: all, one album's, or those in no album.
    var albumFilter: AlbumFilter = .all
    /// Every chosen photo when several are; `selectedPhotoID` is the one clicked last.
    var selectedPhotoIDs: Set<String> = []
    var newAlbumRequest: NewAlbumRequest?
    // End of photo albums
    var selectedMedia: String?
    var mediaItems: [MediaLibrary.Item] = []
    var mediaRevision = 0
    var errorMessage: String? {
        didSet { if let errorMessage { Diagnostics.record(errorMessage) } }
    }
    var showSiteSummary = false
    var suppressSiteSummary = false
    var helpTopic: HelpTopic = .start
    /// Set to open the Help window from code (a launch flag); the window opens it and clears it.
    var helpRequested = false
    var settingsRequested = false

    private(set) var previewBuilder: PreviewBuilder?
    private(set) var siteResources: SiteResources?
    private(set) var design: DesignModel?
    /// The gem or remote theme's files, once downloaded.
    private(set) var themeRoot: URL?
    private(set) var themeStatus: String?

    /// The bundled dart-sass, for themes written in SCSS.
    static let sass: SassCompiler? = Bundle.main.url(forResource: "dart-sass/sass", withExtension: nil)
        .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? SassCompiler(executable: $0) : nil }
    private var searchIndex: [String: String] = [:]
    weak var textView: InkwellTextView?
    /// True while the post's text view has the keyboard: the Format menu acts only then, so in the title or a property
    /// field its shortcuts are left to the field.
    private(set) var editorHasFocus = false
    @ObservationIgnored private weak var focusedTextView: InkwellTextView?

    func editorFocusChanged(_ view: InkwellTextView, focused: Bool) {
        if focused {
            focusedTextView = view
        } else if focusedTextView !== view {
            return
        }
        if !focused { focusedTextView = nil }
        if editorHasFocus != focused { editorHasFocus = focused }
    }
    private(set) var draftStore: DraftStore?
    private var changesTask: Task<Void, Never>?
    private var syncLoop: Task<Void, Never>?

    enum PreviewWidth: String, CaseIterable {
        case desktop = "Desktop"
        case phone = "Phone"
    }

    /// Which colour scheme the preview shows, so both palettes can be checked.
    enum PreviewAppearance: String {
        case system, light, dark
    }

    var previewAppearance: PreviewAppearance = .system

    // MARK: Opening sites

    func start() async {
        await account.restore()
        guard Prefs.bool(Prefs.reopenLastSite), let saved = RecentSite.saved else { return }
        if saved["kind"] == "github", let owner = saved["owner"], let name = saved["name"], let branch = saved["branch"] {
            let ref = SiteRef(owner: owner, name: name, branch: branch, sitePath: saved["sitePath"] ?? "")
            let copy = WorkingCopy(ref: ref, container: GitHubBackend.container)
            if await copy.isDownloaded, let client = account.client {
                await attach(GitHubBackend(copy: copy, client: client))
                if let pages = try? await client.pages(owner, name) {
                    pagesURL = pages.html_url.flatMap(URL.init(string:))
                    pagesBuildType = pages.build_type
                    reloadIfBuildTypeMatters()
                }
                defaultBranch = try? await client.repository(owner, name).default_branch
            }
        } else if saved["kind"] == "folder", let path = saved["path"], FileManager.default.fileExists(atPath: path) {
            await openFolder(URL(fileURLWithPath: path))
        }
    }

    /// Opens a repository from the person's account, downloading it the first time.
    func open(repository repo: GitHubRepo) async {
        guard let client = account.client else { return }
        opening = String(localized: "Looking at \(repo.full_name)…")
        loadError = nil
        do {
            let pages: GitHubPages?
            do {
                pages = try await client.pages(repo.owner.login, repo.name)
            } catch GitHubError.http(status: 403, _) {
                throw GitHubError.http(status: 403, message: String(localized: """
                    This sign-in cannot read the repository’s GitHub Pages settings. Sign out, then sign in with a token that has \
                    the repo and workflow scopes.
                    """))
            }
            let branch = pages?.source?.branch ?? repo.default_branch ?? "main"
            let ref = SiteRef(owner: repo.owner.login, name: repo.name, branch: branch, sitePath: pages?.sitePath ?? "")
            let copy = WorkingCopy(ref: ref, container: GitHubBackend.container)
            if await !copy.isDownloaded {
                try await copy.download(client: client) { [weak self] message in
                    await MainActor.run { self?.opening = message }
                }
            }
            guard SiteLoader.looksLikeSite(copy.siteRoot) else {
                throw SiteError.notASite(URL(filePath: repo.full_name))
            }
            if let html = pages?.html_url { pagesURL = URL(string: html) }
            await attach(GitHubBackend(copy: copy, client: client))
            defaultBranch = repo.default_branch
            pagesBuildType = pages?.build_type
            reloadIfBuildTypeMatters()
            showSitePicker = false
            if pages == nil {
                errorMessage = String(localized: """
                    GitHub Pages is not turned on for \(repo.full_name). You can write and publish here, but nothing appears on the web \
                    until Pages is on in the repository’s settings on GitHub.
                    """)
            }
        } catch {
            loadError = error.localizedDescription
        }
        opening = nil
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder with a GitHub Pages site that you already publish with git.")
        panel.prompt = String(localized: "Open Site")
        if panel.runModal() == .OK, let url = panel.url { Task { await openFolder(url) } }
    }

    func openFolder(_ chosen: URL) async {
        let url = SiteLoader.pagesFolder(in: chosen)
        guard let local = LocalGitBackend(siteRoot: url, client: account.client) else {
            loadError = String(localized: """
                Using a local folder needs git. Install the command line tools (xcode-select --install), or sign in with GitHub instead.
                """)
            return
        }
        guard await local.prepare() else {
            loadError = String(localized: """
                \(url.lastPathComponent) is not a git repository. Sign in with GitHub to open your site from there instead.
                """)
            return
        }
        await attach(local)
        showSitePicker = false
    }

    func attach(_ backend: any SiteBackend) async {
        let root = backend.siteRoot
        let options = SiteLoader.Options(kind: Self.chosenKind(forSite: backend.draftKey))
        do {
            let site = try await Task.detached { try SiteLoader.load(root, options: options) }.value
            settleEditor()
            editor = nil
            selectedDocumentID = nil
            self.backend = backend
            self.site = site
            defaultBranch = nil
            pagesBuildType = nil
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
            themeRoot = nil
            rebuildDerived(site)
            refreshChanges()
            startSyncLoop()
            loadTheme(for: site)
            var seen = UserDefaults.standard.stringArray(forKey: Prefs.seenSites) ?? []
            if !seen.contains(backend.draftKey) {
                seen.append(backend.draftKey)
                UserDefaults.standard.set(seen, forKey: Prefs.seenSites)
                if !suppressSiteSummary { showSiteSummary = true }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func closeSite() {
        settleEditor()
        syncLoop?.cancel()
        editor = nil
        selectedDocumentID = nil
        site = nil
        backend = nil
        pagesURL = nil
        defaultBranch = nil
        pagesBuildType = nil
        changes = [:]
        RecentSite.clear()
        showSitePicker = true
    }

    /// The preview's site object and the search index, built off the main thread.
    private func rebuildDerived(_ site: Site) {
        let theme = themeRoot
        Task {
            let docs = site.documents + drafts
            let (builder, index, tags) = await Task.detached {
                var index: [String: String] = [:]
                var tags: [String: [String]] = [:]
                for doc in docs {
                    guard let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { continue }
                    index[doc.id] = text.lowercased()
                    for tag in TagIndex.tags(in: text) { tags[tag, default: []].append(doc.id) }
                }
                return (PreviewBuilder(site: site, timeZone: site.config.timeZone, themeRoot: theme), index, tags)
            }.value
            previewBuilder = builder
            siteResources = SiteResources(builder: builder, themeRoot: theme, sass: Self.sass)
            searchIndex = index
            tagIndex = tags
        }
        refreshHealth()
    }

    /// Fetches a gem or remote theme's files (once) so the preview can use its layouts and styles.
    private func loadTheme(for site: Site) {
        guard let reference = ThemeReference.of(site.config) else {
            themeStatus = nil
            return
        }
        let cache = ThemeCache.standard
        if let cached = cache.cached(owner: reference.owner, repository: reference.repository, ref: reference.ref) {
            themeRoot = cached
            rebuildDerived(site)
            design?.reload()
            return
        }
        themeStatus = String(localized: "Getting the \(reference.repository) theme for the preview…")
        let client = account.client ?? GitHubClient(token: "")
        Task {
            do {
                themeRoot = try await cache.ensure(owner: reference.owner, repository: reference.repository, ref: reference.ref, client: client)
                themeStatus = nil
                if let site = self.site { rebuildDerived(site) }
                design?.reload()
            } catch {
                themeStatus = String(localized: """
                    The \(reference.repository) theme could not be downloaded, so the preview is unstyled: \(error.localizedDescription)
                    """)
            }
        }
    }

    func reloadSite() {
        guard let root = backend?.siteRoot else { return }
        let options = loadOptions
        Task {
            guard let site = try? await Task.detached(operation: { try SiteLoader.load(root, options: options) }).value else { return }
            self.site = site
            reloadDrafts()
            rebuildDerived(site)
            refreshChanges()
        }
    }

    // MARK: Site kind (SPEC §4.12)

    /// The kind chosen for the open site, or nil to use the one Inkwell finds.
    var chosenKind: SiteKind? {
        backend.flatMap { Self.chosenKind(forSite: $0.draftKey) }
    }

    static func chosenKind(forSite key: String) -> SiteKind? {
        UserDefaults.standard.string(forKey: "siteKind:\(key)").flatMap(SiteKind.init(rawValue:))
    }

    func chooseKind(_ kind: SiteKind?) {
        guard let key = backend?.draftKey else { return }
        UserDefaults.standard.set(kind?.rawValue, forKey: "siteKind:\(key)")
        settleEditor()
        editor = nil
        selectedDocumentID = nil
        reloadSite()
    }

    var loadOptions: SiteLoader.Options {
        SiteLoader.Options(kind: chosenKind, pagesBuildType: pagesBuildType)
    }

    /// A branch-built site's workflows do not build it, so they no longer decide its kind once GitHub says so.
    func reloadIfBuildTypeMatters() {
        guard pagesBuildType == "legacy", let root = backend?.siteRoot, PagesWorkflow.build(siteRoot: root) != nil else { return }
        reloadSite()
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

    func restartSyncLoop() {
        if backend != nil { startSyncLoop() }
    }

    func editorPreferencesChanged() {
        textView?.applyPreferences()
    }

    func signOut() {
        closeSite()
        account.signOut()
    }

    private func startSyncLoop() {
        syncLoop?.cancel()
        syncLoop = Task {
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: .seconds(max(1, UserDefaults.standard.integer(forKey: Prefs.syncMinutes)) * 60))
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
        case nil, .design?, .navigation?, .settings?, .code?, .tags?, .media?, .health?:
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
        default:
            guard doc.publishedFlag else { return .hidden }
            return Schedule.isScheduled(doc.date) && !(site.map { Schedule.publishesFutureNow($0.config) } ?? false) ? .scheduled : .published
        }
    }

    func count(for sectionID: String) -> Int {
        (site?.documents(in: sectionID).count ?? 0) + drafts.filter { $0.sectionID == sectionID }.count
    }

    var pendingChanges: Int { changes.count }

    /// Why the hourly schedule workflow cannot run for this site, or nil when it can (or the site is a local folder).
    var scheduleWorkflowBlocker: Schedule.WorkflowBlocker? {
        guard let ref = (backend as? GitHubBackend)?.copy.ref else { return nil }
        return Schedule.workflowBlocker(sitePath: ref.sitePath, branch: ref.branch, defaultBranch: defaultBranch, buildType: pagesBuildType)
    }

    func select(_ id: String?) {
        guard id != selectedDocumentID || editor == nil else { return }
        settleEditor()
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
        let collection: String
        if let name = section?.collectionName {
            collection = name
        } else if site.kind == .website, confirmStartingBlog() {
            // The first post published creates `_posts/`, and the site becomes a blog.
            collection = "posts"
        } else {
            if site.kind.servesFilesAsIs {
                errorMessage = String(localized: "Posts need Jekyll, which this site does not use. Edit its pages instead.")
            } else if site.kind != .website {
                errorMessage = String(localized: "This site has no section for posts yet.")
            }
            return
        }
        let fields = section.map { schema(for: $0.id) } ?? []
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
            let url = try draftStore.create(collection: collection, title: "", date: today, text: text, siteRoot: site.root,
                                               timeZone: site.config.timeZone)
            reloadDrafts()
            sidebarSelection = section.map { .section($0.id) } ?? .drafts
            if let doc = drafts.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
                select(doc.id)
                editor?.focusTitle = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A website without posts gets a blog only when the person asks for one.
    func confirmStartingBlog() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Start a blog on this site?")
        alert.informativeText = String(localized: """
            This site has pages but no posts. A new post stays a draft on this Mac. When you publish it, it goes into a _posts folder, \
            and your site's layouts decide how posts look.
            """)
        alert.addButton(withTitle: String(localized: "Write a Post"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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
        return draftStore?.freeFilename(collection: collection, date: date, slug: slug, siteRoot: site.root, current: current,
                                        timeZone: site.config.timeZone)
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

    private var publishUpdates: Bool { editor.map { status(of: $0.document) == .edited } ?? false }

    var publishTitle: String { publishUpdates ? String(localized: "Update") : String(localized: "Publish") }

    /// The menu command, with its ellipsis.
    var publishMenuTitle: String { publishUpdates ? String(localized: "Update…") : String(localized: "Publish…") }

    func beginPublish() {
        guard let editor, let site, let backend, canPublish else { return }
        editor.saveNow()
        publishSheet = PublishSession.publish(document: editor.document, editor: editor, site: site, backend: backend, model: self)
    }

    func deleteFromSite(_ doc: SiteDocument) {
        guard let backend, doc.origin == .repository else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(doc.title)” from your site?")
        alert.informativeText = String(localized: """
            It is removed from GitHub in one change, and the page stops working. GitHub keeps its history, so it can be brought back.
            """)
        alert.addButton(withTitle: String(localized: "Delete from Site"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        retireEditor(for: doc)
        publishSheet = PublishSession.delete(document: doc, backend: backend, model: self)
    }

    func unpublish(_ doc: SiteDocument) {
        guard let backend, let draftStore, doc.origin == .repository, doc.relativePath.hasPrefix("_"),
              let folder = doc.relativePath.split(separator: "/").first else { return }
        let collection = String(folder.dropFirst())
        if editor?.document.id == doc.id { settleEditor() }
        retireEditor(for: doc)
        publishSheet = PublishSession.unpublish(document: doc, draftURL: draftStore.url(collection: collection, filename: doc.filename),
                                                backend: backend, model: self)
    }

    func discardChanges(_ doc: SiteDocument) {
        guard let backend, changes[doc.relativePath] != nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard the unpublished changes to “\(doc.title)”?")
        alert.informativeText = changes[doc.relativePath] == .added
            ? String(localized: "The file has never been published, so it is removed.")
            : String(localized: "It goes back to the version that is on your site.")
        alert.addButton(withTitle: String(localized: "Discard Changes"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        let name = doc.title.isEmpty ? String(localized: "Untitled") : doc.title
        alert.messageText = String(localized: "Delete “\(name)”?")
        alert.informativeText = String(localized: "The draft is moved to the Trash. It was never published.")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        retireEditor(for: doc)
        try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
        reloadDrafts()
    }

    /// Saves the open post before the editor closes. If the file changed elsewhere while there are unsaved edits here,
    /// asks which version to keep, so neither is dropped without a choice.
    func settleEditor() {
        guard let editor else { return }
        editor.saveNow()
        editor.resolveConflictIfTrivial()
        guard editor.conflictNeedsChoice else { return }
        let name = editor.title.isEmpty ? editor.document.filename : editor.title
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” changed outside Inkwell while you were editing it.")
        alert.informativeText = String(localized: """
            Keep your version to save it over the other one, or use the other version and discard your edits.
            """)
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: String(localized: "Use the Other Version"))
        editor.resolveDiskConflict(keepMine: alert.runModal() == .alertFirstButtonReturn)
    }

    static let flushSavesNotification = Notification.Name("InkwellFlushSaves")

    /// Writes everything still waiting for its autosave pause, before the app quits.
    func saveAllBeforeQuitting() {
        settleEditor()
        design?.flushPendingTokens()
        NotificationCenter.default.post(name: Self.flushSavesNotification, object: nil)
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
            let options = loadOptions
            guard let root = backend?.siteRoot,
                  let site = try? await Task.detached(operation: { try SiteLoader.load(root, options: options) }).value else { return }
            self.site = site
            reloadDrafts()
            rebuildDerived(site)
            refreshChanges()
            // Publishing pulls first, which can update the open file too.
            editor?.reloadIfChangedOnDisk()
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
        var insertAt: InsertPoint
        var alt = ""
        var caption = ""
        /// For a page served as it is: the `src` to write, relative to the page, and the picture goes in as HTML.
        var htmlSource: String?
    }

    /// Where a picture goes, remembered when its import starts: the post, and its text then.
    struct InsertPoint {
        var editor: ObjectIdentifier
        var text: String
        var location: Int
    }

    func insertPoint(at location: Int) -> InsertPoint? {
        guard let editor, let textView else { return nil }
        return InsertPoint(editor: ObjectIdentifier(editor), text: textView.string, location: location)
    }

    /// The remembered location while the text is as it was, the cursor once it has changed (typing, the Source
    /// toggle), and nil when another post is open now.
    func location(for point: InsertPoint) -> Int? {
        guard let editor, ObjectIdentifier(editor) == point.editor, let textView else { return nil }
        return textView.string == point.text ? point.location : textView.selectedRange().location
    }

    static var pictureNotAdded: String { String(localized: "The picture was not added, because another post is open now.") }

    func importImages(_ urls: [URL], at location: Int) {
        guard let site, let editor, let url = urls.first, let point = insertPoint(at: location) else { return }
        if urls.count > 1 { return importGallery(urls, at: point) }
        let slug = Filename.parse(editor.document.filename).slug
        let root = site.root
        Task {
            do {
                let image = try await Task.detached {
                    try ImageImport.app.importImage(at: url, siteRoot: root, slug: slug == "untitled" ? "image" : slug)
                }.value
                guard self.location(for: point) != nil else {
                    try? FileManager.default.removeItem(at: image.fileURL)
                    errorMessage = Self.pictureNotAdded
                    return
                }
                pendingImage = PendingImage(image: image, insertAt: point)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Pictures dropped on a page served as it is: imported like any picture (resized, location and camera details
    /// removed) into the folder the site keeps its pictures in, then written as `<img>` once it has alt text.
    func importImagesIntoPage(_ urls: [URL], at location: Int) {
        guard let site, let editor, let url = urls.first else { return }
        let point = InsertPoint(editor: ObjectIdentifier(editor), text: editor.fullText, location: location)
        let root = site.root
        let folder = ["media", "images", "img", "assets/images", "assets/img"]
            .first { FileManager.default.fileExists(atPath: root.appending(path: $0).path) } ?? "images"
        let page = editor.document.relativePath
        let slug = (editor.document.filename as NSString).deletingPathExtension
        Task {
            do {
                var importer = ImageImport.app
                importer.folder = folder
                let image = try await Task.detached {
                    try importer.importImage(at: url, siteRoot: root, slug: slug == "index" ? "picture" : slug)
                }.value
                guard self.editor.map(ObjectIdentifier.init) == point.editor else {
                    try? FileManager.default.removeItem(at: image.fileURL)
                    errorMessage = Self.pictureNotAdded
                    return
                }
                let target = String(image.sitePath.drop { $0 == "/" })
                pendingImage = PendingImage(image: image, insertAt: point, htmlSource: Self.relativePath(to: target, from: page))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// `media/a.jpg` as seen from `guide/index.html` is `../media/a.jpg`.
    static func relativePath(to target: String, from page: String) -> String {
        let folder = page.split(separator: "/").dropLast()
        let parts = target.split(separator: "/")
        var shared = 0
        while shared < folder.count, shared < parts.count - 1, folder[folder.startIndex + shared] == parts[shared] { shared += 1 }
        let up = Array(repeating: "..", count: folder.count - shared)
        return (up + parts[shared...].map(String.init)).joined(separator: "/")
    }

    /// An edit made on a hand-built page's preview: new text for a marked element, or a request to replace a picture.
    func applyPageEdit(_ message: [String: Any]) {
        guard let editor, let site, let index = message["index"] as? Int else { return }
        switch message["kind"] as? String {
        case "text":
            guard let before = message["before"] as? String, let after = message["after"] as? String else { return }
            if let updated = PageEditing.replacingText(index, with: after, expecting: before, in: editor.fullText, liquid: editor.document.isHTMLPage) {
                if updated != editor.fullText { editor.setFullText(updated) }
            } else {
                errorMessage = String(localized: "That text changed in the source while you were editing it, so your edit was not kept.")
            }
        case "image":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = String(localized: "Choose a picture to show here instead.")
            panel.prompt = String(localized: "Replace")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let root = site.root, page = editor.document.relativePath, id = ObjectIdentifier(editor), liquid = editor.document.isHTMLPage
            let folder = ["media", "images", "img", "assets/images", "assets/img"]
                .first { FileManager.default.fileExists(atPath: root.appending(path: $0).path) } ?? "images"
            let slug = (editor.document.filename as NSString).deletingPathExtension
            Task {
                do {
                    var importer = ImageImport.app
                    importer.folder = folder
                    let image = try await Task.detached {
                        try importer.importImage(at: url, siteRoot: root, slug: slug == "index" ? "picture" : slug)
                    }.value
                    let source = Self.relativePath(to: String(image.sitePath.drop { $0 == "/" }), from: page)
                    guard let current = self.editor, ObjectIdentifier(current) == id,
                          let updated = PageEditing.replacingImage(index, with: source, in: current.fullText, liquid: liquid) else {
                        try? FileManager.default.removeItem(at: image.fileURL)
                        errorMessage = Self.pictureNotAdded
                        return
                    }
                    current.setFullText(updated)
                    refreshChanges()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case "link":
            guard let before = message["before"] as? String else { return }
            pageLinkEdit = PageLinkEdit(index: index, address: before, page: editor.document.relativePath)
        default:
            break
        }
    }

    /// A link on a hand-built page whose address is being changed from the preview.
    struct PageLinkEdit: Identifiable {
        let id = UUID()
        var index: Int
        var address: String
        var page: String
    }

    func finishPageLinkEdit(_ edit: PageLinkEdit, address: String) {
        guard let editor, editor.document.relativePath == edit.page else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let updated = PageEditing.replacingLink(edit.index, with: address, expecting: edit.address, in: editor.fullText,
                                                      liquid: editor.document.isHTMLPage) else {
            errorMessage = String(localized: "That link changed in the source while you were editing it, so your edit was not kept.")
            return
        }
        if updated != editor.fullText { editor.setFullText(updated) }
    }

    func insertPendingImage() {
        guard let pending = pendingImage else { return }
        if let source = pending.htmlSource { return insertPendingImageIntoPage(pending, source: source) }
        let alt = pending.alt.trimmingCharacters(in: .whitespaces)
        var markdown = pending.image.markdown(alt: alt, useRelativeURL: true)
        let caption = pending.caption.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty { markdown += "\n*\(caption)*" }
        guard let location = location(for: pending.insertAt) else {
            cancelPendingImage()
            errorMessage = Self.pictureNotAdded
            return
        }
        textView?.insertBlock(markdown, at: location)
        pendingImage = nil
        refreshChanges()
    }

    private func insertPendingImageIntoPage(_ pending: PendingImage, source: String) {
        guard let editor, ObjectIdentifier(editor) == pending.insertAt.editor else {
            cancelPendingImage()
            errorMessage = Self.pictureNotAdded
            return
        }
        let alt = HTMLHead.escape(pending.alt.trimmingCharacters(in: .whitespaces))
        let caption = pending.caption.trimmingCharacters(in: .whitespaces)
        let img = "<img src=\"\(HTMLHead.escape(source))\" alt=\"\(alt)\">"
        let html = caption.isEmpty ? img : "<figure>\(img)<figcaption>\(HTMLHead.escapeText(caption))</figcaption></figure>"
        let text = editor.fullText as NSString
        // Where it was dropped while the page is unchanged; otherwise just before </body>.
        var location = editor.fullText == pending.insertAt.text ? min(pending.insertAt.location, text.length) : NSNotFound
        if location == NSNotFound {
            let body = text.range(of: "</body>", options: [.caseInsensitive, .backwards])
            location = body.location == NSNotFound ? text.length : body.location
        }
        editor.setFullText(text.replacingCharacters(in: NSRange(location: location, length: 0), with: html))
        pendingImage = nil
        refreshChanges()
    }

    func cancelPendingImage() {
        if let pending = pendingImage { try? FileManager.default.removeItem(at: pending.image.fileURL) }
        pendingImage = nil
    }
}
