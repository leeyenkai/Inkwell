import InkwellKit
import SwiftUI

/// Short guides, kept in the app so they work offline and match this version.
struct HelpWindow: View {
    @Binding var topic: HelpTopic

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: Binding(get: { topic }, set: { if let t = $0 { topic = t } })) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(topic.title).font(.largeTitle.weight(.semibold))
                    if topic == .shortcuts {
                        ShortcutList()
                    } else {
                        ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(.init(paragraph)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
    case start, writing, images, publishing, design, health, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: String(localized: "Getting started")
        case .writing: String(localized: "Writing")
        case .images: String(localized: "Pictures and photos")
        case .publishing: String(localized: "Publishing")
        case .design: String(localized: "Design")
        case .health: String(localized: "Site health")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .start: "flag"
        case .writing: "square.and.pencil"
        case .images: "photo"
        case .publishing: "paperplane"
        case .design: "paintpalette"
        case .health: "stethoscope"
        case .shortcuts: "keyboard"
        }
    }

    var paragraphs: [String] {
        switch self {
        case .start: [
            String(localized: """
                Inkwell edits a GitHub Pages site. Sign in with GitHub, pick the site’s repository, and Inkwell keeps a copy on this \
                Mac. You do not need git, Terminal or a folder of your own.
                """),
            String(localized: """
                The sidebar lists the site’s sections, found from its menu and collections. Pick one to see its posts, or press **⌘N** \
                for a new post.
                """),
            String(localized: "Everything you write is saved as you go. Nothing reaches your site until you publish it."),
        ]
        case .writing: [
            String(localized: """
                Posts are plain Markdown. Inkwell styles it as you type and hides the markers away from the line you are on; turn that \
                off with **View › Hide Markdown Syntax**.
                """),
            String(localized: """
                Type **/** at the start of a line for headings, lists, tables, images, links and embeds. Type **[[** to link to another \
                post by its title.
                """),
            String(localized: """
                **Properties** above the text hold the title, date and the section’s other fields. A date in the future schedules the \
                post. **Search and sharing** sets the description and picture used in search results and link previews.
                """),
            String(localized: "Tables open as a grid with **Format › Table…** (⇧⌘T) or the Edit Table button beside them."),
        ]
        case .images: [
            String(localized: """
                Drop, paste or add a picture (**⇧⌘I**). Inkwell resizes it, turns it upright, removes location and camera data, and \
                names it after the post. Several at once become a gallery.
                """),
            String(localized: """
                **Photos** keeps a photo stream: one small file per photo, each with a caption. **Media** lists every image in the site, \
                where it is used, and which ones nothing uses.
                """),
        ]
        case .publishing: [
            String(localized: """
                **Publish** (⇧⌘P) checks the post, then sends it and its new pictures to GitHub as one change. Inkwell shows when GitHub \
                Pages has the new version live.
                """),
            String(localized: """
                Edits to published posts, design changes and fixes wait in **Unpublished changes** at the bottom of the sidebar until \
                you publish them.
                """),
            String(localized: """
                Inkwell checks GitHub for changes made elsewhere. If the same file changed in both places, you choose which version to \
                keep.
                """),
            String(localized: "**Version History…** shows earlier versions of a post, and can bring one back."),
        ]
        case .design: [
            String(localized: """
                **Theme & Style** switches between Inkwell’s themes and edits colours, fonts and layout. **Navigation** edits the menu; \
                **Settings** the site’s title, description, favicon, share image and custom domain.
                """),
            String(localized: """
                **Code** opens layouts, includes and stylesheets for anything the panels do not cover. The preview follows every \
                change.
                """),
        ]
        case .health: [
            String(localized: """
                **Health** looks over the whole site: properties that will not build, two files at one address, links and images that go \
                nowhere, missing alt text, large files, and the basics search engines and link previews need.
                """),
            String(localized: """
                Where a fix is safe, **Fix** makes it as an unpublished change, so you can look before it goes live. Inkwell never adds \
                a feed, sitemap or tag the site already has.
                """),
            String(localized: "**Check Links** asks each site your posts link to whether the page is still there."),
        ]
        case .shortcuts: []
        }
    }
}

struct ShortcutList: View {
    static let groups: [(String, [(String, String)])] = [
        (String(localized: "Posts"), [
            ("⌘N", String(localized: "New post")),
            ("⇧⌘N", String(localized: "New page")),
            ("⇧⌘P", String(localized: "Publish")),
            ("⌥⇧⌘P", String(localized: "Review unpublished changes")),
            ("⌘R", String(localized: "Check GitHub for changes")),
            ("⌘O", String(localized: "Switch site")),
        ]),
        (String(localized: "View"), [
            ("⌥⌘P", String(localized: "Preview")),
            ("⇧⌘E", String(localized: "Source")),
            ("⌥⌘H", String(localized: "Hide Markdown syntax")),
            ("⌥⌘I", String(localized: "Properties")),
        ]),
        (String(localized: "Format"), [
            ("⌘B", String(localized: "Bold")),
            ("⌘I", String(localized: "Italic")),
            ("⌘U", String(localized: "Underline")),
            ("⇧⌘X", String(localized: "Strikethrough")),
            ("⇧⌘H", String(localized: "Highlight")),
            ("⌘E", String(localized: "Inline code")),
            ("⌘K", String(localized: "Link")),
            ("⌘1–⌘4", String(localized: "Headings")),
            ("⌘0", String(localized: "Body text")),
            ("⌘'", String(localized: "Quote")),
            ("⇧⌘L", String(localized: "Bulleted list")),
            ("⌥⌘L", String(localized: "Checklist")),
            ("⇧⌘F", String(localized: "Footnote")),
            ("⇧⌘↩", String(localized: "Section break")),
            ("⇧⌘I", String(localized: "Add image")),
            ("⇧⌘T", String(localized: "Table")),
        ]),
        (String(localized: "Typing"), [
            ("/", String(localized: "Insert a block (at the start of a line)")),
            ("[[", String(localized: "Link to a post")),
            (String(localized: "Tab / ⇧Tab"), String(localized: "Nest or un-nest a list item")),
            (String(localized: "Return"), String(localized: "Continue a list; on an empty item, end it")),
        ]),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(Self.groups, id: \.0) { group in
                GridRow { Text(group.0).font(.headline).padding(.top, 10).gridCellColumns(2) }
                ForEach(group.1, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.body.monospaced()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(action)
                    }
                }
            }
        }
    }
}

/// Shown the first time a site is opened: what Inkwell found and where to start.
struct SiteSummarySheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var imageCount = 0

    var body: some View {
        if let site = model.site {
            let sections = site.sections.filter { $0.collectionName != nil }
            let posts = site.documents.filter { !$0.isPage }.count
            VStack(alignment: .leading, spacing: 16) {
                Text("\(site.name) is ready").font(.title.weight(.semibold))
                Text(summary(site, sections: sections, posts: posts)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    step("square.and.pencil", "Write a post", "Press ⌘N. It stays a draft on this Mac until you publish.")
                    step("paintpalette", "Make it yours", "Theme & Style changes colours, fonts and layout, with a preview.")
                    step("stethoscope", "Check its health", model.healthProblems == 0
                        ? "Health watches for broken links, missing pictures and more."
                        : "Health found \(model.healthProblems) things worth a look.")
                }
                HStack {
                    Button("Open Health") {
                        model.sidebarSelection = .health
                        dismiss()
                    }
                    Spacer()
                    Button("Look Around") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Write a Post") {
                        dismiss()
                        model.newPost()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
            .frame(width: 520)
            .task {
                let root = site.root
                imageCount = await Task.detached { MediaLibrary.scan(siteRoot: root).count }.value
            }
        }
    }

    func summary(_ site: Site, sections: [SiteSection], posts: Int) -> String {
        let names = sections.map(\.label)
        let list = names.formatted(.list(type: .and))
        let found = names.isEmpty
            ? String(localized: "Inkwell found a \(site.generator) site.")
            : String(localized: "Inkwell found a \(site.generator) site with \(names.count) sections: \(list).")
        var counts = [String(localized: "\(posts) posts")]
        if imageCount > 0 { counts.append(String(localized: "\(imageCount) images")) }
        counts.append(String(localized: "\(site.documents.filter(\.isPage).count) pages"))
        return found + " " + String(localized: "It has \(counts.formatted(.list(type: .and))).")
    }

    func step(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
