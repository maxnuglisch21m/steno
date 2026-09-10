import Darwin
import Foundation
import StenoCore

/// `.steno-lock`: which process is recording into this folder.
///
/// Written when a recording session creates the folder and removed when the folder is
/// finished, so a lock that is still there says one of two things:
///
/// - its process is running → a live recording, and nothing may touch the folder;
/// - its process is gone → the recording died, and the folder is the recovery pass's.
///
/// Without it the launch-time scan could not tell those apart, and two Stenos on one
/// Mac — the user's own copy and one being tested, which is exactly the situation this
/// was written in — would fight: the second would see `state: recording`, decide the
/// first had crashed, and rewrite the header of a WAV still being appended to.
///
/// The PID alone is not enough, because PIDs are reused: after a reboot the number in
/// a stale lock can belong to a completely unrelated process, and the folder would then
/// look owned for ever and never be recovered. So the process's own start time is
/// written alongside it and both have to match. That turns "is this PID alive" into "is
/// *this process* alive", which is the question actually being asked.
struct MeetingLock: Codable, Sendable, Equatable {
    /// The name inside the meeting folder. Hidden, because it is Steno's bookkeeping
    /// rather than part of the recording (`docs/FORMAT.md`).
    static let fileName = ".steno-lock"

    var pid: Int32
    /// When that process started, to the second. Guards against PID reuse.
    var processStarted: Date
    /// Steno's version, for a human reading the file after the fact.
    var app: String

    // MARK: - This process

    /// A lock describing the running process.
    static func current(app: String) -> MeetingLock {
        MeetingLock(
            pid: getpid(),
            processStarted: startTime(of: getpid()) ?? Date(),
            app: app
        )
    }

    /// Whether the process this lock names is still running.
    ///
    /// A PID that exists but started at a different time is a different process that
    /// inherited the number, which is a stale lock rather than a live one.
    var isAlive: Bool {
        guard let started = Self.startTime(of: pid) else { return false }
        // One second of tolerance: the recorded value has come through JSON and the
        // kernel's own timestamp has microsecond resolution.
        return abs(started.timeIntervalSince(processStarted)) < 1
    }

    /// How the recovery policy should read this lock.
    var status: RecoveryLock {
        if !isAlive { return .stale(pid: pid) }
        return pid == getpid() ? .ours(pid: pid) : .alive(pid: pid)
    }

    /// When a process started, or `nil` when there is no such process.
    ///
    /// `sysctl(KERN_PROC_PID)` rather than `kill(pid, 0)`: the signal probe answers
    /// "does this number exist", and the question here is "is this the same process".
    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
        // A zero-length answer means the PID is gone; sysctl reports success for it.
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(started.tv_sec)
                + TimeInterval(started.tv_usec) / 1_000_000
        )
    }

    // MARK: - The file

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// Writes the lock into a meeting folder. Failures are logged, never thrown: a
    /// recording that cannot be locked is still a recording worth making.
    static func write(_ lock: MeetingLock, in folder: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(lock).write(to: url(in: folder), options: .atomic)
        } catch {
            Log.storage.error(
                "could not write \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Reads the lock out of a meeting folder, or `nil` when there is none.
    ///
    /// An unreadable lock counts as no lock: a file Steno cannot parse is not a claim
    /// it should honour, and honouring it would strand the folder for ever.
    static func read(in folder: URL) -> MeetingLock? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let lock = try? decoder.decode(MeetingLock.self, from: data) else {
            Log.storage.notice(
                "\(folder.lastPathComponent, privacy: .public) has an unreadable \(fileName, privacy: .public)"
            )
            return nil
        }
        return lock
    }

    /// What the recovery policy should be told about a folder's lock.
    static func status(in folder: URL) -> RecoveryLock {
        read(in: folder)?.status ?? .absent
    }

    /// Removes the lock. Idempotent, and never throws: the folder is finished either
    /// way, and a lock left behind is recovered from — a `state` past `recording`
    /// makes the scanner leave the folder alone regardless.
    static func remove(in folder: URL) {
        let url = url(in: folder)
        guard FileManager.default.fileExists(atPath: url.stenoPath) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.storage.notice(
                "could not remove \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
