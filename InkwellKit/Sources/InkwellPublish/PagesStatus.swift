import Foundation

public enum PagesBuildState: Sendable, Equatable {
    case waiting
    case building
    case live
    case failed(String)
    case unknown(String)

    public var isFinished: Bool {
        switch self {
        case .live, .failed, .unknown: true
        default: false
        }
    }
}

/// Watches the GitHub Pages build for a commit. Pages builds run as the `pages-build-deployment` workflow, whose runs
/// are public for a public repository, so no sign-in is needed. A token, when given, raises the rate limit.
public struct PagesStatus: Sendable {
    public var owner: String
    public var repository: String
    public var token: String?
    var session: URLSession

    public init(owner: String, repository: String, token: String? = nil, session: URLSession = .shared) {
        self.owner = owner
        self.repository = repository
        self.token = token
        self.session = session
    }

    struct Runs: Decodable {
        struct Run: Decodable {
            var name: String?
            var status: String
            var conclusion: String?
            var html_url: String?
        }

        var workflow_runs: [Run]
    }

    public func state(forCommit sha: String) async -> PagesBuildState {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repository)/actions/runs")
        components?.queryItems = [URLQueryItem(name: "head_sha", value: sha), URLQueryItem(name: "per_page", value: "10")]
        guard let url = components?.url else { return .unknown("Bad repository name.") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Inkwell", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unknown("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            let runs = try JSONDecoder().decode(Runs.self, from: data).workflow_runs
            let pages = runs.first { ($0.name ?? "").contains("pages") } ?? runs.first
            guard let run = pages else { return .waiting }
            switch (run.status, run.conclusion) {
            case ("completed", "success"): return .live
            case let ("completed", conclusion): return .failed(conclusion ?? "failed")
            default: return .building
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Polls until the build finishes or `timeout` passes, reporting each change.
    public func watch(commit sha: String, interval: Duration = .seconds(5), timeout: Duration = .seconds(600),
                      onChange: @Sendable (PagesBuildState) async -> Void) async -> PagesBuildState {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last: PagesBuildState?
        while clock.now < deadline {
            let state = await state(forCommit: sha)
            if state != last {
                await onChange(state)
                last = state
            }
            if state.isFinished { return state }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
        }
        return last ?? .waiting
    }
}
