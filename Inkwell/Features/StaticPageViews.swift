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
            Divider()
            HSplitView {
                CodeEditor(text: Binding(get: { editor.fullText }, set: { editor.setFullText($0) }), fileExtension: "html",
                           editable: !readOnly, identity: editor.document.id)
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
