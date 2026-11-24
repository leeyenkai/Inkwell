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
        case .publish: scheduledFor == nil ? "Publish" : "Schedule"
        case .update: "Update"
        case .delete: "Delete from Site"
        case .unpublish: "Unpublish"
        case .changes: "Publish \(paths.count) Change\(paths.count == 1 ? "" : "s")"
        }
    }

    // MARK: Kinds

    static func publish(document: SiteDocument, editor: EditorDocument, site: Site, backend: any SiteBackend, model: AppModel) -> PublishSession {
        let text = editor.fullText
        let title = FrontMatterDocument(text: text).value("title")?.string ?? document.title
        let isUpdate = document.origin == .repository && model.changes[document.relativePath] == .modified
        let name = title.isEmpty ? "Untitled" : title
        let session = PublishSession(kind: isUpdate ? .update : .publish, heading: "\(isUpdate ? "Update" : "Publish") “\(name)”",
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
        let session = PublishSession(kind: .delete, heading: "Delete “\(document.title)”", message: "Delete: \(document.title)",
                                     paths: [document.relativePath], displayURL: nil, backend: backend, model: model)
        var saved: Data?
        session.checks = [CheckItem(level: .info, text: "The page at \(document.url) stops working once GitHub Pages rebuilds the site.")]
        session.prepare = {
            saved = try Data(contentsOf: document.fileURL)
            try FileManager.default.removeItem(at: document.fileURL)
        }
        session.rollback = { if let saved { try? saved.write(to: document.fileURL) } }
        return session
    }

    static func unpublish(document: SiteDocument, draftURL: URL, backend: any SiteBackend, model: AppModel) -> PublishSession {
        let session = PublishSession(kind: .unpublish, heading: "Unpublish “\(document.title)”", message: "Unpublish: \(document.title)",
                                     paths: [document.relativePath], displayURL: nil, backend: backend, model: model)
        session.checks = [CheckItem(level: .info, text: "The post leaves your site and goes back to Drafts on this Mac, where you can keep working on it.")]
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

    static func changes(paths: [String], message: String, backend: any SiteBackend, model: AppModel, heading: String = "Publish changes",
                        selecting: String? = nil) -> PublishSession {
        let session = PublishSession(kind: .changes, heading: heading, message: message, paths: paths, displayURL: nil,
                                     backend: backend, model: model)
        session.selectAfter = selecting
        session.checks = [CheckItem(level: .info, text: "\(paths.count) file\(paths.count == 1 ? "" : "s") go to your site in one change.")]
        return session
    }

    // MARK: Checklist

    private func buildChecklist(document: SiteDocument, text: String, site: Site, changes: [String: ChangeKind]) {
        let doc = FrontMatterDocument(text: text)
        var items: [CheckItem] = []
        let issues = Validation.frontMatter(doc, filename: document.filename, inCollection: !document.isPage)
        if issues.isEmpty {
            items.append(CheckItem(level: .ok, text: "Properties are valid"))
        } else {
            for issue in issues { items.append(CheckItem(level: issue.severity == .error ? .error : .warning, text: issue.message)) }
        }
        if doc.value("published")?.bool == false {
            items.append(CheckItem(level: .warning, text: "published is off: the post stays off the site, but its file is public on GitHub."))
        }
        if document.origin == .localDraft, FileManager.default.fileExists(atPath: site.root.appending(path: document.relativePath).path) {
            items.append(CheckItem(level: .error, text: "\(document.relativePath) already exists in the site."))
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
        for ref in refs {
            if ref.alt.trimmingCharacters(in: .whitespaces).isEmpty { missingAlt += 1 }
            if ref.path.hasPrefix("http://") || ref.path.hasPrefix("https://") || ref.path.hasPrefix("//") { continue }
            guard ref.path.hasPrefix("/") else {
                items.append(CheckItem(level: .warning, text: "“\(ref.path)” is a relative image path, which may break on the live site."))
                continue
            }
            var relative = String(ref.path.dropFirst())
            if !site.config.baseurl.isEmpty, ref.path.hasPrefix(site.config.baseurl + "/") {
                relative = String(ref.path.dropFirst(site.config.baseurl.count + 1))
            }
            let file = site.root.appending(path: relative)
            guard FileManager.default.fileExists(atPath: file.path) else {
                items.append(CheckItem(level: .error, text: "Image not found: \(ref.path)"))
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
            items.append(CheckItem(level: .ok, text: "\(imagePaths.count) new image\(imagePaths.count == 1 ? "" : "s") (\(size))"))
        }
        if withLocation > 0 {
            items.append(CheckItem(level: .warning, text: "\(withLocation) image\(withLocation == 1 ? " still has" : "s still have") location data."))
        }
        if !large.isEmpty {
            items.append(CheckItem(level: .warning, text: "Over 1 MB, slow on phones: \(large.joined(separator: ", "))"))
        }
        if missingAlt > 0 {
            items.append(CheckItem(level: .warning, text: "\(missingAlt) image\(missingAlt == 1 ? " is" : "s are") missing alt text"))
        }
        let address = SiteHealth.normalized(document.url)
        if let twin = site.documents.first(where: { $0.relativePath != document.relativePath && $0.publishedFlag && SiteHealth.normalized($0.url) == address }) {
            items.append(CheckItem(level: .error, text: "\(twin.relativePath) already uses the address \(document.url)."))
        }
        let title = doc.value("title")?.string ?? ""
        let fullTitle = site.config.title.isEmpty ? title : "\(title) | \(site.config.title)"
        if fullTitle.count > 60 {
            items.append(CheckItem(level: .info, text: "Search results show about 60 characters of the title; this one has \(fullTitle.count)."))
        }
        let broken = brokenInternalLinks(doc.body, site: site)
        if broken.isEmpty {
            items.append(CheckItem(level: .ok, text: "No broken links"))
        } else {
            for link in broken { items.append(CheckItem(level: .warning, text: "Link goes nowhere on the site: \(link)")) }
        }
        if let date = doc.value("date")?.string.flatMap({ SiteDate.parse($0, timeZone: site.config.timeZone) }) ?? document.date,
           Schedule.isScheduled(date) {
            if Schedule.publishesFutureNow(site.config) {
                items.append(CheckItem(level: .warning, text: "The date is in the future, but future: true in _config.yml shows it right away."))
            } else {
                scheduledFor = date
                let when = date.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: site.config.timeZone))
                items.append(CheckItem(level: .info, text: "Scheduled: the post stays off the site until \(when)."))
                if !Schedule.hasWorkflow(siteRoot: site.root) { addScheduleWorkflow = true }
            }
        }
        if let repo = backend.repository {
            items.append(CheckItem(level: .info, text: "Goes to \(repo.owner)/\(repo.name); GitHub Pages then rebuilds the site."))
        }
        checks = items
        paths = [document.relativePath] + imagePaths
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
        } catch {
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
