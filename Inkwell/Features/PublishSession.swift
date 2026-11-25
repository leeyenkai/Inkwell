import Foundation
import InkwellKit
import Observation

struct CheckItem: Identifiable {
    enum Level { case ok, warning, error, info }

    let id = UUID()
    var level: Level
    var text: String
}

/// One change to the live site (publish, update, delete, unpublish, or a set of files), from the checklist to the
/// finished GitHub Pages build. File moves made before publishing are undone if publishing fails.
@Observable
final class PublishSession: Identifiable {
    enum Kind { case publish, update, delete, unpublish, changes }

    enum Phase: Equatable {
        case ready
        case publishing
        case building(PagesBuildState)
        case live
        case pushed
        case committedOnly
        case pushFailed(String)
        case conflict([String])
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let heading: String
    var message: String
    private(set) var checks: [CheckItem] = []
    private(set) var paths: [String]
    private(set) var phase: Phase = .ready
    private(set) var liveURL: URL?
    /// Offered when a post is dated in the future and the site has no schedule workflow yet.
    var addScheduleWorkflow: Bool?
    private(set) var scheduledFor: Date?
    /// Set when publishing adds `future: false` to `_config.yml`, so the scheduled post really waits.
    private(set) var holdsFuturePosts = false
    private static let configPath = "_config.yml"
    let displayURL: String?

    private let backend: any SiteBackend
    private weak var model: AppModel?
    private weak var editor: EditorDocument?
    private var prepare: () throws -> Void = {}
    private var rollback: () -> Void = {}
    private var succeeded: () -> Void = {}
    private var selectAfter: String?

    private init(kind: Kind, heading: String, message: String, paths: [String], displayURL: String?, backend: any SiteBackend, model: AppModel) {
        self.kind = kind
        self.heading = heading
        self.message = message
        self.paths = paths
        self.displayURL = displayURL
        self.backend = backend
        self.model = model
    }

    var hasErrors: Bool { checks.contains { $0.level == .error } }
    var actionTitle: String {
        switch kind {
        case .publish: scheduledFor == nil ? String(localized: "Publish") : String(localized: "Schedule")
        case .update: String(localized: "Update")
        case .delete: String(localized: "Delete from Site")
        case .unpublish: String(localized: "Unpublish")
        case .changes: String(localized: "Publish \(paths.count) Changes")
        }
    }

    // MARK: Kinds

    static func publish(document: SiteDocument, editor: EditorDocument, site: Site, backend: any SiteBackend, model: AppModel) -> PublishSession {
        let text = editor.fullText
        let title = FrontMatterDocument(text: text).value("title")?.string ?? document.title
        let isUpdate = document.origin == .repository && model.changes[document.relativePath] == .modified
        let name = title.isEmpty ? "Untitled" : title
        let shown = title.isEmpty ? String(localized: "Untitled") : title
        let heading = isUpdate ? String(localized: "Update “\(shown)”") : String(localized: "Publish “\(shown)”")
        let session = PublishSession(kind: isUpdate ? .update : .publish, heading: heading,
                                     message: "\(isUpdate ? "Update" : "Publish"): \(name)", paths: [document.relativePath],
                                     displayURL: Permalink.display(document.url, config: site.config), backend: backend, model: model)
        session.editor = editor
        session.liveURL = model.liveURL(for: document)
        session.selectAfter = document.relativePath
        session.buildChecklist(document: document, text: text, site: site, changes: model.changes)
        if document.origin == .localDraft {
            let target = site.root.appending(path: document.relativePath)
            session.prepare = { [weak session] in
                let current = session?.editor?.fullText ?? text
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(current.utf8).write(to: target, options: .withoutOverwriting)
            }
            session.rollback = { try? FileManager.default.removeItem(at: target) }
            session.succeeded = { [weak session] in
                session?.editor?.retire()
                try? FileManager.default.removeItem(at: document.fileURL)
            }
        }
        return session
    }

    static func delete(document: SiteDocument, backend: any SiteBackend, model: AppModel) -> PublishSession {
        let session = PublishSession(kind: .delete, heading: String(localized: "Delete “\(document.title)”"),
                                     message: "Delete: \(document.title)",
                                     paths: [document.relativePath], displayURL: nil, backend: backend, model: model)
        var saved: Data?
        let note = String(localized: "The page at \(document.url) stops working once GitHub Pages rebuilds the site.")
        session.checks = [CheckItem(level: .info, text: note)]
        session.prepare = {
            saved = try Data(contentsOf: document.fileURL)
            try FileManager.default.removeItem(at: document.fileURL)
        }
        session.rollback = { if let saved { try? saved.write(to: document.fileURL) } }
        return session
    }

    static func unpublish(document: SiteDocument, draftURL: URL, backend: any SiteBackend, model: AppModel) -> PublishSession {
        let session = PublishSession(kind: .unpublish, heading: String(localized: "Unpublish “\(document.title)”"),
                                     message: "Unpublish: \(document.title)",
                                     paths: [document.relativePath], displayURL: nil, backend: backend, model: model)
        let note = String(localized: "The post leaves your site and goes back to Drafts on this Mac, where you can keep working on it.")
        session.checks = [CheckItem(level: .info, text: note)]
        var saved: Data?
        session.prepare = {
            let data = try Data(contentsOf: document.fileURL)
            saved = data
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: draftURL, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: document.fileURL)
        }
        session.rollback = {
            if let saved { try? saved.write(to: document.fileURL) }
            try? FileManager.default.removeItem(at: draftURL)
        }
        return session
    }

    static func changes(paths: [String], message: String, backend: any SiteBackend, model: AppModel,
                        heading: String = String(localized: "Publish changes"), selecting: String? = nil) -> PublishSession {
        let session = PublishSession(kind: .changes, heading: heading, message: message, paths: paths, displayURL: nil,
                                     backend: backend, model: model)
        session.selectAfter = selecting
        session.checks = [CheckItem(level: .info, text: String(localized: "\(paths.count) files go to your site in one change."))]
        return session
    }

    // MARK: Checklist

    private func buildChecklist(document: SiteDocument, text: String, site: Site, changes: [String: ChangeKind]) {
        if document.isStatic || site.kind.servesFilesAsIs {
            return buildStaticChecklist(document: document, text: text, site: site, changes: changes)
        }
        let doc = FrontMatterDocument(text: text)
        var items: [CheckItem] = []
        let issues = Validation.frontMatter(doc, filename: document.filename, inCollection: !document.isPage)
        if issues.isEmpty {
            items.append(CheckItem(level: .ok, text: String(localized: "Properties are valid")))
        } else {
            for issue in issues { items.append(CheckItem(level: issue.severity == .error ? .error : .warning, text: issue.message)) }
        }
        if doc.value("published")?.bool == false {
            let note = String(localized: "published is off: the post stays off the site, but its file is public on GitHub.")
            items.append(CheckItem(level: .warning, text: note))
        }
        if document.origin == .localDraft, FileManager.default.fileExists(atPath: site.root.appending(path: document.relativePath).path) {
            items.append(CheckItem(level: .error, text: String(localized: "\(document.relativePath) already exists in the site.")))
        }

        var imagePaths: [String] = []
        var bytes = 0
        var missingAlt = 0
        var withLocation = 0
        var large: [String] = []
        var refs = ContentChecks.images(in: doc.body)
        // The share image in the properties travels with the post too.
        if let share = doc.value("image")?.string, !share.isEmpty {
            refs.append(ImageReference(alt: "share image", path: ContentChecks.plainPath(share), range: doc.body.startIndex ..< doc.body.startIndex))
        }
        // A banner's picture is in its settings, not a Markdown image.
        let elements = PageElements.find(in: doc.body)
        for element in elements {
            if let image = element.attributes["image"], !image.isEmpty {
                refs.append(ImageReference(alt: "banner", path: image, range: doc.body.startIndex ..< doc.body.startIndex))
            }
        }
        for ref in refs {
            if ref.alt.trimmingCharacters(in: .whitespaces).isEmpty { missingAlt += 1 }
            if ref.path.hasPrefix("http://") || ref.path.hasPrefix("https://") || ref.path.hasPrefix("//") { continue }
            guard ref.path.hasPrefix("/") else {
                let note = String(localized: "“\(ref.path)” is a relative image path, which may break on the live site.")
                items.append(CheckItem(level: .warning, text: note))
                continue
            }
            var relative = String(ref.path.dropFirst())
            if !site.config.baseurl.isEmpty, ref.path.hasPrefix(site.config.baseurl + "/") {
                relative = String(ref.path.dropFirst(site.config.baseurl.count + 1))
            }
            let file = site.root.appending(path: relative)
            guard FileManager.default.fileExists(atPath: file.path) else {
                items.append(CheckItem(level: .error, text: String(localized: "Image not found: \(ref.path)")))
                continue
            }
            if changes[relative] == .added || changes[relative] == .modified, !imagePaths.contains(relative) {
                imagePaths.append(relative)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                bytes += size
                if size > 1_000_000 { large.append((relative as NSString).lastPathComponent) }
                if ImageImport.hasLocation(file) { withLocation += 1 }
            }
        }
        if !imagePaths.isEmpty {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            items.append(CheckItem(level: .ok, text: String(localized: "\(imagePaths.count) new images (\(size))")))
        }
        if withLocation > 0 {
            items.append(CheckItem(level: .warning, text: String(localized: "\(withLocation) images still have location data.")))
        }
        if !large.isEmpty {
            let names = large.joined(separator: ", ")
            items.append(CheckItem(level: .warning, text: String(localized: "Over 1 MB, slow on phones: \(names)")))
        }
        if missingAlt > 0 {
            items.append(CheckItem(level: .warning, text: String(localized: "\(missingAlt) images are missing alt text")))
        }
        let address = SiteHealth.normalized(document.url)
        if let twin = site.documents.first(where: {
            $0.relativePath != document.relativePath && $0.publishedFlag && SiteHealth.normalized($0.url) == address
        }) {
            let note = String(localized: "\(twin.relativePath) already uses the address \(document.url).")
            items.append(CheckItem(level: .error, text: note))
        }
        let title = doc.value("title")?.string ?? ""
        let fullTitle = site.config.title.isEmpty ? title : "\(title) | \(site.config.title)"
        if fullTitle.count > 60 {
            let note = String(localized: "Search results show about 60 characters of the title; this one has \(fullTitle.count).")
            items.append(CheckItem(level: .info, text: note))
        }
        let broken = brokenInternalLinks(doc.body, site: site)
        if broken.isEmpty {
            items.append(CheckItem(level: .ok, text: String(localized: "No broken links")))
        } else {
            for link in broken {
                items.append(CheckItem(level: .warning, text: String(localized: "Link goes nowhere on the site: \(link)")))
            }
        }
        if let date = doc.value("date")?.string.flatMap({ SiteDate.parse($0, timeZone: site.config.timeZone) }) ?? document.date,
           Schedule.isScheduled(date) {
            if Schedule.futureTurnedOn(site.config) {
                let note = String(localized: "The date is in the future, but future: true in _config.yml shows it right away.")
                items.append(CheckItem(level: .warning, text: note))
            } else {
                scheduledFor = date
                let when = date.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: site.config.timeZone))
                items.append(CheckItem(level: .info, text: String(localized: "Scheduled: the post stays off the site until \(when).")))
                if Schedule.publishesFutureNow(site.config) {
                    items += holdFuturePostsChecks(document: document, site: site, changes: changes)
                }
                if !Schedule.hasWorkflow(siteRoot: site.root) {
                    if let blocker = model?.scheduleWorkflowBlocker {
                        items.append(CheckItem(level: .info, text: blocker.message))
                    } else {
                        addScheduleWorkflow = true
                    }
                }
            }
        }
        if let repo = backend.repository {
            let note = String(localized: "Goes to \(repo.owner)/\(repo.name); GitHub Pages then rebuilds the site.")
            items.append(CheckItem(level: .info, text: note))
        }
        let kitLayouts = ["inkwell-slides", "slides", "album"]
        let kitPaths = elementKitPaths(uses: !elements.isEmpty || kitLayouts.contains(doc.value("layout")?.string ?? ""),
                                       changes: changes, site: site)
        if !kitPaths.isEmpty {
            items.append(CheckItem(level: .info, text: String(localized: "Adds the files that page elements need (\(kitPaths.count)).")))
        }
        checks = items
        paths = [document.relativePath] + imagePaths + kitPaths + (holdsFuturePosts ? [Self.configPath] : [])
    }

    /// A page served as it is: its links and pictures are checked relative to its folder, and new or changed pictures
    /// and other new files it uses go with it. Changes to shared files (a stylesheet used by every page) do not.
    private func buildStaticChecklist(document: SiteDocument, text: String, site: Site, changes: [String: ChangeKind]) {
        var items: [CheckItem] = []
        let fm = FileManager.default
        if (HTMLHead(text).title ?? "").isEmpty {
            items.append(CheckItem(level: .warning, text: String(localized: "The page has no title, so browsers show its address.")))
        }
        let mediaExtensions: Set = ["jpg", "jpeg", "png", "gif", "webp", "svg", "avif", "mp4", "webm", "mov", "mp3", "m4a", "pdf"]
        var files: [String] = [], missing: [String] = [], broken: [String] = [], shared: [String] = []
        for reference in SiteHealth.htmlReferences(in: text) {
            guard let path = SiteHealth.resolve(reference.target, from: document.relativePath, baseurl: site.config.baseurl) else { continue }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            var isFolder: ObjCBool = false
            let found = trimmed.isEmpty || fm.fileExists(atPath: site.root.appending(path: trimmed).path, isDirectory: &isFolder)
                || fm.fileExists(atPath: site.root.appending(path: trimmed + ".html").path)
            guard found else {
                if case .image = reference { missing.append(reference.target) } else { broken.append(reference.target) }
                continue
            }
            guard !trimmed.isEmpty, !isFolder.boolValue, trimmed != document.relativePath, let change = changes[trimmed],
                  change == .added || change == .modified, !files.contains(trimmed), !shared.contains(trimmed) else { continue }
            let ext = (trimmed as NSString).pathExtension.lowercased()
            if mediaExtensions.contains(ext) || (change == .added && !["html", "htm"].contains(ext)) {
                files.append(trimmed)
            } else if !["html", "htm"].contains(ext) {
                shared.append(trimmed)
            }
        }
        for target in missing { items.append(CheckItem(level: .error, text: String(localized: "Image not found: \(target)"))) }
        if broken.isEmpty {
            items.append(CheckItem(level: .ok, text: String(localized: "No broken links")))
        } else {
            for link in broken { items.append(CheckItem(level: .warning, text: String(localized: "Link goes nowhere on the site: \(link)"))) }
        }
        let noAlt = SiteHealth.imagesWithoutAlt(in: text).count
        if noAlt > 0 { items.append(CheckItem(level: .warning, text: String(localized: "\(noAlt) images are missing alt text"))) }
        if !files.isEmpty {
            items.append(CheckItem(level: .ok, text: String(localized: "\(files.count) new or changed files go with the page")))
        }
        if !shared.isEmpty {
            let names = shared.joined(separator: ", ")
            let note = String(localized: "Not included, as other pages use them too: \(names). Publish them from Review Changes.")
            items.append(CheckItem(level: .info, text: note))
        }
        if let repo = backend.repository {
            let note = String(localized: "Goes to \(repo.owner)/\(repo.name); GitHub Pages then rebuilds the site.")
            items.append(CheckItem(level: .info, text: note))
        }
        checks = items
        paths = [document.relativePath] + files
    }

    /// GitHub Pages builds posts dated in the future straight away unless `_config.yml` says `future: false`, so a
    /// scheduled post adds that line and takes the file with it.
    private func holdFuturePostsChecks(document: SiteDocument, site: Site, changes: [String: ChangeKind]) -> [CheckItem] {
        holdsFuturePosts = true
        let note = String(localized: "GitHub Pages shows posts dated in the future right away, so this adds future: false to _config.yml.")
        var items = [CheckItem(level: .info, text: note)]
        if changes[Self.configPath] != nil {
            let note = String(localized: "_config.yml has other unpublished changes, and they go out with this post too.")
            items.append(CheckItem(level: .warning, text: note))
        }
        let others = site.documents.filter {
            $0.relativePath != document.relativePath && !$0.isPage && $0.publishedFlag && changes[$0.relativePath] != .added
                && Schedule.isScheduled($0.date)
        }
        if !others.isEmpty {
            let names = others.map { $0.title.isEmpty ? $0.filename : $0.title }.joined(separator: ", ")
            let note = String(localized: "These posts are dated in the future and leave the site until their dates: \(names)")
            items.append(CheckItem(level: .warning, text: note))
        }
        return items
    }

    /// Element kit files Inkwell wrote that are not yet on GitHub, and head files changed to load the kit, when the post
    /// uses elements. A kit file someone edited by hand is theirs to publish.
    private func elementKitPaths(uses: Bool, changes: [String: ChangeKind], site: Site) -> [String] {
        guard uses else { return [] }
        let kit = ElementKit.files
        return changes.filter { path, kind in
            guard kind != .deleted else { return false }
            if let text = kit[path] {
                return (try? String(contentsOf: site.root.appending(path: path), encoding: .utf8)) == text
            }
            guard path.hasPrefix("_includes/") || path.hasPrefix("_layouts/") else { return false }
            return (try? String(contentsOf: site.root.appending(path: path), encoding: .utf8))?.contains("inkwell-blocks") == true
        }
        .keys.sorted()
    }

    private func brokenInternalLinks(_ body: String, site: Site) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\!)\[[^\]]*\]\((/[^)\s#]*)"#) else { return [] }
        let ns = body as NSString
        let known = Set(site.documents.flatMap { [$0.url, $0.url.hasSuffix("/") ? String($0.url.dropLast()) : $0.url + "/"] })
        var broken: [String] = []
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            let trimmed = String(path.drop { $0 == "/" })
            let exists = known.contains(path) || FileManager.default.fileExists(atPath: site.root.appending(path: trimmed).path)
                || FileManager.default.fileExists(atPath: site.root.appending(path: trimmed + ".md").path)
            if !exists, !broken.contains(path) { broken.append(path) }
        }
        return broken
    }

    // MARK: Run

    func run() async {
        phase = .publishing
        editor?.saveNow()
        do {
            try prepare()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        do {
            if addScheduleWorkflow == true, let root = model?.site?.root {
                let file = root.appending(path: Schedule.workflowPath)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(Schedule.workflow.utf8).write(to: file, options: .withoutOverwriting)
                paths.append(Schedule.workflowPath)
                let earlier = rollback
                rollback = {
                    earlier()
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if holdsFuturePosts, let root = model?.site?.root {
                try holdFuturePosts(root: root)
            }
        } catch {
            rollback()
            phase = .failed(error.localizedDescription)
            return
        }
        do {
            let outcome = try await backend.publish(paths: paths, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            succeeded()
            model?.didPublish(selecting: selectAfter)
            guard outcome.pushed else {
                phase = outcome.pushError.map { .pushFailed($0) } ?? .committedOnly
                return
            }
            guard let client = backend.client, let repo = backend.repository else {
                phase = .pushed
                return
            }
            phase = .building(.waiting)
            let watcher = BuildWatcher(client: client, owner: repo.owner, repository: repo.name)
            let final = await watcher.watch(commit: outcome.commit) { [weak self] state in
                await self?.update(state)
            }
            phase = final == .live ? .live : .building(final)
        } catch let SyncError.conflict(paths) {
            rollback()
            phase = .conflict(paths)
            model?.refreshChanges()
        } catch {
            rollback()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Writes `future: false` into `_config.yml` (read again now, in case it changed since the checklist), and puts the
    /// file back if publishing fails.
    private func holdFuturePosts(root: URL) throws {
        let url = root.appending(path: Self.configPath)
        let before = try? Data(contentsOf: url)
        let text = before.map { String(data: $0, encoding: .utf8) } ?? ""
        guard let text, let held = Schedule.configHoldingFuturePosts(text) else { return }
        try Data(held.utf8).write(to: url, options: .atomic)
        let earlier = rollback
        rollback = {
            earlier()
            if let before { try? before.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func update(_ state: PagesBuildState) {
        phase = state == .live ? .live : .building(state)
    }

    func retryPush() async {
        phase = .publishing
        do {
            try await backend.pushAgain()
            phase = .pushed
        } catch {
            phase = .pushFailed(error.localizedDescription)
        }
        model?.refreshChanges()
    }
}
