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
                if let id = model.selectedPhotoID, let photo = model.photos.first(where: { $0.id == id }) {
                    PhotoDetail(model: model, photo: photo)
                } else {
                    ContentUnavailableView("Choose a photo", systemImage: "photo", description: Text("Edit its caption, alt text, place and date."))
                }
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
        .sheet(isPresented: $model.showPhotoSetup) { PhotoSetupSheet(model: model) }
        .sheet(isPresented: $model.showSiteSummary) { SiteSummarySheet(model: model) }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Site") {
                ForEach(model.site?.sections ?? []) { section in
                    Label {
                        HStack {
                            Text(section.label)
                            Spacer()
                            if section.listsDocuments {
                                Text("\(model.count(for: section.id))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .tag(SidebarSelection.section(section.id))
                }
            }
            Section("Writing") {
                Label {
                    HStack {
                        Text("Drafts")
                        Spacer()
                        Text("\(model.documents(for: .drafts).count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .tag(SidebarSelection.drafts)
                Label("Tags", systemImage: "tag").tag(SidebarSelection.tags)
                Label("Media", systemImage: "photo.stack").tag(SidebarSelection.media)
                Label {
                    HStack {
                        Text("Health")
                        Spacer()
                        if model.healthProblems > 0 {
                            Text("\(model.healthProblems)").foregroundStyle(.secondary).monospacedDigit()
                                .accessibilityLabel("\(model.healthProblems) problems")
                        }
                    }
                } icon: {
                    Image(systemName: "stethoscope")
                }
                .tag(SidebarSelection.health)
            }
            Section("Design") {
                Label("Theme & Style", systemImage: "paintpalette").tag(SidebarSelection.design)
                Label("Navigation", systemImage: "menubar.rectangle").tag(SidebarSelection.navigation)
                Label("Settings", systemImage: "gearshape").tag(SidebarSelection.settings)
                Label("Code", systemImage: "chevron.left.forwardslash.chevron.right").tag(SidebarSelection.code)
            }
        }
        .listStyle(.sidebar)
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
                    Label("\(model.pendingChanges) unpublished change\(model.pendingChanges == 1 ? "" : "s")", systemImage: "pencil.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Review and publish them (⌥⇧⌘P)")
            } else {
                Label(model.drafts.isEmpty ? "Site up to date" : "Site up to date · \(model.drafts.count) draft\(model.drafts.count == 1 ? "" : "s")",
                      systemImage: "checkmark.circle.fill")
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
            Label(model.backend?.displayName ?? "Site", systemImage: "globe")
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
        case .drafts?: "Drafts"
        case .design?: "Design"
        case .navigation?: "Navigation"
        case .settings?: "Settings"
        case .code?: "Code"
        case .tags?: "Tags"
        case .media?: "Media"
        case .health?: "Health"
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
                    Label(model.searchText.isEmpty ? "Nothing here yet" : "No Results", systemImage: "doc.text")
                } description: {
                    Text(model.searchText.isEmpty ? "Press ⌘N to start a post." : "Try a different search.")
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(docs.count) item\(docs.count == 1 ? "" : "s")")
    }
}

struct DocumentMenu: View {
    var model: AppModel
    var doc: SiteDocument

    var body: some View {
        Button("Rename or Move…") { model.moveRequest = doc }
        Button("Duplicate") { model.duplicate(doc) }
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
            Divider()
            if doc.relativePath.hasPrefix("_"), model.status(of: doc) != .notPublished {
                Button("Unpublish to Drafts…") { model.unpublish(doc) }
            }
            Button("Delete from Site…", role: .destructive) { model.deleteFromSite(doc) }
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
            "Draft · edited \(doc.modified.formatted(.relative(presentation: .named)))"
        case .edited:
            "Edited · not yet updated"
        default:
            if let date = doc.date { "\(status.label) · \(date.formatted(.dateTime.month(.abbreviated).day().year()))" } else { status.label }
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
                Text(doc.title.isEmpty ? "Untitled" : doc.title)
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
        if let editor = model.editor {
            if model.showPreview {
                HSplitView {
                    EditorView(model: model, editor: editor)
                        .frame(minWidth: 360)
                    PreviewPane(model: model, editor: editor)
                        .frame(minWidth: 320)
                }
            } else {
                EditorView(model: model, editor: editor)
            }
        } else {
            ContentUnavailableView("No Post Selected", systemImage: "square.and.pencil",
                                   description: Text("Choose a post, or press ⌘N to write a new one."))
        }
    }
}
