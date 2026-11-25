import Foundation
import InkwellCore

public extension Schedule {
    /// `_config.yml` with `future: false` added, so GitHub Pages keeps posts dated in the future off the site until their
    /// date. Nil when the file already sets `future:` either way. Only the new line changes.
    static func configHoldingFuturePosts(_ text: String) -> String? {
        if text.isEmpty { return "future: false\n" }
        var config = ConfigDocument(text: text)
        guard config.value("future") == nil else { return nil }
        config.set("future", raw: "false")
        return config.text
    }
}
