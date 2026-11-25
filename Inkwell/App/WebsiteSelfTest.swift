import AppKit
import InkwellKit

extension SelfTest {
    /// `--selftest-website`, on a local copy of a hand-built site whose `index.html` links `assets/*.css` (SPEC §4.12): edits
    /// the home page and adds a picture to it, changes the shared stylesheet, and publishes the page. The commit must hold
    /// the page and its new picture only, byte for byte as edited, with no front matter. Refuses GitHub remotes.
    static func website(_ model: AppModel) async -> Bool {
        guard let site = model.site, let local = model.backend as? LocalGitBackend else { return false }
        func check(_ ok: Bool, _ what: String) -> Bool {
            print("website selftest: \(ok ? "ok" : "FAILED") \(what)")
            return ok
        }
        var ok = check(site.kind == .handBuilt, "recognised as hand-built (\(site.kind.rawValue))")
        ok = check(site.sections.map(\.id) == ["pages"], "pages only, no posts section (\(site.sections.map(\.id)))") && ok
        guard let home = site.documents.first(where: { $0.relativePath == "index.html" }), home.isStatic,
              let original = try? String(contentsOf: home.fileURL, encoding: .utf8) else {
            return check(false, "index.html is listed as a page served as it is")
        }

        // The preview serves the home page as it is, with no Liquid run.
        if let builder = model.previewBuilder {
            let response = SiteResources(builder: builder, themeRoot: nil, sass: nil).response(for: "/")
            ok = check(response.status == 200 && response.data == Data(original.utf8), "preview of / is index.html unchanged") && ok
        }

        // A new picture, a change to the shared stylesheet, and an edit to the page that uses the picture.
        let root = site.root
        let picture = "media/selftest-\(Int(Date().timeIntervalSince1970)).png"
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: root.appending(path: "media"), withIntermediateDirectories: true)
            try? png.write(to: root.appending(path: picture))
        }
        let stylesheet = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "assets").path))?
            .first { $0.hasSuffix(".css") }.map { "assets/\($0)" }
        if let stylesheet, let css = try? String(contentsOf: root.appending(path: stylesheet), encoding: .utf8) {
            try? Data((css + "\n/* selftest */\n").utf8).write(to: root.appending(path: stylesheet))
        }
        model.select(home.id)
        guard let editor = model.editor else { return check(false, "home page opens") }
        let marker = "<p><img src=\"\(picture)\" alt=\"A test picture\"></p>"
        guard let bodyClose = original.range(of: "</body>") else { return check(false, "home page has </body>") }
        var edited = original
        edited.insert(contentsOf: marker + "\n", at: bodyClose.lowerBound)
        editor.setFullText(edited)
        editor.saveNow()
        let saved = (try? String(contentsOf: home.fileURL, encoding: .utf8)) ?? ""
        ok = check(saved == edited, "saved byte for byte, nothing else changed") && ok

        model.refreshChanges()
        try? await Task.sleep(for: .seconds(1))
        model.beginPublish()
        guard let session = model.publishSheet else { return check(false, "publish sheet opens") }
        let prefix = await local.git.prefix()
        let expected = Set(["index.html", picture].map { prefix + $0 })
        ok = check(!session.checks.contains { $0.level == .error }, "checklist has no errors") && ok
        await session.run()
        let files = Set((try? await local.git.run(["show", "--name-only", "--no-renames", "--format=", "HEAD"]))?
            .split(separator: "\n").map(String.init) ?? [])
        ok = check(session.phase == .pushed && files == expected, "one commit with the page and its picture only (\(files.sorted()))") && ok
        let committed = (try? await local.git.run(["show", "HEAD:\(prefix)index.html"])) ?? ""
        let sameText = committed.trimmingCharacters(in: .newlines) == edited.trimmingCharacters(in: .newlines)
        ok = check(sameText && !committed.hasPrefix("---"), "committed page is the edited text, with no front matter") && ok
        if let stylesheet {
            let status = (try? await local.git.status()) ?? [:]
            ok = check(status[prefix + stylesheet] != nil || status[stylesheet] != nil, "shared stylesheet left unpublished") && ok
        }
        model.publishSheet = nil

        let report = SiteHealth.check(model.site ?? site)
        let jekyllFix = report.issues.contains { issue in
            if case let .edits(edits, _)? = issue.fix { return edits.contains { $0.path == "_config.yml" || $0.path.hasSuffix(".md") } }
            return false
        }
        ok = check(!jekyllFix, "health offers no Jekyll fixes") && ok

        // Last, since it ends with the site moved to Jekyll.
        ok = await editingChecks(model) && ok
        return ok
    }

    /// W2: a description added through Properties, a picture dropped on a page, and a new page made from the home page.
    static func editingChecks(_ model: AppModel) async -> Bool {
        guard let site = model.site else { return false }
        func check(_ ok: Bool, _ what: String) -> Bool {
            print("website selftest: \(ok ? "ok" : "FAILED") \(what)")
            return ok
        }
        var ok = true
        guard let about = site.documents.first(where: { $0.relativePath == "about.html" }),
              let before = try? String(contentsOf: about.fileURL, encoding: .utf8) else { return check(false, "about.html is a page") }
        model.select(about.id)
        guard let editor = model.editor else { return check(false, "about.html opens") }
        editor.setFullText(HTMLHead.setting(.description, to: "Who makes it", in: editor.fullText))
        editor.saveNow()
        let after = (try? String(contentsOf: about.fileURL, encoding: .utf8)) ?? ""
        let added = after.count - before.count
        ok = check(HTMLHead(after).description == "Who makes it" && after.replacingOccurrences(of: #"<meta name="description" content="Who makes it">"#,
                                                                                                with: "") == before && added > 0,
                   "description added as one tag, nothing else changed") && ok

        // A picture dropped on the page: imported, then written as <img> with its alt text.
        let source = FileManager.default.temporaryDirectory.appending(path: "inkwell-selftest-drop.png")
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: source)
        }
        let at = (editor.fullText as NSString).range(of: "</body>").location
        model.importImagesIntoPage([source], at: at)
        for _ in 0 ..< 30 where model.pendingImage == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if var pending = model.pendingImage {
            pending.alt = "An orange square"
            model.pendingImage = pending
            model.insertPendingImage()
            editor.saveNow()
            let text = (try? String(contentsOf: about.fileURL, encoding: .utf8)) ?? ""
            let src = pending.htmlSource ?? ""
            ok = check(text.contains("<img src=\"\(src)\" alt=\"An orange square\">")
                && FileManager.default.fileExists(atPath: site.root.appending(path: src).path), "dropped picture imported and inserted (\(src))") && ok
        } else {
            ok = check(false, "dropped picture imported") && ok
        }

        // W3: a paragraph edited on the preview itself.
        if let home = model.site?.documents.first(where: { $0.relativePath == "index.html" }) {
            model.editOnPage = true
            model.showPreview = true
            model.select(home.id)
            try? await Task.sleep(for: .seconds(3))
            let script = """
            (() => {
              const el = [...document.querySelectorAll('p[data-ik-text]')].find((p) => p.textContent.includes('plain HTML'));
              if (!el) return 'none';
              el.click();
              el.textContent = 'Edited on the page & saved';
              el.dispatchEvent(new FocusEvent('focusout', { bubbles: true }));
              return el.dataset.ikText;
            })()
            """
            let answer = try? await SitePreview.latest?.evaluateJavaScript(script)
            try? await Task.sleep(for: .seconds(1))
            model.editor?.saveNow()
            let text = (try? String(contentsOf: home.fileURL, encoding: .utf8)) ?? ""
            ok = check(text.contains("<p>Edited on the page &amp; saved</p>") && !text.contains("data-ik"),
                       "paragraph edited on the page, no marks in the file (\(answer.map { "\($0)" } ?? "no preview"))") && ok

            // W3: a link's address changed from the preview's chip, then put back.
            let click = """
            (() => {
              const a = document.querySelector('nav a[data-ik-link]');
              if (!a) return 'no link';
              a.click();
              const button = document.querySelector('.inkwell-chip button');
              if (!button) return 'no chip';
              button.click();
              return a.getAttribute('href');
            })()
            """
            let clicked = try? await SitePreview.latest?.evaluateJavaScript(click)
            for _ in 0 ..< 20 where model.pageLinkEdit == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let edit = model.pageLinkEdit {
                model.pageLinkEdit = nil
                model.finishPageLinkEdit(edit, address: "about.html#team")
                model.editor?.saveNow()
                let changed = (try? String(contentsOf: home.fileURL, encoding: .utf8)) ?? ""
                ok = check(changed == text.replacingOccurrences(of: #"href="about.html""#, with: #"href="about.html#team""#) && changed != text,
                           "link address changed from the preview, nothing else") && ok
                model.finishPageLinkEdit(AppModel.PageLinkEdit(index: edit.index, address: "about.html#team", page: edit.page), address: "about.html")
                model.editor?.saveNow()
                ok = check((try? String(contentsOf: home.fileURL, encoding: .utf8)) == text, "link address put back") && ok
            } else {
                ok = check(false, "link chip asks for a new address (\(clicked.map { "\($0)" } ?? "no preview"))") && ok
            }
            model.editOnPage = false
        }

        // A new page from the home page.
        model.createHTMLPage(title: "Pricing", basedOn: nil)
        try? await Task.sleep(for: .seconds(1))
        let page = (try? String(contentsOf: site.root.appending(path: "pricing.html"), encoding: .utf8)) ?? ""
        let listed = model.site?.documents.first { $0.relativePath == "pricing.html" }
        ok = check(page.contains("<h1>Pricing</h1>") && page.contains("assets/site.css") && !page.hasPrefix("---")
            && listed?.isStatic == true, "new page copies the site's look and is listed (\(HTMLHead(page).title ?? "no title"))") && ok

        // W4: the home page's header changed, and the same change made on the new page that copied it.
        if let home = model.site?.documents.first(where: { $0.relativePath == "index.html" }), let pricing = listed {
            model.select(home.id)
            if let editor = model.editor {
                let before = editor.fullText
                editor.setFullText(before.replacingOccurrences(of: "<h1>Plain Product</h1>", with: "<h1>Plain Product Co</h1>"))
                editor.saveNow()
                let change = SharedParts.changes(from: before, to: editor.fullText).first
                let changed = change.map { model.applySharedPart(old: $0.old, new: $0.new, to: [pricing]) } ?? 0
                let text = (try? String(contentsOf: pricing.fileURL, encoding: .utf8)) ?? ""
                ok = check(change?.part == .header && changed == 1 && text.contains("<h1>Plain Product Co</h1>")
                    && text.contains("<h1>Pricing</h1>"), "header change applied to the page sharing it") && ok
            }
        }
        ok = await menuAndJekyllChecks(model) && ok
        return ok
    }

    /// W4 steps 2 and 3: a menu item added on the home page reaches the page with the same menu; then the site moves to
    /// Jekyll, with its shared header in an include the preview runs.
    static func menuAndJekyllChecks(_ model: AppModel) async -> Bool {
        func check(_ ok: Bool, _ what: String) -> Bool {
            print("website selftest: \(ok ? "ok" : "FAILED") \(what)")
            return ok
        }
        guard let root = model.site?.root else { return false }
        func read(_ path: String) -> String { (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? "" }
        var ok = true
        let aboutBefore = read("about.html")
        if let source = model.menuSources.first(where: { $0.path == "index.html" }), let text = model.currentText(of: "index.html"),
           let menu = HTMLMenu.find(in: text) {
            let matches = model.menuMatches(for: source, menu: menu)
            var entries = menu.entries
            entries.append(HTMLMenu.Entry(title: "Pricing", address: "pricing.html"))
            model.applyMenu(entries, from: menu, on: source, and: matches.same)
            model.editor?.saveNow()
            let item = #"<nav><a href="about.html">About</a><a href="pricing.html">Pricing</a></nav>"#
            ok = check(matches.same.map(\.path) == ["pricing.html"] && read("index.html").contains(item) && read("pricing.html").contains(item)
                && read("about.html") == aboutBefore, "menu item added on both pages with that menu, nothing else") && ok
        } else {
            ok = check(false, "home page menu found") && ok
        }

        model.createHTMLPage(title: "Contact", basedOn: nil)
        try? await Task.sleep(for: .seconds(1))
        guard let plan = model.jekyllAdoptionPlan() else { return check(false, "move to Jekyll planned") }
        ok = check(plan.isWorthDoing && plan.shared.map(\.path) == ["_includes/header.html"] && plan.leftAlone == ["index.html"]
            && plan.removals == [".nojekyll"], "move planned: header shared by \(plan.shared.first?.pages ?? []), home left alone") && ok
        model.adoptJekyll(plan)
        model.showChanges = false
        for _ in 0 ..< 40 where model.site?.kind != .website { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))
        let contact = model.site?.documents.first { $0.relativePath == "contact.html" }
        ok = check(model.site?.kind == .website && contact?.isHTMLPage == true && !FileManager.default.fileExists(atPath: root.appending(path: ".nojekyll").path)
            && read("_includes/header.html").contains("<h1>Plain Product Co</h1>") && read("contact.html").hasPrefix(JekyllAdoption.frontMatter),
            "moved to Jekyll: a website whose pages stay HTML (\(model.site?.kind.rawValue ?? "no site"))") && ok
        if let builder = model.previewBuilder, let contact {
            let page = builder.render(text: read("contact.html"), relativePath: "contact.html", url: contact.url)
            ok = check(page.html.contains("<h1>Plain Product Co</h1>") && !page.html.contains("{% include") && !page.html.contains("layout:"),
                       "preview runs the shared header include") && ok
        }
        return ok
    }
}
