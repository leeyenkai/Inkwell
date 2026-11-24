import Foundation

/// Text shown to people, looked up in this module's string catalog.
func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .module)
}
