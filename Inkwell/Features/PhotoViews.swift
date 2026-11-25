import InkwellKit
import SwiftUI

struct PhotoGrid: View {
    @Bindable var model: AppModel

    var body: some View {
        let all = model.photos
        let photos = model.shownPhotos(all)
        let albums = model.albums
        let selection = model.photoSelection
        let album = model.albumFilter.albumID.flatMap { id in albums.first { $0.id == id } }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(photos) { photo in
                    let chosen = selection.contains(photo.id)
                    let paths = chosen ? model.selectedPhotoPaths(all) : [photo.doc.relativePath]
                    PhotoTile(model: model, photo: photo, selected: chosen)
                        .choosable(photo.caption.isEmpty ? String(localized: "Photo") : photo.caption, selected: chosen) {
                            model.clickPhoto(photo.id, in: photos)
                        }
                        .draggable(paths.joined(separator: "\n")) {
                            DragPreview(url: model.fileURL(forSitePath: photo.image), count: paths.count)
                        }
                        .contextMenu {
                            PhotoMenu(model: model, photo: photo, paths: paths, albums: albums, album: album)
                        }
                }
            }
            .padding(10)
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAllPhotos(photos) }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No photos yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Add photos from your Mac. Each gets a caption, and they appear newest first.")
                } actions: {
                    Button("Add Photos…") { choosePhotos() }
                }
            } else if photos.isEmpty, let album {
                ContentUnavailableView {
                    Label("No photos in “\(album.title)”", systemImage: "rectangle.stack")
                } description: {
                    Text("Drag photos onto the album, or choose some in All Photos and use Add to Album. Photos you add now join it.")
                } actions: {
                    Button("Add Photos…") { choosePhotos() }
                }
            } else if photos.isEmpty {
                ContentUnavailableView("Every photo is in an album", systemImage: "checkmark.rectangle.stack")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            AlbumBar(model: model, albums: albums, photos: all)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { choosePhotos() } label: {
                    // With photos chosen the bar is busy, so the button shrinks to its symbol.
                    Label("Add Photos…", systemImage: "plus").labelStyle(AdaptiveLabelStyle(iconOnly: !selection.isEmpty))
                }
                .fixedSize()
                .help(album.map { String(localized: "New photos join “\($0.title)”") }
                        ?? String(localized: "Add photos from your Mac"))
                if !selection.isEmpty {
                    let paths = model.selectedPhotoPaths(all)
                    AddToAlbumMenu(model: model, albums: albums, paths: paths)
                    if let album {
                        Button("Remove from Album") { model.removePhotos(paths, from: album.id) }
                            .help(String(localized: "The photos stay in your photo stream"))
                    }
                }
                Spacer()
                Text(selection.count > 1 ? "\(selection.count) of \(photos.count) chosen" : "\(photos.count) photos")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Photos")
        .navigationSubtitle(album?.title ?? (model.albumFilter == .none ? String(localized: "Not in an Album") : ""))
        .sheet(item: $model.newAlbumRequest) { request in NewAlbumSheet(model: model, request: request) }
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose photos. They are resized, turned upright and cleaned of location data.")
        if panel.runModal() == .OK { model.importPhotos(panel.urls) }
    }
}

/// The title alone, or the symbol alone where room is short (the title stays the accessibility label).
struct AdaptiveLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { configuration.title }
    }
}

/// What a photo's context menu offers; with several chosen, it acts on all of them.
struct PhotoMenu: View {
    var model: AppModel
    var photo: PhotoEntry
    var paths: [String]
    var albums: [Album]
    var album: Album?

    var body: some View {
        AddToAlbumMenu(model: model, albums: albums, paths: paths)
        if let album {
            Button("Remove from “\(album.title)”") { model.removePhotos(paths, from: album.id) }
            if paths.count == 1 {
                Button("Use as Album Cover") { model.changeAlbums { $0.setCover(album.id, image: photo.image) } }
                    .disabled(album.cover == photo.image)
            }
        }
        if paths.count == 1 {
            Divider()
            Button("Delete Photo…", role: .destructive) { model.deletePhoto(photo) }
        }
    }
}

/// Add to Album: every album, then New Album… which starts one with these photos.
struct AddToAlbumMenu: View {
    var model: AppModel
    var albums: [Album]
    var paths: [String]

    var body: some View {
        Menu {
            ForEach(albums) { album in
                Button(album.title) { model.addPhotos(paths, to: album.id) }
            }
            if !albums.isEmpty { Divider() }
            Button("New Album…") { model.newAlbumRequest = NewAlbumRequest(photoPaths: paths) }
        } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
        .fixedSize()
    }
}

/// The picture under the pointer while photos are dragged onto an album, with how many there are.
struct DragPreview: View {
    var url: URL?
    var count: Int

    var body: some View {
        SquareThumbnail(url: url)
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)").font(.caption.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 6, y: -6)
                }
            }
    }
}

// MARK: Albums

/// All Photos, each album and Not in an Album, above the grid. Photos dropped on an album join it; albums dragged onto
/// each other change the order the site shows them in.
struct AlbumBar: View {
    var model: AppModel
    var albums: [Album]
    var photos: [PhotoEntry]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    AlbumChip(model: model, filter: .all, title: String(localized: "All Photos"), count: photos.count,
                              symbol: "photo.on.rectangle")
                    ForEach(albums) { album in
                        AlbumChip(model: model, filter: .album(album.id), title: album.title,
                                  count: photos.count { $0.albums.contains(album.id) }, symbol: "rectangle.stack",
                                  cover: model.coverURL(for: album, photos: photos), album: album, albums: albums)
                    }
                    let loose = photos.count { $0.albums.isEmpty }
                    if !albums.isEmpty, loose > 0 || model.albumFilter == .none {
                        AlbumChip(model: model, filter: .none, title: String(localized: "Not in an Album"), count: loose,
                                  symbol: "rectangle.dashed")
                    }
                    Button {
                        model.newAlbumRequest = NewAlbumRequest()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.title3)
                                .frame(width: AlbumChip.side, height: AlbumChip.side)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                                .padding(3)
                            Text("New Album").font(.caption).lineLimit(1)
                        }
                        .frame(width: AlbumChip.side + 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "New album"))
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            Divider()
        }
        .background(.bar)
    }
}

struct AlbumChip: View {
    var model: AppModel
    var filter: AlbumFilter
    var title: String
    var count: Int
    var symbol: String
    var cover: URL?
    var album: Album?
    var albums: [Album] = []
    @State private var targeted = false

    static let side: CGFloat = 60
    var selected: Bool { model.albumFilter == filter }

    var body: some View {
        Button {
            model.showAlbum(filter)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let cover, let image = Thumbnails.shared.image(for: cover, size: 180) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: symbol).font(.title2).foregroundStyle(selected ? Color.accentColor : .secondary)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selected || targeted ? Color.accentColor : .clear, lineWidth: targeted ? 3 : 2.5))
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: Self.side + 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album == nil ? String(localized: "\(title), \(count) photos")
            : String(localized: "Album \(title), \(count) photos"))
        .accessibilityHint(album == nil ? "" : String(localized: "Shows its photos. Drop photos here to add them."))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .modifier(AlbumDragging(model: model, album: album, albums: albums, targeted: $targeted))
    }
}

/// An album takes photos dropped on it and can be dragged before another album; the menu and VoiceOver offer the same moves.
struct AlbumDragging: ViewModifier {
    var model: AppModel
    var album: Album?
    var albums: [Album]
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let album {
            let index = albums.firstIndex(of: album) ?? 0
            content
                .draggable("album:\(album.id)")
                .dropDestination(for: String.self) { items, _ in
                    let lines = items.flatMap { $0.split(separator: "\n").map(String.init) }
                    if let moved = lines.first(where: { $0.hasPrefix("album:") }) {
                        model.moveAlbum(String(moved.dropFirst(6)), before: album.id)
                    } else {
                        let photos = lines.filter { $0.hasPrefix("_\(PhotoStream.collection)/") }
                        guard !photos.isEmpty else { return false }
                        model.addPhotos(photos, to: album.id)
                    }
                    return true
                } isTargeted: { targeted = $0 }
                .contextMenu {
                    Button("Move Left") { model.moveAlbum(album.id, before: albums[index - 1].id) }.disabled(index == 0)
                    Button("Move Right") { model.moveAlbum(album.id, before: albums.dropFirst(index + 2).first?.id) }
                        .disabled(index == albums.count - 1)
                    Divider()
                    Button("Delete Album…", role: .destructive) { model.deleteAlbum(album) }
                }
                .accessibilityAction(named: "Move Left") {
                    if index > 0 { model.moveAlbum(album.id, before: albums[index - 1].id) }
                }
                .accessibilityAction(named: "Move Right") {
                    if index < albums.count - 1 { model.moveAlbum(album.id, before: albums.dropFirst(index + 2).first?.id) }
                }
        } else {
            content
        }
    }
}

/// The detail column for Photos: one photo, several chosen photos, or the album shown.
struct PhotosDetail: View {
    var model: AppModel

    var body: some View {
        let selection = model.photoSelection
        let photos = model.photos
        if selection.count > 1 {
            PhotoSelectionDetail(model: model, photos: photos.filter { selection.contains($0.id) })
        } else if let id = selection.first, let photo = photos.first(where: { $0.id == id }) {
            PhotoDetail(model: model, photo: photo)
        } else if let id = model.albumFilter.albumID, let album = model.albums.first(where: { $0.id == id }) {
            AlbumDetail(model: model, album: album, photos: photos.filter { $0.albums.contains(id) })
        } else {
            ContentUnavailableView("Choose a photo", systemImage: "photo", description: Text("Edit its caption, alt text, place and date."))
        }
    }
}

struct PhotoSelectionDetail: View {
    var model: AppModel
    var photos: [PhotoEntry]

    var body: some View {
        let paths = photos.map(\.doc.relativePath)
        let album = model.albumFilter.albumID.flatMap { id in model.albums.first { $0.id == id } }
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(photos.prefix(3).enumerated().reversed()), id: \.element.id) { offset, photo in
                    SquareThumbnail(url: model.fileURL(forSitePath: photo.image))
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.8), lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .rotationEffect(.degrees(Double(offset) * 5 - 5))
                        .offset(x: CGFloat(offset) * 14 - 14)
                }
            }
            .frame(height: 190)
            .accessibilityHidden(true)
            Text("\(photos.count) photos chosen").font(.title3.weight(.semibold))
            HStack {
                AddToAlbumMenu(model: model, albums: model.albums, paths: paths)
                if let album {
                    Button("Remove from “\(album.title)”") { model.removePhotos(paths, from: album.id) }
                }
            }
            Text("You can also drag them onto an album above the photos.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// An album's settings under a preview of its page.
struct AlbumDetail: View {
    var model: AppModel
    var album: Album
    var photos: [PhotoEntry]
    @State private var choosingCover = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let page = model.albumPreview(album), let site = model.site {
                    SitePreview(html: page.html, pageURL: site.config.baseurl + album.url, root: site.root, baseurl: site.config.baseurl,
                                resources: model.siteResources, appearance: model.previewAppearance)
                }
            }
            Form {
                LabeledContent("Title") {
                    CommitField(placeholder: String(localized: "Album title"), value: album.title) { title in
                        model.changeAlbums { $0.rename(album.id, to: title) }
                    }
                }
                LabeledContent("Description") {
                    CommitField(placeholder: String(localized: "Optional; shown under the title"), value: album.description) { text in
                        model.changeAlbums { $0.setDescription(album.id, to: text) }
                    }
                }
                LabeledContent("Cover") {
                    HStack {
                        SquareThumbnail(url: model.coverURL(for: album, photos: photos))
                            .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(album.cover.isEmpty ? "Newest photo" : "Chosen photo").foregroundStyle(.secondary)
                        Button("Choose…") { choosingCover = true }
                            .disabled(photos.isEmpty)
                            .popover(isPresented: $choosingCover) { CoverPicker(model: model, album: album, photos: photos) }
                    }
                }
                Picker("Photo order", selection: Binding(get: { album.oldestFirst }, set: { oldest in
                    model.changeAlbums { $0.setOldestFirst(album.id, oldest) }
                })) {
                    Text("Newest first").tag(false)
                    Text("Oldest first").tag(true)
                }
                LabeledContent("Address") {
                    Text((model.site?.config.baseurl ?? "") + album.url).font(.callout.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Delete Album…", role: .destructive) { model.deleteAlbum(album) }
                    Spacer()
                    if model.pendingChanges > 0 {
                        Button("Publish Changes…") { model.showChanges = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 330)
        }
    }
}

struct CoverPicker: View {
    var model: AppModel
    var album: Album
    var photos: [PhotoEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a cover").font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], spacing: 4) {
                    ForEach(photos) { photo in
                        SquareThumbnail(url: model.fileURL(forSitePath: photo.image))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(album.cover == photo.image ? Color.accentColor : .clear, lineWidth: 3))
                            .choosable(photo.caption.isEmpty ? String(localized: "Photo") : photo.caption,
                                       selected: album.cover == photo.image) {
                                model.changeAlbums { $0.setCover(album.id, image: photo.image) }
                                dismiss()
                            }
                    }
                }
            }
            .frame(height: 220)
            Button("Use the Newest Photo") {
                model.changeAlbums { $0.setCover(album.id, image: nil) }
                dismiss()
            }
            .disabled(album.cover.isEmpty)
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct NewAlbumSheet: View {
    var model: AppModel
    var request: NewAlbumRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var files: [(edit: ContentEdit, reason: String)] = []
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Album").font(.title2.weight(.semibold))
            Text(request.photoPaths.isEmpty
                ? "An album gets its own page on your site and is listed on the photos page. Nothing goes live until you publish."
                : "The \(request.photoPaths.count) chosen photos go into it. It gets its own page and is listed on the photos page.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $title, prompt: Text("Title, such as Japan 2025"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            TextField("Description", text: $description, prompt: Text("Description (optional)"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 4)
            if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                let id = Albums.newID(for: title, taken: Set(model.albums.map(\.id)))
                Text("Its address: \((model.site?.config.baseurl ?? "") + Albums.url(id))").font(.callout).foregroundStyle(.secondary)
            }
            if !files.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.edit.path) { step in
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.edit.path).font(.caption.monospaced()).frame(width: 190, alignment: .leading)
                                Text(step.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Also adds \(files.count) site files that show albums").font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Album", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { files = model.albumSiteChanges() }
    }

    func create() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createAlbum(title: title, description: description, adding: request.photoPaths)
        dismiss()
    }
}

struct PhotoTile: View {
    var model: AppModel
    var photo: PhotoEntry
    var selected: Bool

    var body: some View {
        SquareThumbnail(url: model.fileURL(forSitePath: photo.image)).overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if photo.hidden { Image(systemName: "eye.slash.fill") }
                if model.status(of: photo.doc) != .published, !photo.hidden { Image(systemName: "circle.fill").foregroundStyle(.orange) }
            }
            .font(.caption2)
            .padding(4)
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        .opacity(photo.hidden ? 0.5 : 1)
    }
}

extension View {
    /// A tile that can be chosen with the mouse or the keyboard (Tab, then Space), and says what it is to VoiceOver.
    func choosable(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A square crop of a picture that never grows past its grid cell.
struct SquareThumbnail: View {
    var url: URL?

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url, let image = Thumbnails.shared.image(for: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
    }
}

struct PhotoDetail: View {
    var model: AppModel
    var photo: PhotoEntry

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let url = model.fileURL(forSitePath: photo.image), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                }
            }
            Form {
                LabeledContent("Caption") {
                    CommitField(placeholder: String(localized: "What it shows, or a line about it"), value: photo.caption) {
                        model.updatePhoto(photo, key: "caption", value: $0)
                    }
                }
                LabeledContent("Alt text") {
                    CommitField(placeholder: String(localized: "For people who can’t see it"), value: photo.alt) {
                        model.updatePhoto(photo, key: "alt", value: $0)
                    }
                }
                LabeledContent("Place") {
                    CommitField(placeholder: String(localized: "Optional; never taken from the photo"), value: photo.location) {
                        model.updatePhoto(photo, key: "location", value: $0)
                    }
                }
                DatePicker("Date", selection: Binding(get: { photo.doc.date ?? Date() }, set: { date in
                    model.updatePhoto(photo, key: "date", value: YAMLFormat.date(date, timeZone: model.site?.config.timeZone ?? .current))
                }), displayedComponents: .date)
                Toggle("Hide from the photo stream", isOn: Binding(get: { photo.hidden }, set: {
                    model.updatePhoto(photo, key: "hidden", value: $0 ? "true" : nil)
                }))
                HStack {
                    Button("Delete Photo…", role: .destructive) { model.deletePhoto(photo) }
                    Spacer()
                    if model.pendingChanges > 0 {
                        Button("Publish Changes…") { model.showChanges = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 300)
        }
    }
}

/// One photo at a time after import: caption, alt text and place, Return for the next.
struct CaptionSheet: View {
    @Bindable var model: AppModel
    @State private var index = 0
    @State private var photos: [AppModel.PendingPhoto] = []
    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if photos.indices.contains(index) {
                HStack {
                    Text("Add captions").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(String(index + 1)) of \(String(photos.count))").foregroundStyle(.secondary).monospacedDigit()
                }
                if let image = Thumbnails.shared.image(for: photos[index].image.fileURL, size: 900) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 320).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                TextField("Caption", text: $photos[index].caption, prompt: Text("Caption (Return for the next photo)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($captionFocused)
                    .onSubmit(next)
                TextField("Alt text", text: $photos[index].alt, prompt: Text("Alt text: what it shows, for people who can’t see it"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(next)
                HStack {
                    TextField("Place", text: $photos[index].location, prompt: Text("Place (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(next)
                    DatePicker("Date", selection: $photos[index].date, displayedComponents: .date).labelsHidden()
                }
                HStack {
                    Button("Cancel") { model.cancelPendingPhotos() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if index > 0 { Button("Back") { index -= 1 } }
                    Button(index == photos.count - 1 ? "Add \(photos.count) Photos" : "Next", action: next)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            photos = model.pendingPhotos ?? []
            captionFocused = true
        }
    }

    func next() {
        if index < photos.count - 1 {
            index += 1
            captionFocused = true
        } else {
            model.savePendingPhotos(photos)
        }
    }
}

struct PhotoSetupSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: [(edit: ContentEdit, reason: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Photos").font(.title2.weight(.semibold))
            Text("Each photo becomes a small file with its caption, and the photos page lists them newest first. Nothing goes live until you publish.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(plan.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline) {
                    Text(step.edit.path).font(.callout.monospaced()).frame(width: 220, alignment: .leading)
                    Text(step.reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Up Photos") {
                    model.applyPhotoSetup(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { plan = model.setUpPhotos() }
    }
}

struct GallerySheet: View {
    @Bindable var model: AppModel

    var body: some View {
        if let gallery = model.pendingGallery {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a gallery of \(gallery.images.count) pictures").font(.title2.weight(.semibold))
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(gallery.images.indices, id: \.self) { i in
                            HStack {
                                if let image = Thumbnails.shared.image(for: gallery.images[i].fileURL) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                TextField("Alt text", text: Binding(get: { model.pendingGallery?.alts[i] ?? "" }, set: { model.pendingGallery?.alts[i] = $0 }),
                                          prompt: Text("Alt text: what it shows"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                HStack {
                    let albums = model.albums
                    if !albums.isEmpty {
                        Menu("Show an Album Instead") {
                            ForEach(albums) { album in
                                Button(album.title) { model.insertAlbum(album.id, replacing: gallery) }
                            }
                        }
                        .fixedSize()
                        .help(String(localized: "Shows one of your photo albums here, and leaves these pictures out"))
                    }
                    Spacer()
                    Button("Cancel") { model.cancelGallery() }.keyboardShortcut(.cancelAction)
                    Button("Insert Gallery") { if let g = model.pendingGallery { model.insertGallery(g) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 520)
        }
    }
}

// MARK: Media library

struct MediaGrid: View {
    @Bindable var model: AppModel
    @State private var items: [MediaLibrary.Item] = []
    @State private var unusedOnly = false
    @State private var loading = true

    var shown: [MediaLibrary.Item] { unusedOnly ? items.filter(\.usedBy.isEmpty) : items }

    var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(items.reduce(0) { $0 + $1.bytes }), countStyle: .file)
        return String(localized: "\(items.count) images · \(size)")
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(shown) { item in
                    VStack(spacing: 3) {
                        SquareThumbnail(url: model.site?.root.appending(path: item.path))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.selectedMedia == item.path ? Color.accentColor : .clear, lineWidth: 3))
                        Text(item.usedBy.isEmpty ? "Unused" : "\(item.usedBy.count) uses")
                            .font(.caption2).foregroundStyle(item.usedBy.isEmpty ? .orange : .secondary)
                    }
                    .choosable(spokenLabel(item), selected: model.selectedMedia == item.path) { model.selectedMedia = item.path }
                }
            }
            .padding(10)
        }
        .overlay { if loading { ProgressView() } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Unused only", isOn: $unusedOnly).toggleStyle(.checkbox)
                Spacer()
                let unused = items.filter(\.usedBy.isEmpty)
                // On a hand-built site, scripts can name pictures in ways Inkwell cannot follow, so "unused" is a guess.
                if model.site?.kind.servesFilesAsIs != true {
                    Button("Delete \(unused.count) Unused…") { deleteUnused(unused) }.disabled(unused.isEmpty)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Media")
        .navigationSubtitle(subtitle)
        .task(id: model.mediaRevision) { await load() }
    }

    func spokenLabel(_ item: MediaLibrary.Item) -> String {
        let name = (item.path as NSString).lastPathComponent
        return item.usedBy.isEmpty ? String(localized: "\(name), unused") : String(localized: "\(name), used \(item.usedBy.count) times")
    }

    func load() async {
        guard let root = model.site?.root else { return }
        items = await Task.detached { MediaLibrary.scan(siteRoot: root) }.value
        model.mediaItems = items
        loading = false
    }

    func deleteUnused(_ unused: [MediaLibrary.Item]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(unused.count) unused images?")
        alert.informativeText = String(localized: """
            No post, page or stylesheet links to them. They leave the site when you next publish; GitHub keeps their history.
            """)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let root = model.site?.root else { return }
        for item in unused { try? FileManager.default.removeItem(at: root.appending(path: item.path)) }
        model.selectedMedia = nil
        model.mediaRevision += 1
        model.refreshChanges()
    }
}

struct MediaDetail: View {
    var model: AppModel
    var item: MediaLibrary.Item

    var url: URL? { model.site?.root.appending(path: item.path) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                }
            }
            Form {
                LabeledContent("File") { Text(item.path).font(.callout.monospaced()).textSelection(.enabled) }
                LabeledContent("Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file) + dimensions)
                        .foregroundStyle(item.bytes > 1_000_000 ? .orange : .primary)
                }
                LabeledContent("Used in") {
                    VStack(alignment: .trailing) {
                        if item.usedBy.isEmpty { Text("Nothing links to it").foregroundStyle(.orange) }
                        ForEach(item.usedBy, id: \.self) { path in
                            Button(path) {
                                if let doc = model.site?.documents.first(where: { $0.relativePath == path }) {
                                    model.sidebarSelection = .section(doc.sectionID)
                                    if doc.sectionID == PhotoStream.collection { model.selectedPhotoID = doc.id } else { model.select(doc.id) }
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Button("Replace…") { replace() }
                        .help("Choose another picture to use in its place; links to it keep working")
                    Spacer()
                    Button("Delete…", role: .destructive) { delete() }
                }
            }
            .formStyle(.grouped)
            .frame(height: 260)
        }
    }

    var dimensions: String {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return "" }
        return " · \(w) × \(h)"
    }

    func replace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url, let url else { return }
        do {
            _ = try ImageImport.app.replace(url, with: source)
            Thumbnails.shared.forget(url)
            model.mediaRevision += 1
            model.refreshChanges()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    func delete() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \((item.path as NSString).lastPathComponent)?")
        alert.informativeText = item.usedBy.isEmpty
            ? String(localized: "Nothing links to it.")
            : String(localized: "It is used in \(item.usedBy.count) places, which will show a broken image.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let url else { return }
        try? FileManager.default.removeItem(at: url)
        model.selectedMedia = nil
        model.mediaRevision += 1
        model.refreshChanges()
    }
}
