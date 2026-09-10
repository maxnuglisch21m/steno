import Foundation
import StenoCore

/// Appends to `screens.jsonl`, one line per image, the moment the image is written.
///
/// Not assembled at the end and not buffered: the specification (§4) asks for the line
/// to be appended on save, and that is what makes an interrupted recording leave an
/// index for every file it managed to write. Each append is followed by a
/// `synchronize()`, so a kill between two frames loses at most the line being written
/// — which `ScreensIndexEntry.decode(jsonl:lenient:)` is built to skip.
///
/// Only ever touched from the capture queue. `ScreenshotCapturer` owns it and is the
/// single caller; it is a class rather than a struct so the file handle and the count
/// survive the closure that writes them.
final class ScreensIndexWriter: @unchecked Sendable {
    /// `screens.jsonl`, relative to the meeting folder.
    static let fileName = "screens.jsonl"

    private let url: URL
    /// The zone `at` is written in — the same one `meta.json`'s timestamps use, so a
    /// reader does not have to reconcile two offsets within one folder.
    private let timeZone: TimeZone
    private var handle: FileHandle?
    private(set) var lineCount = 0
    /// Set once, so a broken index does not fill the log with one line per frame.
    private var hasReportedFailure = false

    init(folder: URL, timeZone: TimeZone = .current) {
        self.url = folder.appendingPathComponent(Self.fileName)
        self.timeZone = timeZone
    }

    /// Appends one entry. Failures are logged once and otherwise swallowed: a
    /// screenshot index that cannot be written is not a reason to lose the audio.
    func append(_ entry: ScreensIndexEntry) {
        do {
            let handle = try openIfNeeded()
            try handle.write(contentsOf: entry.jsonLineData(timeZone: timeZone))
            // Cheap for a few hundred bytes, and it is what makes the file worth
            // reading after a crash rather than after a clean stop.
            try handle.synchronize()
            lineCount += 1
        } catch {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            Log.screens.error(
                "screens.jsonl could not be written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Closes the file. Idempotent.
    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    private func openIfNeeded() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.stenoPath) {
            fileManager.createFile(atPath: url.stenoPath, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        // Appending rather than truncating: a recovery pass in M6 may reopen a folder
        // whose index already has lines in it.
        try opened.seekToEnd()
        handle = opened
        return opened
    }
}
