import InkwellKit
import SwiftUI

struct MoveSheet: View {
    var model: AppModel
    var doc: SiteDocument
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var slug = ""
    @State private var sectionID = ""
    @State private var keepOld = true

    var isPublished: Bool { doc.origin == .repository && model.status(of: doc) != .notPublished }

    var newAddress: String {
        guard let site = model.site else { return "" }
        let parts = Filename.parse(doc.filename)
        let file = (parts.dateText.map { "\($0)-" } ?? "") + Slug.make(slug.isEmpty ? title : slug) + ".\(parts.ext.isEmpty ? "md" : parts.ext)"
        if let collection = site.section(sectionID)?.collectionName {
            return Permalink.display(Permalink.url(collection: collection, filename: file, date: doc.date, config: site.config), config: site.config)
        }
        return Permalink.display(Permalink.pageURL(relativePath: file, config: site.config), config: site.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(doc.origin == .localDraft ? String(localized: "Rename or move draft") : String(localized: "Rename or move"))
                .font(.title2.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                TextField("Address", text: $slug, prompt: Text(Slug.make(title)))
                if doc.relativePath.hasPrefix("_") {
                    Picker("Section", selection: $sectionID) {
                        ForEach(model.movableSections) { Text($0.label).tag($0.id) }
                    }
                }
                LabeledContent("New address") { Text(newAddress).font(.callout.monospaced()).textSelection(.enabled) }
                if isPublished {
                    Toggle("Keep the old address working", isOn: $keepOld)
                    let old = model.site.map { Permalink.display(doc.url, config: $0.config) } ?? doc.url
                    Text("Visitors and search engines using \(old) are sent to the new address. Links in your other posts are updated either way.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isPublished ? String(localized: "Move…") : String(localized: "Save")) {
                    let (t, s, section, keep) = (title, slug, sectionID, keepOld)
                    dismiss()
                    DispatchQueue.main.async { model.applyMove(doc, title: t, slug: s, sectionID: section, keepOldAddress: keep) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            title = doc.title
            slug = Filename.parse(doc.filename).slug
            sectionID = doc.sectionID
        }
    }
}

struct NewPageSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var addToMenu = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New page").font(.title2.weight(.semibold))
            Text("A standalone page, such as About, Now or Contact.").foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title, prompt: Text("Now"))
                Toggle("Add to the menu", isOn: $addToMenu)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Page") {
                    let (t, menu) = (title, addToMenu)
                    dismiss()
                    DispatchQueue.main.async { model.createPage(title: t, addToMenu: menu) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct HistorySheet: View {
    var model: AppModel
    var doc: SiteDocument
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [Revision] = []
    @State private var selected: Revision?
    @State private var text: String?
    @State private var loading = true
    @State private var error: String?

    var current: String { (try? String(contentsOf: doc.fileURL, encoding: .utf8)) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History of “\(doc.title)”").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                List(revisions, selection: $selected) { revision in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(revision.title).lineLimit(1)
                        Text([revision.date?.formatted(date: .abbreviated, time: .shortened), revision.author.isEmpty ? nil : revision.author]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(revision)
                }
                .frame(width: 240)
                .overlay {
                    if loading { ProgressView() } else if let error {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding()
                    } else if revisions.isEmpty {
                        Text("Not published yet, so there is no history.").font(.caption).foregroundStyle(.secondary).padding()
                    }
                }
                ScrollView {
                    if let text {
                        DiffView(lines: TextDiff.lines(from: text, to: current))
                    } else {
                        Text("Choose a version to see how it differs from the text on this Mac.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 380)
            HStack {
                Text("Lines in red were removed since that version; green were added.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore This Version") { restore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text == nil)
            }
        }
        .padding(24)
        .frame(width: 860)
        .task { await load() }
        .onChange(of: selected) { Task { await loadText() } }
    }

    func load() async {
        guard let backend = model.backend else { return }
        do {
            revisions = try await backend.history(of: doc.relativePath)
            selected = revisions.first
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func loadText() async {
        guard let backend = model.backend, let selected else { return }
        text = try? await backend.contents(of: doc.relativePath, at: selected.id)
    }

    /// Puts the old text back as an unpublished edit; Update publishes it, and nothing in the history is rewritten.
    func restore() {
        guard let text else { return }
        if let editor = model.editor, editor.document.id == doc.id {
            editor.setFullText(text)
            editor.saveNow()
            editor.reloadFromView()
        } else {
            try? Data(text.utf8).write(to: doc.fileURL, options: .atomic)
            model.select(doc.id)
        }
        model.reloadSite()
        dismiss()
    }
}

struct DiffView: View {
    var lines: [TextDiff.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case let .same(text): row(text, " ", nil)
                case let .added(text): row(text, "+", .green)
                case let .removed(text): row(text, "−", .red)
                }
            }
        }
        .padding(8)
        .textSelection(.enabled)
    }

    func row(_ text: String, _ mark: String, _ color: Color?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark).foregroundStyle(color ?? .secondary).frame(width: 10)
            Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 1)
        .background(color.map { $0.opacity(0.12) } ?? .clear)
    }
}

// MARK: Tags

struct TagsList: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedTag) {
            ForEach(model.allTags, id: \.name) { tag in
                HStack {
                    Label(tag.name, systemImage: "tag")
                    Spacer()
                    Text(tag.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(tag.name)
            }
        }
        .overlay {
            if model.allTags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "tag", description: Text("Add a tags property to a post, such as tags: [travel, essays]."))
            }
        }
        .navigationTitle("Tags")
    }
}

struct TagDetail: View {
    var model: AppModel
    var tag: String
    @State private var newName = ""

    var body: some View {
        let docs = model.documents(tagged: tag)
        Form {
            Section("Rename or merge") {
                HStack {
                    TextField("", text: $newName, prompt: Text("New name, or an existing tag to merge into")).labelsHidden()
                    Button(model.tagIndex[newName] != nil && newName != tag ? String(localized: "Merge") : String(localized: "Rename")) {
                        model.renameTag(tag, to: newName.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == tag)
                }
                Button("Remove from All Posts…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Remove the tag “\(tag)” from \(docs.count) posts?")
                    alert.informativeText = String(localized: """
                    The posts stay; only the tag is taken off. Changes are published with your next update.
                    """)
                    alert.addButton(withTitle: String(localized: "Remove Tag"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    if alert.runModal() == .alertFirstButtonReturn { model.renameTag(tag, to: nil) }
                }
            }
            Section("\(docs.count) posts") {
                ForEach(docs) { doc in
                    Button {
                        model.sidebarSelection = .section(doc.sectionID)
                        model.select(doc.id)
                    } label: {
                        HStack {
                            Image(systemName: model.status(of: doc).symbol).foregroundStyle(model.status(of: doc).color)
                            Text(doc.title.isEmpty ? String(localized: "Untitled") : doc.title)
                            Spacer()
                            Text(doc.date?.formatted(date: .abbreviated, time: .omitted) ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { newName = tag }
        .onChange(of: tag) { newName = tag }
    }
}

/// Picks a post or page to link to, for `[[` and the slash menu.
struct LinkPickerSheet: View {
    var model: AppModel
    var location: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var results: [SiteDocument] {
        let docs = (model.site?.documents ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Array(docs.prefix(40)) : docs.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Link to a post or page", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = results.first { choose(first) } }
            List(results) { doc in
                Button {
                    choose(doc)
                } label: {
                    HStack {
                        Image(systemName: model.site?.section(doc.sectionID)?.symbol ?? "doc.text").foregroundStyle(.secondary)
                        Text(doc.title)
                        Spacer()
                        Text(doc.url).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
            HStack {
                Text("Links use the page’s address, so they keep working if you rename it in Inkwell.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear { focused = true }
    }

    func choose(_ doc: SiteDocument) {
        model.textView?.insertLink(title: doc.title, url: doc.url, replacing: location)
        dismiss()
    }
}
