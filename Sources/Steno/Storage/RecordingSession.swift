import Foundation
import StenoCore

/// One meeting folder and the `meta.json` inside it.
///
/// `meta.json` is rewritten on every state change rather than once at the end. That
/// is the whole point of the `state` field: a folder still reading `recording` after a
/// launch was interrupted mid-recording, and one reading `transcribing` needs to be
/// queued again (specification §6). Writing it costs a few hundred bytes.
@MainActor
final class RecordingSession {
    let folder: URL
    private(set) var meta: MeetingMeta

    private let fileManager: FileManager

    var metaURL: URL { folder.appendingPathComponent(RecordingStore.metaFileName) }

    /// Creates the folder, writes the first `meta.json`, and claims the folder with a
    /// `.steno-lock` naming this process.
    ///
    /// The lock is what lets a second Steno — the user's own copy next to one being
    /// tested — tell a live recording apart from a crashed one at launch, instead of
    /// repairing a WAV that is still being written to. It is removed by
    /// `releaseLock()` when the folder is finished.
    init(folder: URL, meta: MeetingMeta, fileManager: FileManager = .default) throws {
        self.folder = folder
        self.meta = meta
        self.fileManager = fileManager
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeMeta()
        MeetingLock.write(.current(app: meta.app), in: folder)
        Log.storage.info("recording folder created: \(folder.lastPathComponent, privacy: .public)")
    }

    /// Opens an existing folder, for the crash recovery scan (M6) and the transcription
    /// queue. Writes no lock: neither of them is recording.
    init(existing folder: URL, fileManager: FileManager = .default) throws {
        self.folder = folder
        self.fileManager = fileManager
        let data = try Data(contentsOf: folder.appendingPathComponent(RecordingStore.metaFileName))
        self.meta = try MeetingMeta.decode(from: data)
    }

    /// Gives up the claim on the folder. Idempotent.
    ///
    /// Called once capture has ended, whatever the outcome — a folder past `recording`
    /// is nothing the recovery scan would touch anyway, so the lock has done its job by
    /// then and leaving it would only make the folder look owned to a reader.
    func releaseLock() {
        MeetingLock.remove(in: folder)
    }

    /// Mutates the metadata and writes it out. Both or neither: a failed write leaves
    /// the in-memory value alone, so a retry writes something consistent.
    func update(_ mutate: (inout MeetingMeta) throws -> Void) throws {
        var candidate = meta
        try mutate(&candidate)
        let previous = meta
        meta = candidate
        do {
            try writeMeta()
        } catch {
            meta = previous
            throw error
        }
    }

    /// Writes the meeting's name into `meta.json`, and only there.
    ///
    /// The folder was named when the recording started, and the title search that
    /// feeds this runs beside the suggestion rather than in front of it — so a title
    /// routinely arrives seconds after the first audio frame. **The folder is not
    /// renamed**: the WAV is open inside it, the screenshot capturer and the index
    /// hold URLs into it, and a rename mid-recording would break all three to gain a
    /// prettier path. `meta.title` is the field a reader downstream looks at anyway.
    ///
    /// A title already known wins: the one written when the folder was created came
    /// from the same search, only earlier.
    func setTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, meta.title == nil else { return }
        do {
            try update { $0.title = trimmed }
            Log.storage.info(
                "\(self.folder.lastPathComponent, privacy: .public): meeting title recorded in meta.json"
            )
        } catch {
            Log.storage.error(
                "could not record the meeting title: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Advances `state` and writes.
    func transition(to next: MeetingState) throws {
        try update { try $0.transition(to: next) }
        Log.storage.info(
            "\(self.folder.lastPathComponent, privacy: .public) → \(next.rawValue, privacy: .public)"
        )
    }

    /// Records the reason a recording failed, and writes.
    func fail(reason: String) {
        do {
            try update { try $0.fail(reason: reason) }
        } catch {
            Log.storage.error("could not record failure in meta.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeMeta() throws {
        let data = try meta.jsonData()
        // Atomic: a crash between two writes must not leave a half-written meta.json,
        // which would look exactly like a folder with no metadata at all.
        try data.write(to: metaURL, options: .atomic)
    }
}
