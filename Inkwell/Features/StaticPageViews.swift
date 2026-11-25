import InkwellKit
import SwiftUI

/// A page GitHub Pages serves as it is (HTML without front matter, or any page on a site Jekyll does not build),
/// edited as its own source beside a live preview. Nothing is added to the file: no front matter, no Liquid.
struct StaticPageEditor: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument

    var readOnly: Bool { model.site?.kind == .generated }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(editor.document.title).font(.headline).lineLimit(1)
                Text(editor.document.relativePath).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if readOnly {
                    Label("Read only", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: $model.editOnPage) {
                        Label("Edit on Page", systemImage: "cursorarrow.and.square.on.square.dashed")
                    }
                    .toggleStyle(.button)
                    .help("Click text in the preview to change it, or a picture to replace it")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            StaticPageProperties(model: model, editor: editor, readOnly: readOnly)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            if !readOnly {
                SharedPartsBanner(model: model, editor: editor)
            }
            Divider()
            HSplitView {
                CodeEditor(text: Binding(get: { editor.fullText }, set: { editor.setFullText($0) }), fileExtension: "html",
                           editable: !readOnly, identity: editor.document.id,
                           onDropImages: readOnly ? nil : { urls, location in model.importImagesIntoPage(urls, at: location) })
                    .frame(minWidth: 360)
                PreviewPane(model: model, editor: editor)
                    .frame(minWidth: 320)
            }
        }
    }
}

/// Explains why a site built by another program opens read only.
struct GeneratedSiteNotice: View {
    var builtByWorkflow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Built by another program", systemImage: "lock").font(.callout.weight(.semibold))
            Group {
                if builtByWorkflow {
                    Text("A GitHub Actions workflow builds this site with another program, from the source shown here. Edit it with that program.")
                } else {
                    Text("This folder holds a site generator's output. Edit the site's source and build it again; changes made here would be lost.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }
}

/// A page's title, description and share image, read from its `<head>`. Each change rewrites only that value in the
/// file, or adds the one missing tag before `</head>`.
struct StaticPageProperties: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument
    var readOnly: Bool
    @State private var title = ""
    @State private var summary = ""
    @State private var image = ""

    var body: some View {
        DisclosureGroup(isExpanded: $model.showProperties) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                row("Title", text: $title, prompt: "Shown in the browser tab and search results", field: .title)
                row("Description", text: $summary, prompt: "A sentence for search results and shared links", field: .description)
                row("Share image", text: $image, prompt: "media/picture.jpg", field: .image)
            }
            .font(.callout)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(readOnly)
        } label: {
            Text("Properties").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .onAppear { load() }
        .onChange(of: editor.document.id) { load() }
        .onChange(of: editor.fullText) { load(keepingTyped: true) }
    }

    func row(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, field: HTMLHead.Field) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(label, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, value in
                    let updated = HTMLHead.setting(field, to: value.trimmingCharacters(in: .whitespacesAndNewlines), in: editor.fullText)
                    if updated != editor.fullText { editor.setFullText(updated) }
                }
        }
    }

    /// Fills the fields from the page. While typing, a field keeps what was typed when it says the same thing as the
    /// page (a trailing space, say), so the cursor does not jump.
    func load(keepingTyped: Bool = false) {
        let head = HTMLHead(editor.fullText)
        func pick(_ current: String, _ found: String?) -> String {
            let found = found ?? ""
            return keepingTyped && current.trimmingCharacters(in: .whitespacesAndNewlines) == found ? current : found
        }
        title = pick(title, head.title)
        summary = pick(summary, head.description)
        image = pick(image, head.image)
    }
}

/// A new page for a hand-built site, copying the head, header and footer of an existing page.
struct NewHTMLPageSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var sourceID: String?

    var pages: [SiteDocument] { (model.site?.documents ?? []).filter(\.isStatic).sorted { $0.relativePath < $1.relativePath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Page").font(.title2.weight(.semibold))
            Text("The new page copies the look of an existing one: its stylesheets, header and footer. Its main part starts empty.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Title", text: $title, prompt: Text("Pricing"))
                Picker("Based on", selection: $sourceID) {
                    ForEach(pages) { page in
                        Text(verbatim: "\(page.title) (\(page.relativePath))").tag(Optional(page.id))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Page") {
                    model.createHTMLPage(title: title.trimmingCharacters(in: .whitespaces), basedOn: pages.first { $0.id == sourceID })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { sourceID = (pages.first { $0.relativePath == "index.html" } ?? pages.first)?.id }
    }
}

/// When this page's header, menu or footer is changed and other pages have an identical copy of the old one, offers to
/// change those copies too (SPEC §4.12, W4).
struct SharedPartsBanner: View {
    var model: AppModel
    @Bindable var editor: EditorDocument
    /// The page as it was opened, and the other pages' text then.
    @State private var opened = ""
    @State private var others: [(SiteDocument, String)] = []
    @State private var dismissed: Set<String> = []

    struct Offer: Identifiable {
        var part: SharedParts.Part
        var old: String
        var new: String
        var pages: [SiteDocument]
        var id: String { part.rawValue + String(old.hashValue) + String(new.hashValue) }
    }

    var offers: [Offer] {
        SharedParts.changes(from: opened, to: editor.fullText).compactMap { change in
            let pages = others.filter { SharedParts.applying(change.old, change.new, to: $0.1) != nil }.map(\.0)
            let offer = Offer(part: change.part, old: change.old, new: change.new, pages: pages)
            return pages.isEmpty || dismissed.contains(offer.id) ? nil : offer
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(offers) { offer in
                HStack(spacing: 10) {
                    Image(systemName: "square.on.square").foregroundStyle(Color.accentColor)
                    Text("\(offer.pages.count) other pages have the same \(offer.part.title).")
                        .help(offer.pages.map(\.relativePath).joined(separator: ", "))
                    Spacer()
                    Button("Not Now") { dismissed.insert(offer.id) }
                    Button("Change Them Too") {
                        editor.saveNow()
                        model.applySharedPart(old: offer.old, new: offer.new, to: offer.pages)
                        load()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }
        }
        .onAppear(perform: load)
        .onChange(of: editor.document.id) { load() }
    }

    func load() {
        opened = editor.fullText
        dismissed = []
        let mine = editor.document.relativePath
        others = (model.site?.documents ?? []).filter { $0.editsAsHTML && $0.relativePath != mine }.compactMap { doc in
            (try? String(contentsOf: doc.fileURL, encoding: .utf8)).map { (doc, $0) }
        }
    }
}

/// Changes the address of a link clicked in the preview of a hand-built page. Pages of the site are offered with
/// addresses relative to this page, as hand-built sites write them.
struct PageLinkSheet: View {
    var model: AppModel
    var edit: AppModel.PageLinkEdit
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var pages: [(title: String, address: String)] {
        (model.site?.documents ?? []).filter(\.editsAsHTML).sorted { $0.relativePath < $1.relativePath }.compactMap { doc in
            doc.relativePath == edit.page ? nil : (doc.title, SitePath.relative(to: doc.relativePath, from: edit.page))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link Address").font(.title2.weight(.semibold))
            HStack {
                TextField("Address", text: $address, prompt: Text(verbatim: "https://"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Menu("Pages") {
                    ForEach(pages, id: \.address) { page in
                        Button {
                            address = page.address
                        } label: {
                            Text(verbatim: "\(page.title) (\(page.address))")
                        }
                    }
                }
                .fixedSize()
                .disabled(pages.isEmpty)
            }
            Text("Only the address changes in the file. The link’s text is changed by clicking it on the page.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { address = edit.address }
    }

    func save() {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.finishPageLinkEdit(edit, address: address)
        dismiss()
    }
}
