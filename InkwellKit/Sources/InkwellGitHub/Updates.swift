import Foundation

/// A published version of Inkwell, read from the latest GitHub release of the releases repository.
public struct ReleaseInfo: Sendable, Equatable, Decodable {
    public struct Asset: Sendable, Equatable, Decodable {
        public var name: String
        public var browser_download_url: URL
    }

    public var tag_name: String
    public var name: String?
    public var body: String?
    public var html_url: URL
    public var assets: [Asset]

    public init(tag: String, name: String? = nil, notes: String? = nil, page: URL, assets: [Asset] = []) {
        tag_name = tag
        self.name = name
        body = notes
        html_url = page
        self.assets = assets
    }

    /// "v1.2.0" → "1.2.0".
    public var version: String { tag_name.hasPrefix("v") || tag_name.hasPrefix("V") ? String(tag_name.dropFirst()) : tag_name }
    public var notes: String { body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    /// The disk image to download, or the release page when there is none.
    public var download: URL { assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url ?? html_url }
}

/// Asks GitHub whether a newer Inkwell is out. Unsigned builds cannot replace themselves safely, so a newer
/// version is offered as a download. The request carries no account, site or device details.
public enum UpdateCheck {
    public static func feed(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// The latest release, or nil when the repository has none or cannot be seen (a private repository answers 404).
    public static func latest(feed: URL, session: URLSession = .shared) async throws -> ReleaseInfo? {
        var request = URLRequest(url: feed)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Inkwell", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw GitHubError.http(status: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
        }
        do {
            return try JSONDecoder().decode(ReleaseInfo.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    /// Compares dotted versions numerically ("0.10" is newer than "0.9"). A version with a suffix such as "-beta.2"
    /// comes before the same version without one.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> (numbers: [Int], suffix: String) {
            let trimmed = v.hasPrefix("v") || v.hasPrefix("V") ? String(v.dropFirst()) : v
            let split = trimmed.split(separator: "-", maxSplits: 1)
            let numbers = (split.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, split.count > 1 ? String(split[1]) : "")
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0 ..< max(x.numbers.count, y.numbers.count) {
            let l = i < x.numbers.count ? x.numbers[i] : 0, r = i < y.numbers.count ? y.numbers[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        switch (x.suffix.isEmpty, y.suffix.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): return x.suffix.compare(y.suffix, options: .numeric)
        }
    }
}
