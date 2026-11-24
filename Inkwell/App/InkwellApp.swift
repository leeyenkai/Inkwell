import AppKit
import InkwellKit
import SwiftUI

@main
struct InkwellApp: App {
    @State private var model = AppModel()

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
                Button("Switch Site…") { model.closeSite() }
                    .keyboardShortcut("o")
                    .disabled(model.site == nil)
            }
            CommandGroup(after: .saveItem) {
                Button(model.publishTitle + "…") { model.beginPublish() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canPublish)
                Button("Review Unpublished Changes…") { model.showChanges = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                    .disabled(model.site == nil)
                Button("Check GitHub for Changes") { Task { await model.sync() } }
                    .keyboardShortcut("r")
                    .disabled(model.site == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Preview", isOn: $model.showPreview)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Toggle("Source", isOn: $model.showSource)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Properties", isOn: $model.showProperties)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
            FormatCommands(model: model)
        }
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
            Button("Link") { model.textView?.link() }.keyboardShortcut("k")
            Divider()
            Button("Heading 1") { model.textView?.heading(1) }.keyboardShortcut("1")
            Button("Heading 2") { model.textView?.heading(2) }.keyboardShortcut("2")
            Button("Heading 3") { model.textView?.heading(3) }.keyboardShortcut("3")
            Button("Heading 4") { model.textView?.heading(4) }.keyboardShortcut("4")
            Button("Body Text") { model.textView?.heading(0) }.keyboardShortcut("0")
            Divider()
            Button("Quote") { model.textView?.prefixLines("> ") }.keyboardShortcut("'", modifiers: [.command])
            Button("Bulleted List") { model.textView?.prefixLines("- ") }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Checklist") { model.textView?.prefixLines("- [ ] ") }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Footnote") { model.textView?.footnote() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Section Break") { model.textView?.divider() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Add Image…") { addImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }

    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image. It is resized, cleaned of location data and copied into the site."
        guard model.editor != nil, panel.runModal() == .OK, let url = panel.url else { return }
        model.importImages([url], at: model.textView?.selectedRange().location ?? 0)
    }
}

/// Launch arguments: `--fresh` (do not reopen the last site), `--pane design|navigation|settings`, `--apply-theme <id>`, `--site <folder>`,
/// `--open <path in site>`, `--section <id>`, `--preview`,
/// `--source`, `--publish-sheet`,
/// `--new-draft <title>` with optional `--draft-body <file>`, and `--selftest-publish` (needs a site whose remote is not GitHub).
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
        if args.contains("--selftest-publish") { setvbuf(stdout, nil, _IONBF, 0) }
        if let path = value("--site") {
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
        if let id = value("--apply-theme"), let theme = ThemeManifest.named(id), let design = model.design {
            design.apply(design.plan(for: theme))
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
        if args.contains("--preview") { model.showPreview = true }
        if args.contains("--source") { model.showSource = true }
        if args.contains("--publish-sheet") {
            try? await Task.sleep(for: .milliseconds(600))
            model.refreshChanges()
            try? await Task.sleep(for: .milliseconds(600))
            model.beginPublish()
        }
    }
}

enum SelfTest {
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
