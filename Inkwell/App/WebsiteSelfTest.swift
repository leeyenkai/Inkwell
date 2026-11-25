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
        return ok
    }
}
