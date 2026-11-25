import InkwellKit
import SwiftUI

/// The post's description and share image, with a preview of how a link to it looks in search results and chats.
struct SharingView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument

    var body: some View {
        DisclosureGroup(isExpanded: $model.showSharing) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    if !editor.fields.contains(where: { $0.key == "description" }) {
                        TextField("Description", text: Binding(get: { editor.string("description") }, set: { editor.setString("description", $0) }),
                                  prompt: Text("A sentence for search results and link previews"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2 ... 4)
                    }
                    HStack {
                        Button(editor.string("image").isEmpty
                            ? String(localized: "Choose Share Image…") : String(localized: "Change Share Image…")) { chooseImage() }
                        if !editor.string("image").isEmpty {
                            Button("Remove") {
                                let previous = editor.string("image")
                                editor.setRaw("image", nil)
                                discardUnpublishedShareImage(previous)
                            }
                        }
                    }
                    .controlSize(.small)
                    ForEach(hints, id: \.self) { hint in
                        Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LinkPreviewCard(title: cardTitle, description: cardDescription, host: host, image: imageURL)
                    .frame(width: 260)
            }
            .font(.callout)
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            Text("Search and sharing").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    var siteTitle: String { model.site?.config.title ?? "" }

    /// jekyll-seo-tag writes "Post title | Site title".
    var cardTitle: String {
        let title = editor.isCollectionPost ? editor.title : editor.document.title
        guard !siteTitle.isEmpty, title != siteTitle else { return title }
        return title.isEmpty ? siteTitle : "\(title) | \(siteTitle)"
    }

    var description: String {
        let own = editor.string("description")
        if !own.isEmpty { return own }
        return editor.string("byline")
    }

    var cardDescription: String {
        description.isEmpty ? Excerpt.make(editor.body, title: editor.title) : description
    }

    var host: String {
        guard let url = model.site?.config.url, let host = URL(string: url)?.host() else { return "" }
        return host
    }

    var imageURL: URL? {
        let own = editor.string("image")
        let site = model.site?.config.raw["inkwell"]?["social_image"]?.string ?? model.site?.config.raw["image"]?.string ?? ""
        return model.fileURL(forSitePath: own.isEmpty ? site : own)
    }

    var hints: [String] {
        var result: [String] = []
        if cardTitle.count > 60 { result.append(String(localized: "Search results cut titles after about 60 characters.")) }
        if description.isEmpty {
            result.append(String(localized: "Without a description, search engines and previews use the first paragraph."))
        } else if description.count > 160 {
            result.append(String(localized: "Search results cut descriptions after about 160 characters."))
        }
        return result
    }

    /// A share picture imported here and never published is moved to the Trash when it is replaced or removed, so it
    /// does not linger as a change waiting to be published. One that any post, page or draft still uses stays.
    func discardUnpublishedShareImage(_ sitePath: String) {
        let path = String(sitePath.drop { $0 == "/" })
        guard !path.isEmpty, path.contains("-share"), model.changes[path] == .added, let url = model.fileURL(forSitePath: sitePath),
              let root = model.site?.root else { return }
        editor.saveNow()
        let drafts = model.draftTexts()
        Task {
            let unused = await Task.detached {
                MediaLibrary.scan(siteRoot: root, extraTexts: drafts).first { $0.path == path }?.isUnused ?? false
            }.value
            guard unused, model.site?.root == root else { return }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            model.refreshChanges()
        }
    }

    func chooseImage() {
        guard let site = model.site else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose the picture shown when this post is shared. A wide image (1200 × 630) works best.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let slug = Filename.parse(editor.document.filename).slug
        do {
            let image = try ImageImport.app.importImage(at: url, siteRoot: site.root, slug: (slug == "untitled" ? "post" : slug) + "-share")
            let previous = editor.string("image")
            editor.setRaw("image", image.sitePath)
            discardUnpublishedShareImage(previous)
            model.refreshChanges()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Roughly how chat apps and social sites show a link: picture, title, description, address.
struct LinkPreviewCard: View {
    var title: String
    var description: String
    var host: String
    var image: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image, let picture = Thumbnails.shared.image(for: image, size: 600) {
                Color.clear.aspectRatio(1.91, contentMode: .fit)
                    .overlay { Image(nsImage: picture).resizable().scaledToFill() }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(host.uppercased()).font(.caption2).foregroundStyle(.secondary)
                Text(title.isEmpty ? String(localized: "Untitled") : title).font(.callout.weight(.semibold)).lineLimit(2)
                if !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link preview: \(title). \(description)")
    }
}
