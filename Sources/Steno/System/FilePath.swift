import Foundation

extension URL {
    /// The file-system path, without a trailing slash.
    ///
    /// `path(percentEncoded:)` keeps the trailing slash that `URL(fileURLWithPath:
    /// isDirectory: true)` puts there, which is right for a URL and wrong for
    /// everything Steno does with the string afterwards: it is shown in the settings
    /// window, stored in `UserDefaults`, and compared against other paths, and
    /// `/Users/me/Meetings/` and `/Users/me/Meetings` should not read as two folders.
    var stenoPath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
