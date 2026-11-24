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

/// Follows the GitHub Pages build for a pushed commit. Pages builds run as the "pages build and deployment" workflow
/// (or a site's own Pages workflow). Short-lived errors do not end the watch; only a result or the timeout does.
public struct BuildWatcher: Sendable {
    public var client: GitHubClient
    public var owner: String
    public var repository: String

    public init(client: GitHubClient, owner: String, repository: String) {
        self.client = client
        self.owner = owner
        self.repository = repository
    }

    public func state(forCommit sha: String) async throws -> PagesBuildState {
        let runs = try await client.workflowRuns(owner, repository, headSHA: sha)
        guard let run = runs.first(where: { ($0.name ?? "").lowercased().contains("pages") }) else { return .waiting }
        switch (run.status, run.conclusion) {
        case ("completed", "success"): return .live
        case let ("completed", conclusion): return .failed(conclusion ?? "failed")
        default: return .building
        }
    }

    public func watch(commit sha: String, interval: Duration = .seconds(8), timeout: Duration = .seconds(900),
                      onChange: @Sendable (PagesBuildState) async -> Void) async -> PagesBuildState {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last: PagesBuildState?
        var failures = 0
        while clock.now < deadline, !Task.isCancelled {
            do {
                let state = try await state(forCommit: sha)
                failures = 0
                if state != last {
                    await onChange(state)
                    last = state
                }
                if state.isFinished { return state }
            } catch {
                failures += 1
                if failures >= 5 {
                    let state = PagesBuildState.unknown(error.localizedDescription)
                    await onChange(state)
                    return state
                }
            }
            try? await Task.sleep(for: interval)
        }
        return last ?? .unknown(localized("The build did not report back in time."))
    }
}
