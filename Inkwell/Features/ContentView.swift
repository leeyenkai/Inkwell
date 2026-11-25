import InkwellKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.site != nil && !model.showSitePicker {
                SiteWindow(model: model)
            } else if model.account.isSignedIn {
                SitePickerView(model: model)
            } else {
                WelcomeView(model: model)
            }
        }
        .overlay {
            if let opening = model.opening, model.site != nil || !model.account.isSignedIn { OpeningOverlay(message: opening) }
        }
        .onChange(of: model.helpRequested) {
            if model.helpRequested {
                model.helpRequested = false
                openWindow(id: "help")
            }
        }
        .onChange(of: model.updates.windowRequested) {
            if model.updates.windowRequested {
                model.updates.windowRequested = false
                openWindow(id: "update")
            }
        }
        .onChange(of: model.settingsRequested) {
            if model.settingsRequested {
                model.settingsRequested = false
                openSettings()
            }
        }
        .alert("Inkwell", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SiteWindow: View {
    @Bindable var model: AppModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } content: {
            if model.sidebarSelection == .tags {
                TagsList(model: model)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } else if model.sidebarSelection == .health {
                HealthList(model: model)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
            } else if model.sidebarSelection == .media {
                MediaGrid(model: model)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            } else if model.showsPhotoGrid {
                PhotoGrid(model: model)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            } else if let design = model.design, model.sidebarSelection?.isDesign == true {
                Group {
                    switch model.sidebarSelection {
                    case .navigation?: NavigationEditor(design: design, model: model)
                    case .settings?: SiteSettingsView(design: design, model: model)
                    case .code?: CodeFileList(design: design, model: model)
                    default: DesignPanel(design: design, model: model)
                    }
                }
                .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
            } else {
                DocumentListView(model: model)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
            }
        } detail: {
            if model.sidebarSelection == .health {
                if let id = model.selectedIssueID, let issue = model.healthIssues.first(where: { $0.id == id }) {
                    HealthDetail(model: model, issue: issue)
                } else {
                    ContentUnavailableView("Choose an issue", systemImage: "stethoscope", description: Text("See what is wrong and fix it."))
                }
            } else if model.sidebarSelection == .media {
                if let path = model.selectedMedia, let item = model.mediaItems.first(where: { $0.path == path }) {
                    MediaDetail(model: model, item: item)
                } else {
                    ContentUnavailableView("Choose an image", systemImage: "photo.stack",
                                           description: Text("See where it is used, replace it everywhere at once, or delete it."))
                }
            } else if model.showsPhotoGrid {
                PhotosDetail(model: model)
            } else if model.sidebarSelection == .tags {
                if let tag = model.selectedTag {
                    TagDetail(model: model, tag: tag)
                } else {
                    ContentUnavailableView("Choose a tag", systemImage: "tag", description: Text("Rename, merge or remove a tag across every post."))
                }
            } else if let design = model.design, model.sidebarSelection == .code {
                if let file = model.codeFile {
                    CodeEditorPane(design: design, model: model, file: file)
                } else {
                    ContentUnavailableView("Choose a file", systemImage: "chevron.left.forwardslash.chevron.right",
                                           description: Text("Layouts, includes, styles and settings. Changes show in the preview as you type."))
                }
            } else if let design = model.design, model.sidebarSelection?.isDesign == true {
                DesignPreview(design: design, model: model)
            } else {
                DetailView(model: model)
            }
        }
        .navigationTitle(model.site?.name ?? "Inkwell")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SiteMenu(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.newPost()
                } label: {
                    Label("New Post", systemImage: "square.and.pencil")
                }
                .help("New post (⌘N)")
                Toggle(isOn: $model.showPreview) {
                    Label("Preview", systemImage: "eye")
                }
                .help("Show the post as it will look on the site (⌥⌘P)")
                .disabled(model.editor == nil)
                Button {
                    model.beginPublish()
                } label: {
                    Label(model.publishTitle, systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPublish)
                .help("Commit and push this post (⇧⌘P)")
            }
        }
        .sheet(item: $model.publishSheet) { session in
            PublishSheet(session: session, model: model)
        }
        .sheet(item: $model.pendingImage) { _ in
            ImageSheet(model: model)
        }
        .sheet(isPresented: $model.showChanges) { ChangesSheet(model: model) }
        .sheet(item: $model.moveRequest) { doc in MoveSheet(model: model, doc: doc) }
        .sheet(item: $model.historyRequest) { doc in HistorySheet(model: model, doc: doc) }
        .sheet(isPresented: $model.showNewPage) { NewPageSheet(model: model) }
        .sheet(item: $model.linkPick) { pick in LinkPickerSheet(model: model, location: pick.location) }
        .sheet(isPresented: $model.showConflicts) { ConflictSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.pendingPhotos != nil }, set: { if !$0, model.pendingPhotos != nil { model.cancelPendingPhotos() } })) {
            CaptionSheet(model: model)
        }
        .sheet(item: $model.pendingGallery) { _ in GallerySheet(model: model) }
        .sheet(item: $model.tableEdit) { edit in TableEditorSheet(model: model, edit: edit) }
        .sheet(item: $model.elementEdit) { edit in ElementEditorSheet(model: model, edit: edit) }
        .sheet(isPresented: $model.showElementPicker) { ElementPicker(model: model) }
        .sheet(isPresented: $model.showPhotoSetup) { PhotoSetupSheet(model: model) }
        .sheet(isPresented: $model.showSiteSummary) { SiteSummarySheet(model: model) }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var kind: SiteKind { model.site?.kind ?? .blog }

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Site") {
                ForEach(model.site?.sections ?? []) { section in
                    Label {
                        HStack {
                            Text(section.label)
                            Spacer()
                            if section.listsDocuments {
                                Text(model.count(for: section.id), format: .number)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .tag(SidebarSelection.section(section.id))
                }
                if kind == .website {
                    Button {
                        model.newPost()
                    } label: {
                        Label("Start a Blog…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Write a first post; publishing it adds a _posts folder")
                }
            }
            Section(kind == .blog ? "Writing" : "Site Files") {
                // Websites have no drafts or tags until they have posts.
                if kind == .blog || !model.drafts.isEmpty {
                    Label {
                        HStack {
                            Text("Drafts")
                            Spacer()
                            Text(model.documents(for: .drafts).count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .tag(SidebarSelection.drafts)
                }
                if kind == .blog { Label("Tags", systemImage: "tag").tag(SidebarSelection.tags) }
                Label("Media", systemImage: "photo.stack").tag(SidebarSelection.media)
                Label {
                    HStack {
                        Text("Health")
                        Spacer()
                        if model.healthProblems > 0 {
                            Text(model.healthProblems, format: .number).foregroundStyle(.secondary).monospacedDigit()
                                .accessibilityLabel("\(model.healthProblems) problems")
                        }
                    }
                } icon: {
                    Image(systemName: "stethoscope")
                }
                .tag(SidebarSelection.health)
            }
            // A generated site is changed through its own source, so it has no design tools here.
            if kind != .generated {
                Section("Design") {
                    Label(kind.servesFilesAsIs ? "Style" : "Theme & Style", systemImage: "paintpalette").tag(SidebarSelection.design)
                    // The menu and settings are Jekyll files (_data/navigation.yml, _config.yml).
                    if !kind.servesFilesAsIs {
                        Label("Navigation", systemImage: "menubar.rectangle").tag(SidebarSelection.navigation)
                        Label("Settings", systemImage: "gearshape").tag(SidebarSelection.settings)
                    }
                    Label("Code", systemImage: "chevron.left.forwardslash.chevron.right").tag(SidebarSelection.code)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            if kind == .generated { GeneratedSiteNotice() }
        }
        .safeAreaInset(edge: .bottom) {
            SyncFooter(model: model)
        }
        .onChange(of: model.sidebarSelection) {
            if case let .section(id)? = model.sidebarSelection, case let .page(path)? = model.site?.section(id)?.kind {
                model.select(model.site?.documents.first { $0.relativePath == path }?.id)
            }
        }
    }
}

struct SyncFooter: View {
    var model: AppModel

    var upToDate: String {
        model.drafts.isEmpty ? String(localized: "Site up to date") : String(localized: "Site up to date · \(model.drafts.count) drafts")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.conflicts.isEmpty {
                Button {
                    model.showConflicts = true
                } label: {
                    Label("\(model.conflicts.count) changed in two places", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            if model.unpushed > 0 {
                Button {
                    model.pushAgain()
                } label: {
                    Label("\(model.unpushed) not pushed · Push", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.plain)
            }
            if model.pendingChanges > 0 {
                Button {
                    model.showChanges = true
                } label: {
                    Label("\(model.pendingChanges) unpublished changes", systemImage: "pencil.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Review and publish them (⌥⇧⌘P)")
            } else {
                Label(upToDate, systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            switch model.syncStatus {
            case .syncing:
                Label("Checking GitHub…", systemImage: "arrow.triangle.2.circlepath").font(.caption)
            case let .offline(reason):
                Label("Offline", systemImage: "wifi.slash").font(.caption).help(reason)
            case let .upToDate(date):
                Text("Checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
            case .idle:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The site name in the toolbar, with switching, syncing and links.
struct SiteMenu: View {
    var model: AppModel

    var body: some View {
        Menu {
            Button("Check GitHub for Changes") { Task { await model.sync() } }
            Button("Review Unpublished Changes…") { model.showChanges = true }
            Divider()
            if !model.photosSetUp { Button("Set Up Photos…") { model.showPhotoSetup = true } }
            if let url = model.pagesURL { Button("Open Live Site") { NSWorkspace.shared.open(url) } }
            if let repo = model.backend?.repository, let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)") {
                Button("Open Repository on GitHub") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Switch Site…") { model.closeSite() }
            if model.account.isSignedIn {
                Button("Sign Out of GitHub") { model.signOut() }
            }
        } label: {
            Label(model.backend?.displayName ?? String(localized: "Site"), systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
        .help("Site")
    }
}

struct DocumentListView: View {
    @Bindable var model: AppModel

    var title: String {
        switch model.sidebarSelection {
        case let .section(id)?: model.site?.section(id)?.label ?? ""
        case .drafts?: String(localized: "Drafts")
        case .design?: String(localized: "Design")
        case .navigation?: String(localized: "Navigation")
        case .settings?: String(localized: "Settings")
        case .code?: String(localized: "Code")
        case .tags?: String(localized: "Tags")
        case .media?: String(localized: "Media")
        case .health?: String(localized: "Health")
        case nil: ""
        }
    }

    /// The old hand-written photos page, before the photo stream is set up.
    var offersPhotoSetup: Bool {
        guard case let .section(id)? = model.sidebarSelection, case let .page(path)? = model.site?.section(id)?.kind else { return false }
        return path.hasPrefix("photos") && !model.photosSetUp
    }

    var body: some View {
        let docs = model.documents(for: model.sidebarSelection)
        List(selection: Binding(get: { model.selectedDocumentID }, set: { model.select($0) })) {
            ForEach(docs) { doc in
                DocumentRow(doc: doc, status: model.status(of: doc))
                    .tag(doc.id)
                    .contextMenu { DocumentMenu(model: model, doc: doc) }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            if offersPhotoSetup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep photos as a stream").font(.headline)
                    Text("Add photos with captions and let the page list them, instead of editing HTML.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set Up Photos…") { model.showPhotoSetup = true }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
        .overlay {
            if docs.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? String(localized: "Nothing here yet") : String(localized: "No Results"),
                          systemImage: "doc.text")
                } description: {
                    Text(model.searchText.isEmpty
                        ? String(localized: "Press ⌘N to start a post.")
                        : String(localized: "Try a different search."))
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(docs.count) items")
    }
}

struct DocumentMenu: View {
    var model: AppModel
    var doc: SiteDocument

    var body: some View {
        let kind = model.site?.kind ?? .blog
        // Renaming adds redirects and duplicating rewrites the title, both in front matter, which a page served as it
        // is must not get.
        if !doc.isStatic, !kind.servesFilesAsIs {
            Button("Rename or Move…") { model.moveRequest = doc }
            Button("Duplicate") { model.duplicate(doc) }
        }
        if doc.origin == .repository, model.status(of: doc) != .notPublished {
            Button("Version History…") { model.historyRequest = doc }
        }
        Divider()
        if doc.origin == .localDraft {
            Button("Delete Draft…", role: .destructive) { model.deleteDraft(doc) }
        } else {
            if let url = model.liveURL(for: doc), model.status(of: doc) != .notPublished {
                Button("Open on Site") { NSWorkspace.shared.open(url) }
            }
            if model.changes[doc.relativePath] != nil {
                Button("Discard Unpublished Changes…") { model.discardChanges(doc) }
            }
            if kind != .generated {
                Divider()
                if doc.relativePath.hasPrefix("_"), model.status(of: doc) != .notPublished {
                    Button("Unpublish to Drafts…") { model.unpublish(doc) }
                }
                Button("Delete from Site…", role: .destructive) { model.deleteFromSite(doc) }
            }
        }
        Divider()
        Button("Show in Finder") { model.revealInFinder(doc) }
    }
}

struct DocumentRow: View {
    let doc: SiteDocument
    let status: DocumentStatus

    var subtitle: String {
        switch status {
        case .draft:
            String(localized: "Draft · edited \(doc.modified.formatted(.relative(presentation: .named)))")
        case .edited:
            String(localized: "Edited · not yet updated")
        default:
            if let date = doc.date {
                String(localized: "\(status.label) · \(date.formatted(.dateTime.month(.abbreviated).day().year()))")
            } else {
                status.label
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .font(.system(size: 11, weight: .semibold))
                .help(status.label)
                .accessibilityLabel(status.label)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title.isEmpty ? String(localized: "Untitled") : doc.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(doc.title.isEmpty ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !doc.excerpt.isEmpty {
                    Text(doc.excerpt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let editor = model.editor, editor.document.isStatic || model.site?.kind.servesFilesAsIs == true {
            StaticPageEditor(model: model, editor: editor)
        } else if let editor = model.editor {
            // The editor keeps its place whether or not the preview is beside it, so its text view (cursor, scroll,
            // undo) survives the toggle.
            HSplitView {
                EditorView(model: model, editor: editor)
                    .frame(minWidth: 360)
                if model.showPreview {
                    PreviewPane(model: model, editor: editor)
                        .frame(minWidth: 320)
                }
            }
        } else if model.sidebarSelection == .section("pages") {
            ContentUnavailableView("No Page Selected", systemImage: "doc.richtext",
                                   description: Text(model.site?.kind.servesFilesAsIs == true
                                       ? "Choose a page to edit its HTML."
                                       : "Choose a page, or press ⇧⌘N to make a new one."))
        } else {
            ContentUnavailableView("No Post Selected", systemImage: "square.and.pencil",
                                   description: Text("Choose a post, or press ⌘N to write a new one."))
        }
    }
}
