import Foundation

/// Reading a site file as text without changing it: `String(contentsOf:encoding:)` drops a leading byte order mark,
/// which would then be lost on the next save. Invalid UTF-8 is still refused, so a file is never saved back damaged.
public enum TextFile {
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
