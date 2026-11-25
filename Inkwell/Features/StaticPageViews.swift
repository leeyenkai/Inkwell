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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            StaticPageProperties(model: model, editor: editor, readOnly: readOnly)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Built by another program", systemImage: "lock").font(.callout.weight(.semibold))
            Text("This folder holds a site generator's output. Edit the site's source and build it again; changes made here would be lost.")
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
