import AppKit
import InkwellKit
import SwiftUI

@main
struct InkwellApp: App {
    @State private var model = AppModel()

    init() {
        Prefs.register()
    }

    var body: some Scene {
        WindowGroup("Inkwell") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await Launch.start(model) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.appBecameActive()
                }
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Post") { model.newPost() }
                    .keyboardShortcut("n")
                    .disabled(model.site == nil)
                Button("New Page…") { model.showNewPage = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.site == nil)
                Button("Switch Site…") { model.closeSite() }
                    .keyboardShortcut("o")
                    .disabled(model.site == nil)
            }
            CommandGroup(after: .saveItem) {
                Button(model.publishMenuTitle) { model.beginPublish() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canPublish)
                Button("Review Unpublished Changes…") { model.showChanges = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                    .disabled(model.site == nil)
                Button("Check GitHub for Changes") { Task { await model.sync() } }
                    .keyboardShortcut("r")
                    .disabled(model.site == nil)
                Divider()
                Button("Rename or Move…") { model.moveRequest = model.editor?.document }
                    .disabled(model.editor == nil)
                Button("Version History…") { model.historyRequest = model.editor?.document }
                    .disabled(model.editor?.document.origin != .repository)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Preview", isOn: $model.showPreview)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Toggle("Source", isOn: $model.showSource)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Hide Markdown Syntax", isOn: $model.hideSyntax)
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Toggle("Properties", isOn: $model.showProperties)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                EditorViewCommands(model: model)
                Divider()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesItem(updates: model.updates)
            }
            CommandGroup(after: .textEditing) {
                EditorFindCommands(model: model)
            }
            FormatCommands(model: model)
            CommandGroup(replacing: .help) {
                HelpMenuItems(model: model)
            }
        }
        Settings {
            SettingsWindow(model: model)
        }
        Window("Inkwell Help", id: "help") {
            HelpWindow(topic: $model.helpTopic)
        }
        .defaultSize(width: 860, height: 600)
        Window("Software Update", id: "update") {
            UpdateView(updates: model.updates)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// A view, so it can open the Help window.
struct HelpMenuItems: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Inkwell Help") {
            model.helpTopic = .start
            openWindow(id: "help")
        }
        .keyboardShortcut("?")
        Button("Keyboard Shortcuts") {
            model.helpTopic = .shortcuts
            openWindow(id: "help")
        }
        .keyboardShortcut("/", modifiers: [.command, .option])
        Divider()
        Button("Copy Diagnostics") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Diagnostics.report(model), forType: .string)
        }
        Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL]) }
            .disabled(!FileManager.default.fileExists(atPath: Diagnostics.logURL.path))
    }
}

struct FormatCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { model.textView?.toggle("**") }.keyboardShortcut("b")
            Button("Italic") { model.textView?.toggle("*") }.keyboardShortcut("i")
            Button("Underline") { model.textView?.toggle("<u>", "</u>") }.keyboardShortcut("u")
            Button("Strikethrough") { model.textView?.toggle("~~") }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { model.textView?.toggle("<mark>", "</mark>") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { model.textView?.toggle("`") }.keyboardShortcut("e")
            Button("Superscript") { model.textView?.toggle("<sup>", "</sup>") }
            Button("Subscript") { model.textView?.toggle("<sub>", "</sub>") }
            Button("Clear Formatting") { model.textView?.clearFormatting() }
            Divider()
            Button("Link…") { model.textView?.showLinkPopover() }.keyboardShortcut("k")
            Divider()
            Button("Heading 1") { model.textView?.heading(1) }.keyboardShortcut("1")
            Button("Heading 2") { model.textView?.heading(2) }.keyboardShortcut("2")
            Button("Heading 3") { model.textView?.heading(3) }.keyboardShortcut("3")
            Button("Heading 4") { model.textView?.heading(4) }.keyboardShortcut("4")
            Button("Body Text") { model.textView?.heading(0) }.keyboardShortcut("0")
            Button("Code Block") { model.textView?.setTextStyle(.monospaced) }
            Divider()
            Button("Quote") { model.textView?.prefixLines("> ") }.keyboardShortcut("'", modifiers: [.command])
            Button("Bulleted List") { model.textView?.setList(.bullets) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Numbered List") { model.textView?.setList(.numbers) }
            Button("Checklist") { model.textView?.setList(.checklist) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Footnote") { model.textView?.footnote() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Section Break") { model.textView?.divider() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Indent") { model.textView?.indentLines(outdent: false) }.keyboardShortcut("]")
            Button("Outdent") { model.textView?.indentLines(outdent: true) }.keyboardShortcut("[")
            Button("Move Line Up") { model.textView?.moveLines(up: true) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Line Down") { model.textView?.moveLines(up: false) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("Add Image…") { addImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Table…") { model.textView?.editTable() }.keyboardShortcut("t", modifiers: [.command, .shift])
                .help("Edit the table the cursor is in as a grid, or insert a new one")
            Divider()
            Button("Insert Element…") { model.showElementPicker = true }.keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.editor == nil)
            Button("Edit Element…") { model.editElement() }.keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(model.editor == nil)
        }
    }

    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose an image. It is resized, cleaned of location data and copied into the site.")
        guard model.editor != nil, panel.runModal() == .OK, let url = panel.url else { return }
        model.importImages([url], at: model.textView?.selectedRange().location ?? 0)
    }
}

/// Launch arguments: `--fresh` (do not reopen the last site), `--pane design|navigation|settings|code` (`--code-file <path>`,
/// `--theme-file`), `--apply-theme <id>`, `--site <folder>`,
/// `--open <path in site>`, `--section <id>`, `--preview`,
/// `--source`, `--publish-sheet`, `--table-cursor` (cursor in the first table), `--edit-table` (and open the grid),
/// `--new-draft <title>` with optional `--draft-body <file>`, `--select <text>` (select it in the post), `--link-popover <text>`
/// (and open the link popover over it), and `--selftest-publish` (needs a site whose remote is not GitHub).
/// `--render-theme-previews <folder>` draws each theme's gallery pictures into `<folder>/<theme id>/` and quits.
enum Launch {
    static var started = false

    static func start(_ model: AppModel) async {
        guard !started else { return }
        started = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains(where: { $0.hasPrefix("--selftest") || $0 == "--measure-typing" }) { setvbuf(stdout, nil, _IONBF, 0) }
        if let folder = value("--render-theme-previews") {
            setvbuf(stdout, nil, _IONBF, 0)
            let ok = await ThemePreviewRenderer.renderAll(into: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath), arguments: args)
            exit(ok ? 0 : 1)
        }
        if let path = value("--site") {
            model.suppressSiteSummary = !args.contains("--summary")
            await model.account.restore()
            await model.openFolder(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else if args.contains("--fresh") {
            await model.account.restore()
        } else {
            await model.start()
        }
        if args.contains("--selftest-publish") {
            let ok = await SelfTest.publish(model)
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
        if let section = value("--section") { model.sidebarSelection = .section(section) }
        if let photo = value("--photo") {
            // Several photos, comma-separated, are chosen together.
            let paths = photo.split(separator: ",").map(String.init)
            let ids = model.photos.filter { paths.contains($0.doc.relativePath) }.map(\.id)
            model.selectedPhotoIDs = Set(ids)
            model.selectedPhotoID = ids.first
        }
        if let album = value("--album") { model.albumFilter = album == "none" ? .none : .album(album) }
        if let id = value("--apply-theme"), let theme = ThemeManifest.named(id), let design = model.design {
            design.apply(design.plan(for: theme))
        }
        if args.contains("--measure-typing") {
            await SelfTest.measureTyping(model)
            exit(0)
        }
        if args.contains("--selftest-content") {
            let ok = await SelfTest.content(model)
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
        if args.contains("--selftest-design") {
            let ok = await SelfTest.design(model)
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
        if args.contains("--theme-gallery") { model.showThemeGallery = true }
        switch value("--pane") {
        case "design": model.sidebarSelection = .design
        case "navigation": model.sidebarSelection = .navigation
        case "settings": model.sidebarSelection = .settings
        case "health":
            model.sidebarSelection = .health
            model.selectedIssueID = value("--issue")
        case "media":
            model.sidebarSelection = .media
            model.selectedMedia = value("--media-file")
        case "code":
            model.sidebarSelection = .code
            if let path = value("--code-file") { model.codeFile = CodeFile(path: path, inTheme: args.contains("--theme-file")) }
        default: break
        }
        if let title = value("--new-draft") {
            model.newPost()
            model.editor?.title = title
            if let bodyPath = value("--draft-body"), let body = try? String(contentsOfFile: bodyPath, encoding: .utf8) {
                model.editor?.body = body
                model.editor?.reloadFromView()
            }
            model.editor?.saveNow()
        }
        if let path = value("--open"), let doc = model.allDocuments.first(where: { $0.relativePath == path }) {
            if case .section = model.sidebarSelection, model.site?.section(doc.sectionID) != nil { model.sidebarSelection = .section(doc.sectionID) }
            model.select(doc.id)
        }
        if let text = value("--link-popover") ?? value("--select") {
            // Selects the first occurrence of the text in the post, and opens the link popover over it.
            try? await Task.sleep(for: .milliseconds(900))
            if let textView = model.textView {
                NSApp.activate()
                let found = (textView.string as NSString).range(of: text)
                textView.window?.makeFirstResponder(textView)
                if found.location != NSNotFound { textView.setSelectedRange(found) }
                if args.contains("--link-popover") { textView.showLinkPopover() }
            }
        }
        if args.contains("--preview") { model.showPreview = true }
        if args.contains("--source") { model.showSource = true }
        if args.contains("--publish-sheet") {
            try? await Task.sleep(for: .milliseconds(600))
            model.refreshChanges()
            try? await Task.sleep(for: .milliseconds(600))
            model.beginPublish()
        }
        if let name = value("--new-page"), let template = PageTemplate(rawValue: name) {
            model.createPage(title: template.suggestedTitle.isEmpty ? template.title : template.suggestedTitle, template: template, addToMenu: false)
        }
        if args.contains("--element-picker") { model.showElementPicker = true }
        if args.contains("--edit-element") {
            try? await Task.sleep(for: .milliseconds(800))
            if let span = model.textView.flatMap({ PageElements.find(in: $0.string).first(where: { $0.innerRange != nil }) }) {
                model.textView?.setSelectedRange(NSRange(location: span.openRange.location, length: 0))
                model.editElement()
            }
        }
        if args.contains("--settings") { model.settingsRequested = true }
        if let feed = value("--update-feed") { model.updates.feedOverride = URL(string: feed) }
        if args.contains("--check-updates") {
            model.updates.windowRequested = true
            await model.updates.check(userInitiated: true)
        } else if !args.contains(where: { $0.hasPrefix("--selftest") || $0 == "--measure-typing" }) {
            Task {
                try? await Task.sleep(for: .seconds(5))
                await model.updates.checkAutomatically()
            }
        }
        if let topic = value("--help").flatMap(HelpTopic.init(rawValue:)) {
            model.helpTopic = topic
            model.helpRequested = true
        }
        if args.contains("--edit-table") || args.contains("--table-cursor") {
            try? await Task.sleep(for: .milliseconds(800))
            if let textView = model.textView {
                let at = (textView.string as NSString).range(of: "\n|").location
                if at != NSNotFound { textView.setSelectedRange(NSRange(location: at + 2, length: 0)) }
                if args.contains("--edit-table") {
                    // In a window of its own rather than a sheet, so a window capture can see it.
                    textView.editTable()
                    if let edit = model.tableEdit {
                        model.tableEdit = nil
                        let window = NSWindow(contentViewController: NSHostingController(rootView: TableEditorSheet(model: model, edit: edit)))
                        window.title = String(localized: "Table")
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }
}

enum SelfTest {
    /// Times typing into a long post: each character is a keystroke through the text view, with its restyle.
    static func measureTyping(_ model: AppModel) async {
        model.newPost()
        guard let editor = model.editor else { return }
        let paragraph = "A *long* post with **bold**, `code`, [links](/x/), ~~strike~~ and more words in every paragraph.\n\n"
        for chars in [15000, 60000, 150_000] {
            editor.body = String(repeating: paragraph, count: chars / paragraph.count)
            editor.reloadFromView()
            try? await Task.sleep(for: .seconds(1.5))
            guard let textView = model.textView else { return }
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length / 2, length: 0))
            let start = Date()
            for ch in "typing here" { textView.insertText(String(ch), replacementRange: textView.selectedRange()) }
            let each = Date().timeIntervalSince(start) / 11 * 1000
            print("typing: \(chars / 1000)k characters, \(String(format: "%.1f", each)) ms per keystroke")
        }
    }

    /// Rename with a redirect and publish, history, duplicate, new page, tag rename. Refuses GitHub remotes.
    static func content(_ model: AppModel) async -> Bool {
        guard let site = model.site, let git = Git(root: site.root), let backend = model.backend else { return false }
        if let remote = await git.remoteURL(), remote.contains("github.com") { return false }
        func check(_ ok: Bool, _ what: String) -> Bool {
            print("content selftest: \(ok ? "ok" : "FAILED") \(what)")
            return ok
        }
        func settle() async {
            try? await Task.sleep(for: .seconds(1.5))
        }
        var ok = true
        let root = site.root

        // Rename and move with a redirect, then publish it.
        guard let post = site.documents.first(where: { $0.relativePath == "_notes/2026-06-20-morality.md" }) else { return false }
        model.applyMove(post, title: post.title, slug: "politics-of-morality", sectionID: post.sectionID, keepOldAddress: true)
        let moved = "_notes/2026-06-20-politics-of-morality.md"
        let movedText = (try? String(contentsOf: root.appending(path: moved), encoding: .utf8)) ?? ""
        ok = check(!FileManager.default.fileExists(atPath: post.fileURL.path) && movedText.contains("redirect_from: [/notes/morality/]"),
                   "file moved with redirect_from") && ok
        let config = (try? String(contentsOf: root.appending(path: "_config.yml"), encoding: .utf8)) ?? ""
        ok = check(config.contains("- jekyll-redirect-from"), "redirect plugin listed") && ok
        if let session = model.publishSheet {
            await session.run()
            let files = Set((try? await git.run(["show", "--name-only", "--no-renames", "--format=", "HEAD"]))?.split(separator: "\n").map(String.init) ?? [])
            ok = check(session.phase == .pushed && files.isSuperset(of: [moved, "_notes/2026-06-20-morality.md", "_config.yml"]),
                       "move published as one commit (\(files.count) files, \(session.phase))") && ok
            model.publishSheet = nil
        } else {
            ok = check(false, "move offered a publish") && ok
        }
        await settle()

        // History of the moved post.
        let history = (try? await backend.history(of: moved)) ?? []
        let first = history.first.map(\.id) ?? ""
        let then = (try? await backend.contents(of: moved, at: first)) ?? nil
        ok = check(!history.isEmpty && then?.contains("redirect_from") == true, "history has the published version (\(history.count))") && ok

        // Duplicate a sidenote into a draft.
        if let note = model.site?.documents.first(where: { $0.relativePath.hasPrefix("_sidenotes/") }) {
            model.duplicate(note)
            ok = check(model.drafts.contains { $0.title.hasPrefix("Copy of") }, "duplicate became a draft") && ok
        }

        // A new page, added to the menu.
        model.createPage(title: "Now", addToMenu: true)
        await settle()
        let nav = (try? String(contentsOf: root.appending(path: "_data/navigation.yml"), encoding: .utf8)) ?? ""
        ok = check(FileManager.default.fileExists(atPath: root.appending(path: "now.md").path) && nav.contains("/now"), "page created and in menu") && ok

        // Tags: tag two posts, then rename the tag everywhere.
        for path in [moved, "_notes/2025-12-01-estonia.md"] {
            let url = root.appending(path: path)
            guard var doc = (try? String(contentsOf: url, encoding: .utf8)).map(FrontMatterDocument.init) else { continue }
            doc.set("tags", raw: YAMLFormat.list(["ethics", "europe"]))
            try? Data(doc.text.utf8).write(to: url)
        }
        model.reloadSite()
        await settle()
        ok = check(model.documents(tagged: "ethics").count == 2, "tag index sees both posts") && ok
        model.renameTag("ethics", to: "morality")
        await settle()
        let renamed = (try? String(contentsOf: root.appending(path: "_notes/2025-12-01-estonia.md"), encoding: .utf8)) ?? ""
        ok = check(renamed.contains("tags: [morality, europe]") && model.documents(tagged: "morality").count == 2, "tag renamed everywhere") && ok

        // Photos: set up the stream, add a photo with a caption, and see it on the photos page and in the media library.
        let plan = model.setUpPhotos()
        model.applyPhotoSetup(plan)
        await settle()
        ok = check(model.photosSetUp && model.sidebarSelection == .section("photos"), "photos set up (\(plan.count) changes)") && ok
        let source = FileManager.default.temporaryDirectory.appending(path: "inkwell-selftest-photo.jpg")
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.copyItem(at: root.appending(path: "assets/images/estonia.jpg"), to: source)
        model.importPhotos([source])
        for _ in 0..<20 where model.pendingPhotos == nil { try? await Task.sleep(for: .milliseconds(250)) }
        if var pending = model.pendingPhotos, !pending.isEmpty {
            pending[0].caption = "Self-test snow"
            pending[0].alt = "A snowy street"
            model.savePendingPhotos(pending)
            await settle()
            let photo = model.photos.first { $0.caption == "Self-test snow" }
            ok = check(photo != nil && photo?.image.hasPrefix("/assets/photos/") == true, "photo file written") && ok
            let page = model.previewBuilder?.page(at: "/photos/")?.html ?? ""
            ok = check(page.contains("Self-test snow") && page.contains("photo-item"), "photos page lists it") && ok
            let media = MediaLibrary.scan(siteRoot: root)
            let used = media.first { "/" + $0.path == photo?.image }?.usedBy ?? []
            ok = check(used.contains { $0.hasPrefix("_photos/") }, "media library sees where it is used") && ok
        } else {
            ok = check(false, "photo imported") && ok
        }

        // Albums: a second photo, then an album holding both. Its page shows them, the photos page lists it, and one publish
        // carries the album's page and list, the photo files, their pictures and the site files albums need.
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.copyItem(at: root.appending(path: "assets/images/estonia.jpg"), to: source)
        model.importPhotos([source])
        for _ in 0..<20 where model.pendingPhotos == nil { try? await Task.sleep(for: .milliseconds(250)) }
        if var pending = model.pendingPhotos, !pending.isEmpty {
            pending[0].caption = "Self-test harbour"
            model.savePendingPhotos(pending)
            await settle()
        }
        let pair = model.photos.filter { $0.caption.hasPrefix("Self-test ") }
        let albumID = model.createAlbum(title: "Self-test album", description: "Two photos", adding: pair.map(\.doc.relativePath)) ?? ""
        await settle()
        let album = model.albums.first { $0.id == albumID }
        let members = model.photos.filter { $0.albums.contains(albumID) }
        ok = check(album != nil && pair.count == 2 && members.count == 2 && model.albumFilter == .album(albumID),
                   "album created with two photos (\(members.count))") && ok
        let albumPage = album.flatMap(model.albumPreview)?.html ?? ""
        let showsBoth = pair.allSatisfy { albumPage.contains($0.image) } && albumPage.contains("inkwell-lightbox")
        ok = check(showsBoth && albumPage.contains("Self-test album"), "album page shows both photos") && ok
        let listed = model.previewBuilder?.page(at: "/photos/")?.html.contains("/albums/\(albumID)/") == true
        ok = check(listed, "photos page lists the album") && ok
        let kit = Albums.kitFiles + [ElementKit.stylesheet, ElementKit.script]
        let required = Set([Albums.dataPath, Albums.pagePath(albumID)] + pair.map(\.doc.relativePath) + kit)
        let setup = ["_config.yml", "photos.md", "_layouts/default.html", "_includes/head.html", "_includes/head-custom.html"]
        let pictures = pair.map { String($0.image.drop { $0 == "/" }) }
        let paths = Array(required) + (setup + pictures).filter { model.changes[$0] != nil }
        let session = PublishSession.changes(paths: paths, message: "Self-test album", backend: backend, model: model)
        await session.run()
        let shown = (try? await git.run(["show", "--name-only", "--format=", "HEAD"])) ?? ""
        let published = Set(shown.split(separator: "\n").map(String.init))
        ok = check(session.phase == .pushed && published.isSuperset(of: required) && published.isSuperset(of: pictures),
                   "album published as one commit (\(published.count) files, \(session.phase))") && ok
        await settle()

        // Scheduling: a post dated tomorrow publishes as "Schedule", with the hourly workflow in the same commit.
        model.sidebarSelection = .section("notes")
        model.newPost()
        if let editor = model.editor {
            editor.title = "Self-test scheduled post"
            editor.body = "\nGoes live tomorrow.\n"
            editor.setDate("date", Date().addingTimeInterval(86400), withTime: true)
            editor.saveNow()
            await settle()
            model.refreshChanges()
            await settle()
            model.beginPublish()
            if let session = model.publishSheet {
                let schedules = session.actionTitle == String(localized: "Schedule") && session.addScheduleWorkflow == true
                ok = check(schedules, "publish offers to schedule") && ok
                await session.run()
                let files = (try? await git.run(["show", "--name-only", "--format=", "HEAD"]))?.split(separator: "\n").map(String.init) ?? []
                ok = check(files.contains(Schedule.workflowPath) && files.count == 2, "post and workflow in one commit (\(files))") && ok
                model.publishSheet = nil
                await settle()
                let post = model.site?.documents.first { $0.title == "Self-test scheduled post" }
                ok = check(post.map { model.status(of: $0) } == .scheduled, "post shows as scheduled") && ok
            } else {
                ok = check(false, "scheduled post offered a publish") && ok
            }
        }

        // Editor: a picture on its own line shows inline, and a table edited as a grid goes back in one undo step.
        model.newPost()
        if let editor = model.editor {
            editor.title = "Self-test table"
            editor.body = "\n![Snow](/assets/images/estonia.jpg)\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\nAfter.\n"
            editor.reloadFromView()
            await settle()
        }
        if let textView = model.textView, textView.string.contains("| 1 | 2 |") {
            ok = check(textView.inlineImageCount == 1, "image shown inline") && ok
            let before = textView.string
            textView.setSelectedRange(NSRange(location: (before as NSString).range(of: "| 1").location + 2, length: 0))
            textView.editTable()
            if var table = model.tableEdit?.table {
                table.rows.append(["3", "Tallinn"])
                model.finishTableEdit(table)
                let expected = "| a   |    b    |\n| --- | :-----: |\n| 1   |    2    |\n| 3   | Tallinn |\n\nAfter."
                ok = check(textView.string.contains(expected), "table written back aligned") && ok
                textView.undoManager?.undo()
                ok = check(textView.string == before, "one undo restores the table") && ok
            } else {
                ok = check(false, "table found under the cursor") && ok
            }
        } else {
            ok = check(false, "table draft in the editor") && ok
        }

        // Typing in a long post restyles only the edited paragraph; the result must match a full restyle.
        model.newPost()
        if let editor = model.editor {
            let paragraph = "Some **bold** and *italic* text with {{ site.title }} and [a link](/notes/).\n\n"
            editor.title = "Self-test long post"
            editor.body = String(repeating: paragraph, count: 40) + "| a | b |\n|---|---|\n| 1 | 2 |\n\n![Snow](/assets/images/estonia.jpg)\n\n"
                + String(repeating: paragraph, count: 40)
            editor.reloadFromView()
            await settle()
        }
        if let textView = model.textView, let storage = textView.textStorage, storage.length > InkwellTextView.incrementalLength {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).range(of: "italic").location + 2, length: 0))
            for ch in "ab **c**" { textView.insertText(String(ch), replacementRange: textView.selectedRange()) }
            textView.insertText("\n\nNew *line*", replacementRange: textView.selectedRange())
            let quick = NSAttributedString(attributedString: storage)
            let quickChips = textView.chipRanges
            textView.restyle()
            ok = check(quick.isEqual(to: storage) && quickChips == textView.chipRanges, "quick restyle matches a full one") && ok
        } else {
            ok = check(false, "long post in the editor") && ok
        }

        // Editor: a link made the way the link popover makes it, a checklist tick and a renumbered list, each one undo step.
        model.newPost()
        if let editor = model.editor {
            editor.title = "Self-test links"
            editor.body = "\nRead about Estonia today.\n\n- [ ] milk\n\n1. one\n2. two\n"
            editor.reloadFromView()
            await settle()
        }
        if let textView = model.textView, textView.string.contains("Estonia today") {
            let before = textView.string as NSString
            let entry = LinkSearch.results(query: "estonia", entries: model.linkEntries, headings: []).first
            textView.applyLink(url: entry?.url ?? "", title: entry?.title ?? "", selection: before.range(of: "Estonia"))
            ok = check(entry?.url == "/notes/estonia/" && textView.string.contains("[Estonia](/notes/estonia/) today"),
                       "link from the popover's search") && ok
            ok = check(model.document(forLink: "/notes/estonia")?.relativePath == "_notes/2025-12-01-estonia.md",
                       "link leads to its post") && ok
            textView.undoManager?.undo()
            ok = check(textView.string == before as String, "one undo removes the link") && ok
            textView.toggleCheckbox(atLine: before.range(of: "milk").location)
            ok = check(textView.string.contains("- [x] milk"), "checklist ticked") && ok
            textView.undoManager?.undo()
            ok = check(textView.string == before as String, "one undo unticks it") && ok
            textView.setSelectedRange(NSRange(location: NSMaxRange(before.range(of: "1. one")), length: 0))
            textView.insertNewline(nil)
            ok = check(textView.string.contains("1. one\n2. \n3. two"), "Return renumbers the list") && ok
            // Clicks go through the same hit test as the mouse: the box ticks, and ⌘-click on a link opens its post.
            func click(_ range: NSRange, _ flags: NSEvent.ModifierFlags = []) -> Bool {
                let rect = textView.rect(for: range)
                let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
                                                     windowNumber: textView.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1) else { return false }
                return textView.handleClick(event)
            }
            let box = EditorCommands.checkbox(in: textView.string, line: (textView.string as NSString).range(of: "milk").location)
            ok = check(click(box ?? NSRange()) && textView.string.contains("- [x] milk"), "clicking the box ticks it") && ok
            textView.applyLink(url: "/notes/estonia/", title: "", selection: (textView.string as NSString).range(of: "Estonia"))
            ok = check(click((textView.string as NSString).range(of: "Estonia"), .command)
                && model.editor?.document.relativePath == "_notes/2025-12-01-estonia.md", "⌘-click opens the linked post") && ok
        } else {
            ok = check(false, "link draft in the editor") && ok
        }

        // Health: a missing 404 page is found, and its fix adds the page as an unpublished change.
        try? FileManager.default.removeItem(at: root.appending(path: "404.html"))
        model.reloadSite()
        await settle()
        if let site = model.site {
            let report = SiteHealth.check(site)
            if let issue = report.issues.first(where: { $0.id == "404" }) {
                model.applyFix(issue)
                await settle()
                ok = check(FileManager.default.fileExists(atPath: root.appending(path: "404.md").path) && model.changes["404.md"] == .added,
                           "health fix adds 404.md as a change") && ok
            } else {
                ok = check(false, "health finds the missing 404 page") && ok
            }
            ok = check(!report.issues.contains { $0.id.hasPrefix("images:") }, "commented-out examples are not reported") && ok
        }
        return ok
    }

    /// Applies a theme, changes a colour, an option and the menu, and checks the files, the preview and the change list.
    /// Refuses a site whose remote is GitHub, like the publish self-test.
    static func design(_ model: AppModel) async -> Bool {
        guard let site = model.site, let design = model.design, let git = Git(root: site.root) else { return false }
        if let remote = await git.remoteURL(), remote.contains("github.com") { return false }
        func check(_ ok: Bool, _ what: String) -> Bool {
            print("design selftest: \(ok ? "ok" : "FAILED") \(what)")
            return ok
        }
        guard let theme = ThemeManifest.named("notebook") else { return false }
        design.apply(design.plan(for: theme))
        var ok = check(design.theme?.id == "notebook", "theme applied")
        design.setToken("--accent", "#123456", scheme: .light)
        design.setToken("--accent", "#ABCDEF", scheme: .dark)
        let css = design.read("assets/css/inkwell.css") ?? "", dark = design.read("assets/css/inkwell-dark.css") ?? ""
        ok = check(css.contains("--accent: #123456;") && dark.contains("--accent: #ABCDEF;"), "colours written") && ok
        design.setOption("home_style", .text("cards"))
        design.setString("title", "Design Self-test")
        let config = design.read("_config.yml") ?? ""
        ok = check(config.contains("home_style: \"cards\"") && config.contains("title: \"Design Self-test\""), "settings written") && ok
        design.saveNavigation(design.navigation.entries + [NavigationEntry(title: "Elsewhere", url: "https://example.com")])
        ok = check(design.read("_data/navigation.yml")?.contains("https://example.com") == true, "menu written") && ok
        let footer = CodeFile(path: "_includes/inkwell-footer.html", inTheme: false)
        design.saveCode(footer, (design.read(footer.path) ?? "") + "<p class=\"selftest-marker\">Edited in the code editor</p>\n")
        let browsed = design.makeResources().map { String(decoding: $0.response(for: "/notes").data, as: UTF8.self) } ?? ""
        ok = check(browsed.contains("selftest-marker") && browsed.contains("post-list"), "code edit shows when browsing to /notes") && ok
        let preview = design.previewHTML()?.html ?? ""
        ok = check(preview.contains("inkwell.css") && preview.contains("Design Self-test") && preview.contains("Elsewhere"), "preview") && ok
        try? await Task.sleep(for: .seconds(2))
        let changed = Set(model.changes.keys)
        ok = check(["assets/css/inkwell.css", "_config.yml", "_data/navigation.yml", "_layouts/post.html"].allSatisfy(changed.contains),
                   "unpublished changes listed (\(changed.count))") && ok
        return ok
    }

    /// Writes a draft with an image, publishes it to the site's (local) remote and checks that the commit holds
    /// exactly the post and the image. Refuses to run against a GitHub remote, so a real site is never touched.
    static func publish(_ model: AppModel) async -> Bool {
        guard let site = model.site, let git = Git(root: site.root) else {
            print("No site or no git.")
            return false
        }
        if let remote = await git.remoteURL(), remote.contains("github.com") {
            print("Refusing to self-test against a GitHub remote: \(remote)")
            return false
        }
        print("selftest: site loaded")
        model.sidebarSelection = .section("notes")
        model.newPost()
        guard let editor = model.editor else { return false }
        editor.title = "Self-test post"
        let picture = FileManager.default.temporaryDirectory.appending(path: "IMG_0001.png")
        let size = NSSize(width: 64, height: 48)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .jpeg, properties: [:]) else { return false }
        try? png.write(to: picture)
        guard let imported = try? ImageImport().importImage(at: picture, siteRoot: site.root, slug: "self-test-post") else {
            print("Image import failed.")
            return false
        }
        editor.body = "\nWritten by the self-test.\n\n" + imported.markdown(alt: "A teal square", useRelativeURL: true) + "\n"
        editor.saveNow()
        try? await Task.sleep(for: .milliseconds(300))
        model.refreshChanges()
        try? await Task.sleep(for: .milliseconds(800))
        model.beginPublish()
        guard let session = model.publishSheet else {
            print("Publish was not offered.")
            return false
        }
        print("selftest: publishing")
        await session.run()
        print("selftest: published")
        let files = (try? await git.run(["show", "--name-only", "--format=", "HEAD"]))?
            .split(separator: "\n").map(String.init).sorted() ?? []
        let expected = [editor.document.relativePath, String(imported.sitePath.dropFirst())].sorted()
        print("Phase: \(session.phase)")
        print("Committed: \(files)")
        let draftsLeft = FileManager.default.fileExists(atPath: editor.document.fileURL.path) ? 1 : 0
        return (session.phase == .pushed || session.phase == .committedOnly) && files == expected && draftsLeft == 0
    }
}
