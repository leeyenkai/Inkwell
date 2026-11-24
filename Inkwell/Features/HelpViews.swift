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
        case .start: "Getting started"
        case .writing: "Writing"
        case .images: "Pictures and photos"
        case .publishing: "Publishing"
        case .design: "Design"
        case .health: "Site health"
        case .shortcuts: "Keyboard shortcuts"
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
            "Inkwell edits a GitHub Pages site. Sign in with GitHub, pick the site’s repository, and Inkwell keeps a copy on this "
                + "Mac. You do not need git, Terminal or a folder of your own.",
            "The sidebar lists the site’s sections, found from its menu and collections. Pick one to see its posts, or press **⌘N** "
                + "for a new post.",
            "Everything you write is saved as you go. Nothing reaches your site until you publish it.",
        ]
        case .writing: [
            "Posts are plain Markdown. Inkwell styles it as you type and hides the markers away from the line you are on; turn that "
                + "off with **View › Hide Markdown Syntax**.",
            "Type **/** at the start of a line for headings, lists, tables, images, links and embeds. Type **[[** to link to another "
                + "post by its title.",
            "**Properties** above the text hold the title, date and the section’s other fields. A date in the future schedules the "
                + "post. **Search and sharing** sets the description and picture used in search results and link previews.",
            "Tables open as a grid with **Format › Table…** (⇧⌘T) or the Edit Table button beside them.",
        ]
        case .images: [
            "Drop, paste or add a picture (**⇧⌘I**). Inkwell resizes it, turns it upright, removes location and camera data, and "
                + "names it after the post. Several at once become a gallery.",
            "**Photos** keeps a photo stream: one small file per photo, each with a caption. **Media** lists every image in the site,"
                + " where it is used, and which ones nothing uses.",
        ]
        case .publishing: [
            "**Publish** (⇧⌘P) checks the post, then sends it and its new pictures to GitHub as one change. Inkwell shows when GitHub"
                + " Pages has the new version live.",
            "Edits to published posts, design changes and fixes wait in **Unpublished changes** at the bottom of the sidebar until "
                + "you publish them.",
            "Inkwell checks GitHub for changes made elsewhere. If the same file changed in both places, you choose which version to keep.",
            "**Version History…** shows earlier versions of a post, and can bring one back.",
        ]
        case .design: [
            "**Theme & Style** switches between Inkwell’s themes and edits colours, fonts and layout. **Navigation** edits the menu; "
                + "**Settings** the site’s title, description, favicon, share image and custom domain.",
            "**Code** opens layouts, includes and stylesheets for anything the panels do not cover. The preview follows every change.",
        ]
        case .health: [
            "**Health** looks over the whole site: properties that will not build, two files at one address, links and images that go"
                + " nowhere, missing alt text, large files, and the basics search engines and link previews need.",
            "Where a fix is safe, **Fix** makes it as an unpublished change, so you can look before it goes live. Inkwell never adds "
                + "a feed, sitemap or tag the site already has.",
            "**Check Links** asks each site your posts link to whether the page is still there.",
        ]
        case .shortcuts: []
        }
    }
}

struct ShortcutList: View {
    static let groups: [(String, [(String, String)])] = [
        ("Posts", [("⌘N", "New post"), ("⇧⌘N", "New page"), ("⇧⌘P", "Publish"), ("⌥⇧⌘P", "Review unpublished changes"), ("⌘R", "Check GitHub for changes"),
                   ("⌘O", "Switch site")]),
        ("View", [("⌥⌘P", "Preview"), ("⇧⌘E", "Source"), ("⌥⌘H", "Hide Markdown syntax"), ("⌥⌘I", "Properties")]),
        ("Format", [("⌘B", "Bold"), ("⌘I", "Italic"), ("⌘U", "Underline"), ("⇧⌘X", "Strikethrough"), ("⇧⌘H", "Highlight"), ("⌘E", "Inline code"),
                    ("⌘K", "Link"), ("⌘1–⌘4", "Headings"), ("⌘0", "Body text"), ("⌘'", "Quote"), ("⇧⌘L", "Bulleted list"), ("⌥⌘L", "Checklist"),
                    ("⇧⌘F", "Footnote"), ("⇧⌘↩", "Section break"), ("⇧⌘I", "Add image"), ("⇧⌘T", "Table")]),
        ("Typing", [("/", "Insert a block (at the start of a line)"), ("[[", "Link to a post"), ("Tab / ⇧Tab", "Nest or un-nest a list item"),
                    ("Return", "Continue a list; on an empty item, end it")]),
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
                        : "Health found \(SiteHealth.plural(model.healthProblems, "thing")) worth a look.")
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
        let list = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        let images = imageCount == 0 ? "" : ", \(SiteHealth.plural(imageCount, "image"))"
        var text = "Inkwell found a \(site.generator) site with \(SiteHealth.plural(sections.count, "section"))"
        if !names.isEmpty { text += " (\(list))" }
        text += ", \(SiteHealth.plural(posts, "post"))\(images) and \(SiteHealth.plural(site.documents.filter(\.isPage).count, "page"))."
        return text
    }

    func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
