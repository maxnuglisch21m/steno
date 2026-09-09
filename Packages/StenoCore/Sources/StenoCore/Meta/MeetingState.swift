import Foundation

/// The lifecycle of one recording, as written to `state` in `meta.json`.
///
/// The value is persisted continuously so a crash is detectable: a folder still
/// reading `recording` on the next launch was interrupted mid-recording and needs
/// its WAV header repaired before it can be processed, and one reading
/// `transcribing` needs to be queued again.
public enum MeetingState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Audio and screenshots are being captured.
    case recording
    /// Capture finished; ASR, diarization, and merging are running.
    case transcribing
    /// The transcript and the audio archive are written. Terminal.
    case done
    /// Something went wrong. `MeetingMeta.error` says what. May be retried.
    case failed

    /// Whether the recording has reached a state that needs no further work.
    public var isTerminal: Bool { self == .done }

    /// Whether a folder in this state needs to be picked up again after a launch.
    public var needsRecovery: Bool { self == .recording || self == .transcribing }

    /// The states reachable from this one.
    ///
    /// `failed` leads back to `transcribing` so an interrupted or failed run can be
    /// retried; `done` is final, because the source audio has been transcoded by then.
    public var allowedSuccessors: Set<MeetingState> {
        switch self {
        case .recording: return [.transcribing, .failed]
        case .transcribing: return [.done, .failed]
        case .done: return []
        case .failed: return [.transcribing]
        }
    }

    public func canTransition(to next: MeetingState) -> Bool {
        allowedSuccessors.contains(next)
    }

    /// Moves to `next`, or throws if that transition is not part of the lifecycle.
    ///
    /// A transition to the state already held throws as well: writing `meta.json`
    /// twice with the same state is a logic error, not a no-op worth hiding.
    public mutating func transition(to next: MeetingState) throws {
        guard canTransition(to: next) else {
            throw IllegalTransition(from: self, to: next)
        }
        self = next
    }

    /// Returns the state after transitioning, leaving the receiver untouched.
    public func transitioned(to next: MeetingState) throws -> MeetingState {
        var copy = self
        try copy.transition(to: next)
        return copy
    }

    public struct IllegalTransition: Error, Equatable, CustomStringConvertible {
        public let from: MeetingState
        public let to: MeetingState

        public init(from: MeetingState, to: MeetingState) {
            self.from = from
            self.to = to
        }

        public var description: String {
            "illegal meeting state transition: \(from.rawValue) → \(to.rawValue)"
        }
    }
}
