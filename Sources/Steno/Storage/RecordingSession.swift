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

    /// Creates the folder and writes the first `meta.json`.
    init(folder: URL, meta: MeetingMeta, fileManager: FileManager = .default) throws {
        self.folder = folder
        self.meta = meta
        self.fileManager = fileManager
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeMeta()
        Log.storage.info("recording folder created: \(folder.lastPathComponent, privacy: .public)")
    }

    /// Opens an existing folder, for the crash recovery scan in M6.
    init(existing folder: URL, fileManager: FileManager = .default) throws {
        self.folder = folder
        self.fileManager = fileManager
        let data = try Data(contentsOf: folder.appendingPathComponent(RecordingStore.metaFileName))
        self.meta = try MeetingMeta.decode(from: data)
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
