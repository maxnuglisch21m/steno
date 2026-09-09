import Foundation
import Testing

@testable import StenoCore

@Suite("MeetingState")
struct MeetingStateTests {
    static let legal: [(MeetingState, MeetingState)] = [
        (.recording, .transcribing),
        (.recording, .failed),
        (.transcribing, .done),
        (.transcribing, .failed),
        (.failed, .transcribing)
    ]

    @Test("allows the transitions the lifecycle needs", arguments: legal)
    func allowsLegalTransitions(from: MeetingState, to: MeetingState) throws {
        #expect(from.canTransition(to: to))
        var state = from
        try state.transition(to: to)
        #expect(state == to)
        #expect(try from.transitioned(to: to) == to)
    }

    @Test(
        "throws on every other transition",
        arguments: MeetingState.allCases, MeetingState.allCases
    )
    func throwsOnIllegalTransitions(from: MeetingState, to: MeetingState) {
        let isLegal = Self.legal.contains { $0.0 == from && $0.1 == to }
        guard !isLegal else { return }

        #expect(!from.canTransition(to: to))
        var state = from
        #expect(throws: MeetingState.IllegalTransition(from: from, to: to)) {
            try state.transition(to: to)
        }
        // A rejected transition leaves the state untouched.
        #expect(state == from)
    }

    @Test("a transition to the state already held is a logic error, not a no-op")
    func rejectsSelfTransition() {
        for state in MeetingState.allCases {
            #expect(!state.canTransition(to: state))
        }
    }

    @Test("done is terminal")
    func doneIsTerminal() {
        #expect(MeetingState.done.allowedSuccessors.isEmpty)
        #expect(MeetingState.done.isTerminal)
        #expect(!MeetingState.done.needsRecovery)
    }

    @Test("failed can be retried")
    func failedRetries() {
        #expect(MeetingState.failed.canTransition(to: .transcribing))
        #expect(!MeetingState.failed.isTerminal)
        // A failed recording is not picked up automatically on launch; only a
        // recording interrupted mid-flight is.
        #expect(!MeetingState.failed.needsRecovery)
    }

    @Test(
        "the states a launch has to recover",
        arguments: [
            (MeetingState.recording, true),
            (.transcribing, true),
            (.done, false),
            (.failed, false)
        ]
    )
    func needsRecovery(state: MeetingState, expected: Bool) {
        #expect(state.needsRecovery == expected)
    }

    @Test("the whole happy path runs through")
    func happyPath() throws {
        var state = MeetingState.recording
        try state.transition(to: .transcribing)
        try state.transition(to: .done)
        #expect(state == .done)
    }

    @Test("a failed run can be retried and then succeed")
    func retryPath() throws {
        var state = MeetingState.recording
        try state.transition(to: .transcribing)
        try state.transition(to: .failed)
        try state.transition(to: .transcribing)
        try state.transition(to: .done)
        #expect(state == .done)
    }

    @Test("encodes as the specification's string values")
    func rawValues() throws {
        #expect(MeetingState.allCases.map(\.rawValue) == ["recording", "transcribing", "done", "failed"])
        let data = try JSONEncoder().encode(MeetingState.transcribing)
        #expect(String(data: data, encoding: .utf8) == "\"transcribing\"")
    }

    @Test("the illegal-transition error names both states")
    func errorDescription() {
        let error = MeetingState.IllegalTransition(from: .done, to: .recording)
        #expect(error.description.contains("done"))
        #expect(error.description.contains("recording"))
    }
}
