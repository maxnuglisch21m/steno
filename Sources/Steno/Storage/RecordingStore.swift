import AppKit
import Foundation
import StenoCore

/// The recording root: creating it, finding the newest meeting in it, and showing it
/// in the Finder.
///
/// Nothing here writes outside the root the user chose (specification §11.11). The
/// one documented exception in the whole app is the model cache under
/// `~/Library/Application Support/Steno/Models`, which belongs to `ModelManager`.
@MainActor
final class RecordingStore {
    enum Failure: LocalizedError {
        case rootNotWritable(URL, underlying: String)

        var errorDescription: String? {
            switch self {
            case .rootNotWritable(let url, let underlying):
                return String(
                    format: String(localized: "Der Ablageordner „%@“ ließ sich nicht anlegen: %@"),
                    url.stenoPath,
                    underlying
                )
            }
        }
    }

    /// The name of the metadata file inside every meeting folder.
    static let metaFileName = "meta.json"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - The root

    /// Creates the root folder if it is missing. Call at launch and whenever the
    /// setting changes.
    @discardableResult
    func ensureRootExists(_ root: URL) -> Result<URL, Failure> {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            Log.storage.debug("recording root ready at \(root.stenoPath, privacy: .public)")
            return .success(root)
        } catch {
            Log.storage.error("recording root unusable: \(error.localizedDescription, privacy: .public)")
            return .failure(.rootNotWritable(root, underlying: error.localizedDescription))
        }
    }

    // MARK: - Meeting folders

    /// Every meeting folder in the root, newest first.
    ///
    /// Only folders whose name Steno itself would have produced and which carry a
    /// `meta.json` count — anything else in the recording root is the user's business.
    func meetingFolders(in root: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates = entries.filter { url in
            guard RecordingFolderName.matches(url.lastPathComponent) else { return false }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { return false }
            return fileManager.fileExists(
                atPath: url.appendingPathComponent(Self.metaFileName).stenoPath
            )
        }

        // The name carries the start time to the minute, which is enough to order
        // them; two folders from the same minute are separated by the collision
        // suffix, so the name itself is the tiebreaker.
        return candidates.sorted { left, right in
            let leftDate = RecordingFolderName.startedDate(from: left.lastPathComponent)
            let rightDate = RecordingFolderName.startedDate(from: right.lastPathComponent)
            switch (leftDate, rightDate) {
            case let (l?, r?) where l != r: return l > r
            default: return left.lastPathComponent > right.lastPathComponent
            }
        }
    }

    /// The newest meeting folder that has a `meta.json`, or `nil` when there is none.
    func lastMeetingURL(in root: URL) -> URL? {
        meetingFolders(in: root).first
    }

    /// A free folder name for a recording that is about to start, and the URL it maps to.
    func meetingFolderURL(
        in root: URL,
        started: Date,
        mode: MeetingMode,
        appName: String?,
        title: String?
    ) -> URL {
        let name = RecordingFolderName.make(
            started: started,
            mode: mode,
            appName: appName,
            title: title,
            exists: { candidate in
                self.fileManager.fileExists(
                    atPath: root.appendingPathComponent(candidate).stenoPath
                )
            }
        )
        return root.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Finder

    /// Selects a folder in the Finder. Falls back to opening the root when the folder
    /// is gone — the user moved or deleted it, which is allowed.
    func revealInFinder(_ url: URL) {
        if fileManager.fileExists(atPath: url.stenoPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            Log.storage.notice("last meeting folder is gone, opening its parent instead")
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Opens the recording root, creating it first if it went missing.
    func openRootFolder(_ root: URL) {
        _ = ensureRootExists(root)
        NSWorkspace.shared.open(root)
    }
}
