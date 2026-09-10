import Foundation
import Testing

@testable import StenoCore

@Suite("RecoveryPolicy")
struct RecoveryPolicyTests {
    /// Old enough that the age rule never decides anything in these cases.
    static let old: TimeInterval = 3600

    // MARK: - The decision table

    /// One row per case the launch-time scan has to get right. Read as a table: this
    /// is the specification of M6's first paragraph.
    static let table: [(name: String, input: RecoveryInput, expected: RecoveryDecision)] = [
        (
            "recording with usable audio is finished and queued",
            RecoveryInput(state: .recording, age: Self.old, hasAudio: true, audioFrameCount: 48_000),
            .finishInterruptedRecording
        ),
        (
            "recording whose WAV is header-only fails",
            RecoveryInput(state: .recording, age: Self.old, hasAudio: true, audioFrameCount: 0),
            .failWithoutAudio
        ),
        (
            "recording with no WAV at all fails",
            RecoveryInput(state: .recording, age: Self.old, hasAudio: false),
            .failWithoutAudio
        ),
        (
            "transcribing that the queue has forgotten is queued again",
            RecoveryInput(state: .transcribing, age: Self.old, hasAudio: true, audioFrameCount: 48_000),
            .requeue
        ),
        (
            "transcribing that the queue still has is left to the queue",
            RecoveryInput(
                state: .transcribing,
                age: Self.old,
                hasAudio: true,
                audioFrameCount: 48_000,
                isQueued: true
            ),
            .skip(.alreadyQueued)
        ),
        (
            "transcribing that has used up its attempts is given up on",
            RecoveryInput(
                state: .transcribing,
                age: Self.old,
                hasAudio: true,
                audioFrameCount: 48_000,
                isQueued: true,
                attempts: TranscriptionQueueState.maxAttempts
            ),
            .giveUp
        ),
        (
            "failed is left alone for the manual retry",
            RecoveryInput(state: .failed, age: Self.old, hasAudio: true, audioFrameCount: 48_000),
            .skip(.settled(.failed))
        ),
        (
            "done is left alone",
            RecoveryInput(state: .done, age: Self.old, hasAudio: true, audioFrameCount: 48_000),
            .skip(.settled(.done))
        ),
        (
            "a folder younger than the minimum age is left alone",
            RecoveryInput(state: .recording, age: 3, hasAudio: true, audioFrameCount: 48_000),
            .skip(.tooYoung(age: 3))
        ),
        (
            "a folder held by a live process is left alone",
            RecoveryInput(
                state: .recording,
                age: Self.old,
                lock: .alive(pid: 4711),
                hasAudio: true,
                audioFrameCount: 48_000
            ),
            .skip(.locked(pid: 4711))
        ),
        (
            "a folder this process is recording into is left alone",
            RecoveryInput(
                state: .recording,
                age: Self.old,
                lock: .ours(pid: 99),
                hasAudio: true,
                audioFrameCount: 48_000
            ),
            .skip(.locked(pid: 99))
        ),
        (
            "a stale lock is no reason to skip — it is what a crash leaves",
            RecoveryInput(
                state: .recording,
                age: Self.old,
                lock: .stale(pid: 4711),
                hasAudio: true,
                audioFrameCount: 48_000
            ),
            .finishInterruptedRecording
        )
    ]

    @Test("decides each case the way M6 describes", arguments: table)
    func decides(row: (name: String, input: RecoveryInput, expected: RecoveryDecision)) {
        #expect(RecoveryPolicy.decide(row.input) == row.expected, "\(row.name)")
    }

    // MARK: - Precedence

    @Test("a settled folder is skipped however young or locked it is")
    func settledWinsOverEverything() {
        for state in [MeetingState.done, .failed] {
            let input = RecoveryInput(state: state, age: 0, lock: .alive(pid: 1))
            #expect(RecoveryPolicy.decide(input) == .skip(.settled(state)))
        }
    }

    @Test("a live lock wins over the age rule, so the reason in the log is the true one")
    func lockWinsOverAge() {
        let input = RecoveryInput(state: .recording, age: 0, lock: .alive(pid: 7))
        #expect(RecoveryPolicy.decide(input) == .skip(.locked(pid: 7)))
    }

    @Test("the age rule wins over the missing-audio rule")
    func ageWinsOverAudio() {
        // A recording that has just started has no frames yet either, and calling that
        // a failure would kill a live recording made by another instance.
        let input = RecoveryInput(state: .recording, age: 1, hasAudio: true, audioFrameCount: 0)
        #expect(RecoveryPolicy.decide(input) == .skip(.tooYoung(age: 1)))
    }

    @Test("the minimum age is exclusive at the boundary")
    func boundary() {
        let below = RecoveryInput(
            state: .recording,
            age: RecoveryPolicy.minimumAge - 0.01,
            hasAudio: true,
            audioFrameCount: 1
        )
        let atOrAbove = RecoveryInput(
            state: .recording,
            age: RecoveryPolicy.minimumAge,
            hasAudio: true,
            audioFrameCount: 1
        )
        #expect(RecoveryPolicy.decide(below).isAction == false)
        #expect(RecoveryPolicy.decide(atOrAbove) == .finishInterruptedRecording)
    }

    @Test("a recording is never given up on for attempts it cannot have made")
    func recordingIgnoresAttempts() {
        let input = RecoveryInput(
            state: .recording,
            age: Self.old,
            hasAudio: true,
            audioFrameCount: 48_000,
            attempts: 99
        )
        #expect(RecoveryPolicy.decide(input) == .finishInterruptedRecording)
    }

    @Test("the attempt cap is honoured wherever it is set", arguments: [1, 2, 3, 5])
    func attemptCap(maxAttempts: Int) {
        for attempts in 0..<maxAttempts {
            let input = RecoveryInput(state: .transcribing, age: Self.old, attempts: attempts)
            #expect(RecoveryPolicy.decide(input, maxAttempts: maxAttempts) == .requeue)
        }
        let spent = RecoveryInput(state: .transcribing, age: Self.old, attempts: maxAttempts)
        #expect(RecoveryPolicy.decide(spent, maxAttempts: maxAttempts) == .giveUp)
    }

    // MARK: - RecoveryLock

    @Test("only a running process holds a folder")
    func lockHolding() {
        #expect(RecoveryLock.absent.isHeld == false)
        #expect(RecoveryLock.stale(pid: 1).isHeld == false)
        #expect(RecoveryLock.alive(pid: 1).isHeld)
        #expect(RecoveryLock.ours(pid: 1).isHeld)
        #expect(RecoveryLock.absent.pid == nil)
        #expect(RecoveryLock.stale(pid: 12).pid == 12)
    }

    @Test("a skip is not an action")
    func isAction() {
        #expect(RecoveryDecision.skip(.alreadyQueued).isAction == false)
        #expect(RecoveryDecision.finishInterruptedRecording.isAction)
        #expect(RecoveryDecision.failWithoutAudio.isAction)
        #expect(RecoveryDecision.requeue.isAction)
        #expect(RecoveryDecision.giveUp.isAction)
    }
}
