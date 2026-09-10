import Foundation

/// What a `.steno-lock` in a meeting folder says about who owns it.
///
/// A recording session writes the lock when it creates the folder and removes it when
/// the folder is finished, so a lock that is still there is either a live recording or
/// the fingerprint of one that died. Telling those apart is the whole point of the
/// file: without it, a second Steno launched while the first is recording would see
/// `state: recording` and "repair" a file that is still being written to.
public enum RecoveryLock: Sendable, Hashable {
    /// No lock file, or one that could not be read.
    case absent
    /// A lock whose process is still running. Somebody owns this folder.
    case alive(pid: Int32)
    /// A lock whose process is gone. What a crash leaves behind.
    case stale(pid: Int32)
    /// A lock naming this very process.
    ///
    /// Kept apart from `alive` because the two mean opposite things to the caller: a
    /// folder locked by somebody else is off limits, and a folder locked by us is one
    /// we are recording into right now and equally off limits — but only one of the two
    /// is worth a line in the log.
    case ours(pid: Int32)

    public var pid: Int32? {
        switch self {
        case .absent: return nil
        case .alive(let pid), .stale(let pid), .ours(let pid): return pid
        }
    }

    /// Whether some running process claims the folder.
    public var isHeld: Bool {
        switch self {
        case .alive, .ours: return true
        case .absent, .stale: return false
        }
    }
}

/// Everything the recovery pass knows about one meeting folder, with no file system in
/// sight.
public struct RecoveryInput: Sendable, Hashable {
    /// What `meta.json` says.
    public var state: MeetingState
    /// Seconds since the newest file in the folder was written.
    ///
    /// Not the folder's own creation time: what matters is whether anything is still
    /// writing into it, and a recording that started an hour ago is writing right now.
    public var age: TimeInterval
    public var lock: RecoveryLock
    /// Whether `audio.wav` exists at all.
    public var hasAudio: Bool
    /// Whole audio frames the file holds, from its length rather than its header.
    ///
    /// Zero means header-only or empty: a recording that died before the first buffer
    /// reached the disk, which has nothing to transcribe.
    public var audioFrameCount: Int
    /// Whether the persisted transcription queue already lists this folder.
    public var isQueued: Bool
    /// How many times transcription has already been started for it.
    public var attempts: Int

    public init(
        state: MeetingState,
        age: TimeInterval,
        lock: RecoveryLock = .absent,
        hasAudio: Bool = false,
        audioFrameCount: Int = 0,
        isQueued: Bool = false,
        attempts: Int = 0
    ) {
        self.state = state
        self.age = age
        self.lock = lock
        self.hasAudio = hasAudio
        self.audioFrameCount = audioFrameCount
        self.isQueued = isQueued
        self.attempts = attempts
    }
}

/// What the recovery pass should do with one folder.
public enum RecoveryDecision: Sendable, Hashable {
    /// Leave it alone, for the reason given.
    case skip(Reason)
    /// A crash mid-recording with audio worth keeping: repair the WAV header, finish
    /// `meta.json` with `stopReason: crash`, move it to `transcribing`, and queue it.
    case finishInterruptedRecording
    /// A crash mid-recording that captured nothing: mark it `failed`.
    case failWithoutAudio
    /// It already says `transcribing` but the queue has forgotten it: queue it again.
    case requeue
    /// It has used up its attempts: mark it `failed` and stop relaunching into it.
    case giveUp

    public enum Reason: Sendable, Hashable {
        /// Younger than `RecoveryPolicy.minimumAge` — possibly still being written.
        case tooYoung(age: TimeInterval)
        /// A live process owns the folder.
        case locked(pid: Int32)
        /// Nothing to recover: `done` or `failed`.
        case settled(MeetingState)
        /// `transcribing`, and the queue already has it. It will be picked up by
        /// `TranscriptionQueue.resumePersisted()` rather than by this pass.
        case alreadyQueued
    }

    /// Whether acting on this decision changes anything on disk.
    public var isAction: Bool {
        if case .skip = self { return false }
        return true
    }
}

/// The decision table the launch-time recovery scan runs on.
///
/// Specification §6 and §10 (M6): the `state` in `meta.json` is written continuously so
/// that a crash is detectable, and a folder left mid-flight is finished on the next
/// launch. The awkward part is not the repair, it is deciding which folders may be
/// touched at all — a Mac can run two Stenos, a folder can be seconds old and still
/// growing, and a folder that failed three times must not be retried for ever. All of
/// that is arithmetic over facts, so it lives here where it can be a table in a test
/// rather than a sequence of file-system calls.
public enum RecoveryPolicy {
    /// How recent a folder may be and still be left alone.
    ///
    /// Ten seconds is longer than the gap between two `meta.json` writes and longer
    /// than the gap between two screenshots at the fastest configured interval, so a
    /// folder a live recording owns is always inside it — and it is short enough that a
    /// crash a moment before the relaunch is still recovered on the next launch rather
    /// than never.
    ///
    /// The lock file is the real defence; this is the belt to its braces, for a folder
    /// written by a build old enough not to have written a lock at all.
    public static let minimumAge: TimeInterval = 10

    public static func decide(
        _ input: RecoveryInput,
        maxAttempts: Int = TranscriptionQueueState.maxAttempts
    ) -> RecoveryDecision {
        // A settled folder is checked first and unconditionally: `done` is the end of
        // the lifecycle and `failed` waits for the user's "erneut verarbeiten", so
        // neither an age nor a lock says anything worth acting on about them.
        guard input.state.needsRecovery else {
            return .skip(.settled(input.state))
        }

        if input.lock.isHeld, let pid = input.lock.pid {
            return .skip(.locked(pid: pid))
        }

        if input.age < minimumAge {
            return .skip(.tooYoung(age: input.age))
        }

        switch input.state {
        case .recording:
            // The attempt count is not consulted here. A folder still saying
            // `recording` has never been transcribed — whatever attempts the queue
            // remembers belong to an earlier trip through `transcribing`, which it
            // cannot have taken without leaving that state behind.
            guard input.hasAudio, input.audioFrameCount > 0 else {
                return .failWithoutAudio
            }
            return .finishInterruptedRecording

        case .transcribing:
            if input.attempts >= maxAttempts {
                return .giveUp
            }
            return input.isQueued ? .skip(.alreadyQueued) : .requeue

        case .done, .failed:
            // Unreachable: `needsRecovery` is false for both.
            return .skip(.settled(input.state))
        }
    }
}
