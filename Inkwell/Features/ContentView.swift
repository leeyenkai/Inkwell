import InkwellKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.site != nil {
                SiteWindow(model: model)
            } else {
                WelcomeView(model: model)
            }
        }
        .alert("Inkwell", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Inkwell")
                .font(.largeTitle.weight(.semibold))
            Text("Write, preview and publish to your GitHub Pages site.\nOpen the folder where your site lives on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Site Folder…") { model.openSitePanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(60)
        .frame(minWidth: 640, minHeight: 440)
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
            DocumentListView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            DetailView(model: model)
        }
        .navigationTitle(model.site?.name ?? "Inkwell")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
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
                            if section.collectionName != nil {
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
        HStack(spacing: 6) {
            if !model.hasGit {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Not a git folder")
            } else if model.pendingChanges == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.drafts.isEmpty ? "Everything is published" : "Site up to date · \(model.drafts.count) draft\(model.drafts.count == 1 ? "" : "s")")
            } else {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
                Text("\(model.pendingChanges) not yet published")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct DocumentListView: View {
    @Bindable var model: AppModel

    var title: String {
        switch model.sidebarSelection {
        case let .section(id)?: model.site?.section(id)?.label ?? ""
        case .drafts?: "Drafts"
        case nil: ""
        }
    }

    var body: some View {
        let docs = model.documents(for: model.sidebarSelection)
        List(selection: Binding(get: { model.selectedDocumentID }, set: { model.select($0) })) {
            ForEach(docs) { doc in
                DocumentRow(doc: doc, status: model.status(of: doc), committed: model.lastCommitDates[doc.relativePath])
                    .tag(doc.id)
                    .contextMenu {
                        if doc.origin == .localDraft {
                            Button("Delete Draft…", role: .destructive) { model.deleteDraft(doc) }
                        }
                        Button("Show in Finder") { model.revealInFinder(doc) }
                        if let url = model.liveURL(for: doc), doc.origin == .repository {
                            Button("Open on Site") { NSWorkspace.shared.open(url) }
                        }
                    }
            }
        }
        .listStyle(.inset)
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

struct DocumentRow: View {
    let doc: SiteDocument
    let status: DocumentStatus
    let committed: Date?

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
