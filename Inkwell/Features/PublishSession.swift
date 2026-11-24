import Foundation
import InkwellKit
import Observation

struct CheckItem: Identifiable {
    enum Level { case ok, warning, error, info }

    let id = UUID()
    var level: Level
    var text: String
}

/// One publish or update: the checklist shown before it, then commit, push and the Pages build.
@Observable
final class PublishSession: Identifiable {
    enum Phase: Equatable {
        case ready
        case publishing
        case building(PagesBuildState)
        case live
        case pushed
        case committedOnly
        case failed(String)
    }

    let id = UUID()
    let document: SiteDocument
    let text: String
    let site: Site
    let isUpdate: Bool
    var message: String
    private(set) var checks: [CheckItem] = []
    private(set) var paths: [String] = []
    private(set) var phase: Phase = .ready
    private(set) var liveURL: URL?
    private weak var model: AppModel?

    init(document: SiteDocument, text: String, site: Site, model: AppModel) {
        self.document = document
        self.text = text
        self.site = site
        self.model = model
        isUpdate = document.origin == .repository && model.status(of: document) == .edited
        let title = FrontMatterDocument(text: text).value("title")?.string ?? document.title
        message = "\(isUpdate ? "Update" : "Publish"): \(title.isEmpty ? "Untitled" : title)"
        liveURL = model.liveURL(for: document)
        buildChecklist(status: model.gitStatus)
    }

    var hasErrors: Bool { checks.contains { $0.level == .error } }
    var displayURL: String { Permalink.display(document.url, config: site.config) }

    private func buildChecklist(status: [String: FileStatus]) {
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
        for ref in ContentChecks.images(in: doc.body) where ref.path.hasPrefix("/") {
            let relative = String(ref.path.dropFirst())
            let file = site.root.appending(path: relative)
            if ref.alt.trimmingCharacters(in: .whitespaces).isEmpty { missingAlt += 1 }
            guard FileManager.default.fileExists(atPath: file.path) else {
                items.append(CheckItem(level: .error, text: "Image not found: \(ref.path)"))
                continue
            }
            if [.untracked, .modified, .added].contains(status[relative]), !imagePaths.contains(relative) {
                imagePaths.append(relative)
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
        if missingAlt > 0 {
            items.append(CheckItem(level: .warning, text: "\(missingAlt) image\(missingAlt == 1 ? " is" : "s are") missing alt text"))
        }

        let broken = brokenInternalLinks(doc.body)
        if broken.isEmpty {
            items.append(CheckItem(level: .ok, text: "No broken links"))
        } else {
            for link in broken { items.append(CheckItem(level: .warning, text: "Link goes nowhere on the site: \(link)")) }
        }
        let repo = model?.remote.flatMap(Git.gitHubRepository)
        if let repo {
            items.append(CheckItem(level: .info, text: "Commits to \(repo.owner)/\(repo.name), then GitHub Pages rebuilds the site."))
        } else if model?.remote == nil {
            items.append(CheckItem(level: .info, text: "This site has no remote, so the change is committed here only."))
        }
        checks = items
        paths = [document.relativePath] + imagePaths
    }

    private func brokenInternalLinks(_ body: String) -> [String] {
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

    func publish() async {
        guard let git = Git(root: site.root) else {
            phase = .failed("git was not found on this Mac. Install the Xcode command line tools and try again.")
            return
        }
        phase = .publishing
        let target = site.root.appending(path: document.relativePath)
        var wroteDraft = false
        do {
            if document.origin == .localDraft {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .withoutOverwriting)
                wroteDraft = true
            }
            let result = try await git.publish(paths: paths, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            if document.origin == .localDraft { try? FileManager.default.removeItem(at: document.fileURL) }
            model?.adoptPublished(relativePath: document.relativePath)
            guard result.pushed else {
                phase = .committedOnly
                return
            }
            guard let remote = await git.remoteURL(), let repo = Git.gitHubRepository(from: remote) else {
                phase = .pushed
                return
            }
            phase = .building(.waiting)
            let status = PagesStatus(owner: repo.owner, repository: repo.name)
            let final = await status.watch(commit: result.commit) { [weak self] state in
                await self?.update(state)
            }
            phase = final == .live ? .live : .building(final)
        } catch {
            if wroteDraft, (try? await git.status())?[document.relativePath] == .untracked {
                try? FileManager.default.removeItem(at: target)
            }
            phase = .failed(error.localizedDescription)
        }
    }

    private func update(_ state: PagesBuildState) {
        phase = state == .live ? .live : .building(state)
    }
}
