import Foundation

/// How much room is left where the recordings go.
///
/// A 48 kHz 16-bit two-channel WAV is about 690 MB an hour, and a screenshot-heavy
/// meeting adds to that, so an hour-long recording started on a nearly full disk ends
/// as a truncated file — the one failure mode where the data is gone rather than
/// merely late. Steno refuses to start below `refuseBelow` and says so below
/// `warnBelow`.
enum DiskSpace {
    /// Below this, a recording is refused outright.
    static let refuseBelow: Int64 = 500 * 1_000_000
    /// Below this, the recording starts but the menu says space is short.
    static let warnBelow: Int64 = 2 * 1_000_000_000

    enum Level: Sendable, Equatable {
        /// Enough room for a long meeting.
        case fine
        /// Enough to start, not enough to be comfortable.
        case low
        /// Not enough to start.
        case critical
        /// The volume did not answer. Treated as `fine`: refusing to record because a
        /// capacity query failed would be the worse mistake.
        case unknown
    }

    /// Bytes available for something the user would mind losing.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` is the right key here rather than
    /// `volumeAvailableCapacity`: it is what the system is willing to free up by
    /// evicting purgeable caches, which is the number that decides whether a long
    /// write actually succeeds.
    /// How long an answer is reused before the volume is asked again.
    ///
    /// The query is not cheap — the system has to work out how much it could free by
    /// evicting purgeable files, which takes hundreds of milliseconds — and the menu
    /// asks `canStart` on every redraw. A few seconds of staleness cannot turn a
    /// half-full disk into a full one, and it keeps a slow volume query off the main
    /// actor's critical path.
    static let cacheLifetime: TimeInterval = 15

    private struct CacheEntry {
        var bytes: Int64?
        var readAt: Date
    }

    /// Keyed by the directory the answer was read from.
    ///
    /// `nonisolated(unsafe)` because every access below is inside `cacheLock`; that
    /// lock, not the compiler, is what makes it safe, and the alternative — an actor —
    /// would force `canStart` to become asynchronous for a number that is allowed to
    /// be a few seconds old.
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]
    private static let cacheLock = NSLock()

    static func availableBytes(at url: URL) -> Int64? {
        guard let probe = nearestExistingDirectory(of: url) else { return nil }
        let key = probe.stenoPath

        cacheLock.lock()
        if let entry = cache[key], Date().timeIntervalSince(entry.readAt) < cacheLifetime {
            cacheLock.unlock()
            return entry.bytes
        }
        cacheLock.unlock()

        let bytes = read(from: probe)

        cacheLock.lock()
        cache[key] = CacheEntry(bytes: bytes, readAt: Date())
        cacheLock.unlock()
        return bytes
    }

    /// Asks the volume again, whatever the cache says. Used at the moment a recording
    /// actually starts, where the extra milliseconds are worth an accurate answer.
    static func availableBytesNow(at url: URL) -> Int64? {
        invalidateCache()
        return availableBytes(at: url)
    }

    static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    /// The URL may not exist yet — the recording folder is created after the check —
    /// so walk up to the nearest directory that does.
    private static func nearestExistingDirectory(of url: URL) -> URL? {
        var probe = url.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: probe.stenoPath) {
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent == probe { return nil }
            probe = parent
        }
        return probe
    }

    private static func read(from directory: URL) -> Int64? {
        do {
            let values = try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return Int64(important)
            }
        } catch {
            Log.storage.error("free-space query failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    static func level(at url: URL) -> Level {
        guard let bytes = availableBytes(at: url) else { return .unknown }
        if bytes < refuseBelow { return .critical }
        if bytes < warnBelow { return .low }
        return .fine
    }

    /// `1,2 GB`, in the user's locale and units.
    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
