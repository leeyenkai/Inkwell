import Foundation
import InkwellKit

extension AppModel {
    enum ExternalCheck: Equatable {
        case never, checking(done: Int, of: Int), checked(Date)
    }

    var healthIssues: [SiteHealth.Issue] { (health?.issues ?? []) + externalLinkIssues }
    var healthProblems: Int { healthIssues.filter { $0.severity > .info }.count }

    func refreshHealth() {
        guard let site else { return }
        Task {
            health = await Task.detached { SiteHealth.check(site) }.value
        }
    }

    /// Applies a fix's file changes; they show up as unpublished changes to review and publish.
    func applyFix(_ issue: SiteHealth.Issue) {
        guard let site, case let .edits(edits, _)? = issue.fix else { return }
        do {
            for edit in edits { try edit.apply(to: site.root) }
        } catch {
            errorMessage = String(localized: "The fix could not be applied: \(error.localizedDescription)")
        }
        selectedIssueID = nil
        design?.reload()
        reloadSite()
    }

    func openDocument(path: String) {
        guard let doc = allDocuments.first(where: { $0.relativePath == path }) else { return }
        if site?.section(doc.sectionID) != nil { sidebarSelection = .section(doc.sectionID) } else { sidebarSelection = .drafts }
        if doc.sectionID == PhotoStream.collection, photosSetUp { selectedPhotoID = doc.id } else { select(doc.id) }
    }

    /// Asks every site the posts link to whether the page is still there. Only a definite "gone" (404, 410, or a
    /// name that no longer resolves) counts; slow or blocked sites are left alone.
    func checkExternalLinks() {
        guard let site else { return }
        Task {
            let links = await Task.detached { SiteHealth.externalLinks(site) }.value
            let urls = Array(links.keys).sorted()
            externalCheck = .checking(done: 0, of: urls.count)
            var dead: [String] = []
            let session = URLSession(configuration: .ephemeral)
            await withTaskGroup(of: (String, Bool).self) { group in
                var next = 0
                func add() {
                    guard next < urls.count else { return }
                    let url = urls[next]
                    next += 1
                    group.addTask { (url, await Self.isGone(url, session: session)) }
                }
                for _ in 0 ..< 8 { add() }
                var done = 0
                for await (url, gone) in group {
                    if gone { dead.append(url) }
                    done += 1
                    externalCheck = .checking(done: done, of: urls.count)
                    add()
                }
            }
            var byDoc: [String: [String]] = [:]
            for url in dead { for path in links[url] ?? [] { byDoc[path, default: []].append(url) } }
            externalLinkIssues = byDoc.keys.sorted().map { path in
                let title = site.documents.first { $0.relativePath == path }?.title ?? path
                let urls = byDoc[path, default: []].sorted()
                return SiteHealth.Issue(id: "external:\(path)", category: .links, severity: .warning,
                                        title: String(localized: "\(urls.count) links to other sites in “\(title)” no longer work"),
                                        detail: urls.joined(separator: "\n"), paths: [path], fix: nil)
            }
            externalCheck = .checked(Date())
        }
    }

    nonisolated static func isGone(_ address: String, session: URLSession) async -> Bool {
        guard let url = URL(string: address) else { return false }
        for method in ["HEAD", "GET"] {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.httpMethod = method
            request.setValue("Mozilla/5.0 (Macintosh) Inkwell link check", forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status < 400 { return false }
                // Some sites refuse HEAD; a GET decides.
                if method == "GET" { return [404, 410].contains(status) }
            } catch let error as URLError where [.cannotFindHost, .dnsLookupFailed].contains(error.code) {
                return true
            } catch {
                return false
            }
        }
        return false
    }
}
