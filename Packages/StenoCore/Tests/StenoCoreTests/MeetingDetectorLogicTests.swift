import Foundation
import Testing

@testable import StenoCore

/// The detection state machine, driven by a clock the test owns.
///
/// Every timing in specification §2 — the five-second debounce, the thirty-second
/// silence before auto-stop, the sixty-second hysteresis before Steno asks again — is
/// checked here at both sides of its boundary. Nothing waits: `now` is a number.
@Suite("MeetingDetectorLogic")
struct MeetingDetectorLogicTests {
    private static let teams = WatchedApp(bundleId: "com.microsoft.teams2", name: "Teams")
    private static let zoom = WatchedApp(bundleId: "us.zoom.xos", name: "Zoom")

    private static func logic(
        _ timing: MeetingDetectorTiming = .default
    ) -> MeetingDetectorLogic {
        MeetingDetectorLogic(watchlist: [teams, zoom], timing: timing)
    }

    // MARK: - The five-second trigger

    @Test("microphone use shorter than the debounce is not a meeting")
    func debounceHoldsBack() {
        var logic = Self.logic()
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0).isEmpty)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 4.9).isEmpty)
        #expect(!logic.isInMeeting("com.microsoft.teams2"))
    }

    @Test("five seconds of microphone use is a meeting")
    func debounceFires() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        let events = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        #expect(events == [.meetingStarted(app: Self.teams)])
        #expect(logic.isInMeeting("com.microsoft.teams2"))
    }

    @Test("a gap in the microphone use restarts the debounce")
    func debounceRestarts() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: [], now: 4)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 4.5)
        // Four and a half seconds of it were before the gap and do not count.
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 8).isEmpty)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 9.5).count == 1)
    }

    @Test("the meeting is only reported once, however long it runs")
    func startsOnce() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5).count == 1)
        for step in stride(from: 6.0, through: 600.0, by: 10) {
            #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: step).isEmpty)
        }
    }

    @Test("two apps in meetings are two events, in watchlist order")
    func twoApps() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["us.zoom.xos", "com.microsoft.teams2"], now: 0)
        let events = logic.update(activeBundleIds: ["us.zoom.xos", "com.microsoft.teams2"], now: 5)
        #expect(events == [.meetingStarted(app: Self.teams), .meetingStarted(app: Self.zoom)])
    }

    // MARK: - Auto-stop

    @Test("thirty seconds of silence ends the meeting")
    func autoStop() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        _ = logic.update(activeBundleIds: [], now: 100)
        #expect(logic.update(activeBundleIds: [], now: 129).isEmpty)
        #expect(logic.update(activeBundleIds: [], now: 130) == [.meetingEnded(app: Self.teams)])
        #expect(!logic.isInMeeting("com.microsoft.teams2"))
    }

    @Test("the auto-stop delay is configurable")
    func autoStopDelayIsConfigurable() {
        var logic = Self.logic(MeetingDetectorTiming(trigger: 5, autoStop: 8, rearm: 60))
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        _ = logic.update(activeBundleIds: [], now: 10)
        #expect(logic.update(activeBundleIds: [], now: 17).isEmpty)
        #expect(logic.update(activeBundleIds: [], now: 18) == [.meetingEnded(app: Self.teams)])
    }

    @Test("a short silence in the middle of a call does not end it")
    func silenceGapDoesNotStop() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        // Twenty-nine seconds of nothing — a call put on hold, a device switch — and
        // then the microphone comes back.
        _ = logic.update(activeBundleIds: [], now: 10)
        #expect(logic.update(activeBundleIds: [], now: 38).isEmpty)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 39)
        #expect(logic.update(activeBundleIds: [], now: 60).isEmpty)
        #expect(logic.isInMeeting("com.microsoft.teams2"))
        // The clock restarted at the second silence, so the stop is 30 s after that.
        #expect(logic.update(activeBundleIds: [], now: 89).isEmpty)
        #expect(logic.update(activeBundleIds: [], now: 90) == [.meetingEnded(app: Self.teams)])
    }

    @Test("an app that was never in a meeting never ends one")
    func noEndWithoutStart() {
        var logic = Self.logic()
        for step in stride(from: 0.0, through: 300.0, by: 10) {
            #expect(logic.update(activeBundleIds: [], now: step).isEmpty)
        }
    }

    @Test("an app that never reached the debounce never ends a meeting either")
    func noEndAfterAbortedTrigger() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["us.zoom.xos"], now: 0)
        _ = logic.update(activeBundleIds: [], now: 3)
        for step in stride(from: 4.0, through: 200.0, by: 10) {
            #expect(logic.update(activeBundleIds: [], now: step).isEmpty)
        }
    }

    // MARK: - Asking once per meeting

    @Test("Steno does not ask again until the app has been quiet for sixty seconds")
    func rearmHysteresis() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5).count == 1)

        // Quiet for fifty seconds, then the same meeting resumes: no second offer.
        _ = logic.update(activeBundleIds: [], now: 10)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 55)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 61).isEmpty)
        #expect(logic.wasOffered("com.microsoft.teams2"))
    }

    @Test("after sixty seconds of quiet the next call is a new meeting")
    func rearmAfterSixtySeconds() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)

        _ = logic.update(activeBundleIds: [], now: 10)
        // Thirty seconds in, the meeting ends; sixty seconds in, the offer is re-armed.
        #expect(logic.update(activeBundleIds: [], now: 40) == [.meetingEnded(app: Self.teams)])
        #expect(logic.wasOffered("com.microsoft.teams2"))
        _ = logic.update(activeBundleIds: [], now: 70)
        #expect(!logic.wasOffered("com.microsoft.teams2"))

        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 71)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 76)
            == [.meetingStarted(app: Self.teams)])
    }

    @Test("the re-arm clock runs on silence, not on the offer")
    func rearmNeedsContinuousSilence() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        // A two-hour call: never quiet, so never re-armed, however long it runs.
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 7200)
        #expect(logic.wasOffered("com.microsoft.teams2"))
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 7300).isEmpty)
    }

    // MARK: - Forgetting a meeting

    @Test("forgetting a meeting stops its auto-stop without re-arming the offer")
    func forgetMeeting() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        // The user pressed stop while the call was still running.
        logic.forgetMeeting("com.microsoft.teams2")
        #expect(!logic.isInMeeting("com.microsoft.teams2"))
        _ = logic.update(activeBundleIds: [], now: 10)
        // No auto-stop, because there is nothing left to stop …
        #expect(logic.update(activeBundleIds: [], now: 50).isEmpty)
        // … and no new offer either, until the sixty seconds have passed.
        #expect(logic.wasOffered("com.microsoft.teams2"))
    }

    // MARK: - The watchlist

    @Test("removing an app from the watchlist drops everything known about it")
    func watchlistChangeDropsState() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5)
        #expect(logic.isInMeeting("com.microsoft.teams2"))

        logic.watchlist = [Self.zoom]
        #expect(!logic.isInMeeting("com.microsoft.teams2"))
        // And it can never produce an event again, active or not.
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 10)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 20).isEmpty)
    }

    @Test("an empty watchlist reports nothing at all")
    func emptyWatchlist() {
        var logic = MeetingDetectorLogic(watchlist: [])
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 60).isEmpty)
    }

    @Test("resetting forgets a debounce that was already half-satisfied")
    func resetClearsHistory() {
        var logic = Self.logic()
        _ = logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 0)
        logic.reset()
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 5).isEmpty)
        #expect(logic.update(activeBundleIds: ["com.microsoft.teams2"], now: 10).count == 1)
    }
}
