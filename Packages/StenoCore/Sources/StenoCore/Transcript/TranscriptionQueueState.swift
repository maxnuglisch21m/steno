import Foundation

/// The transcription queue as it is written down, so that a relaunch knows what was
/// still owed.
///
/// Transcription runs one meeting at a time and can take longer than the app stays
/// open — a quit, a crash, or a restart in the middle of an hour-long recording must
/// not lose the folder. So the queue is a list of paths that survives the process, and
/// the recovery pass on the next launch (M6) reads exactly this.
///
/// Paths rather than bookmarks: a meeting folder the user moved is a folder Steno has
/// no business chasing, and a stale path is dropped when it turns out not to exist.
public struct TranscriptionQueueState: Codable, Sendable, Equatable {
    /// One meeting waiting for, or in the middle of, transcription.
    public struct Entry: Codable, Sendable, Equatable, Hashable {
        /// Absolute path of the meeting folder.
        public var path: String
        /// How many times transcription has been started for it.
        ///
        /// Counted rather than merely flagged so that a folder whose transcription
        /// crashes the app cannot put the app into a relaunch loop: past
        /// `maxAttempts` it is marked `failed` and left alone.
        public var attempts: Int

        public init(path: String, attempts: Int = 0) {
            self.path = path
            self.attempts = attempts
        }
    }

    /// After this many starts a folder is given up on and marked `failed`.
    public static let maxAttempts = 3

    /// In the order they will be worked through. The first is the one running.
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static let empty = TranscriptionQueueState()

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var paths: [String] { entries.map(\.path) }

    /// The entry that should be worked on next, without removing it.
    public var head: Entry? { entries.first }

    public func contains(_ path: String) -> Bool {
        entries.contains { $0.path == path }
    }

    /// Appends a folder, unless it is already queued.
    ///
    /// - Returns: whether it was added. A folder enqueued twice — the recovery pass
    ///   finding what the coordinator has just handed over — is one folder.
    @discardableResult
    public mutating func enqueue(_ path: String) -> Bool {
        guard !contains(path) else { return false }
        entries.append(Entry(path: path))
        return true
    }

    /// Records that work on the head has begun, and answers whether it may.
    ///
    /// - Returns: the entry with its attempt counted, or `nil` when it has used up its
    ///   attempts — in which case it has already been removed and the caller marks the
    ///   folder `failed`.
    @discardableResult
    public mutating func beginHead() -> Entry? {
        guard var entry = entries.first else { return nil }
        entry.attempts += 1
        if entry.attempts > Self.maxAttempts {
            entries.removeFirst()
            return nil
        }
        entries[0] = entry
        return entry
    }

    /// Gives the head its attempt back, for a run that never really started.
    ///
    /// An attempt is meant to count a try at *this folder*: three failures and it is
    /// given up on, which is what stops a folder that crashes the app from putting the
    /// app into a relaunch loop. A run that stopped because the models are not on the
    /// Mac yet tried nothing about the folder, and counting it would use the folder's
    /// three attempts up on a Mac where no attempt was ever possible.
    ///
    /// - Returns: whether `path` was the head and had an attempt to give back.
    @discardableResult
    public mutating func refundHead(_ path: String) -> Bool {
        guard var entry = entries.first, entry.path == path, entry.attempts > 0 else {
            return false
        }
        entry.attempts -= 1
        entries[0] = entry
        return true
    }

    /// Takes a folder out of the queue, wherever it is.
    @discardableResult
    public mutating func remove(_ path: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.path == path }
        return entries.count != before
    }

    /// Drops every folder that is no longer on disk.
    public mutating func removeMissing(_ exists: (String) -> Bool) {
        entries.removeAll { !exists($0.path) }
    }

    // MARK: - Coding

    public static func decode(from data: Data) throws -> TranscriptionQueueState {
        try JSONDecoder().decode(TranscriptionQueueState.self, from: data)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
