import Foundation
import Testing

@testable import StenoCore

/// The optional `speakers` block of `meta.json`, which carries what the user said
/// about the number of people in the room to the diarizer in M5.
@Suite("SpeakerHint")
struct SpeakerHintTests {
    // MARK: - The value itself

    @Test("keeps a count inside the allowed range", arguments: Array(2...8))
    func keepsAllowedCounts(count: Int) {
        #expect(SpeakerHint(expected: count).expected == count)
        #expect(!SpeakerHint(expected: count).isEmpty)
    }

    @Test(
        "drops a count the picker cannot produce",
        arguments: [-1, 0, 1, 9, 42, Int.max]
    )
    func dropsCountsOutsideTheRange(count: Int) {
        // Narrowing the diarizer to one speaker, or to forty-two, is worse than
        // telling it nothing — so an impossible number becomes no hint at all.
        #expect(SpeakerHint(expected: count).expected == nil)
        #expect(SpeakerHint(expected: count).isEmpty)
    }

    @Test("automatic is an empty hint")
    func automaticIsEmpty() {
        #expect(SpeakerHint(expected: nil).isEmpty)
    }

    @Test("the range is the one the picker offers")
    func rangeMatchesThePicker() {
        #expect(SpeakerHint.allowedRange == 2...8)
    }

    // MARK: - In meta.json

    @Test("round-trips through meta.json as speakers.expected")
    func roundTrip() throws {
        var meta = MeetingMetaTests.onsiteMeta()
        meta.setExpectedSpeakers(4)

        let data = try meta.jsonData(timeZone: MeetingMetaTests.berlin)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try #require(object["speakers"] as? [String: Any])
        #expect(speakers["expected"] as? Int == 4)

        let decoded = try MeetingMeta.decode(from: data)
        #expect(decoded.speakers?.expected == 4)
        #expect(decoded == meta)
    }

    @Test("no key at all when nothing was asked")
    func absentWhenUnset() throws {
        let data = try MeetingMetaTests.onsiteMeta().jsonData(timeZone: MeetingMetaTests.berlin)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // A reader written against specification §6 must not meet a key that says
        // nothing, so an absent hint is absent rather than `{"expected": null}`.
        #expect(object["speakers"] == nil)
    }

    @Test("an out-of-range count leaves no key behind")
    func outOfRangeWritesNothing() throws {
        var meta = MeetingMetaTests.onsiteMeta()
        meta.setExpectedSpeakers(99)
        let data = try meta.jsonData(timeZone: MeetingMetaTests.berlin)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["speakers"] == nil)
        #expect(meta.speakers == nil)
    }

    @Test("setting it back to automatic removes it")
    func clearing() throws {
        var meta = MeetingMetaTests.onsiteMeta()
        meta.setExpectedSpeakers(6)
        #expect(meta.speakers?.expected == 6)
        meta.setExpectedSpeakers(nil)
        #expect(meta.speakers == nil)
    }

    @Test("the initializer clamps too, not just the setter")
    func initializerNormalizes() {
        let meta = MeetingMeta(
            mode: .onsite,
            started: Date(timeIntervalSince1970: 0),
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "0.1.0",
            speakers: SpeakerHint(expected: nil)
        )
        #expect(meta.speakers == nil)
    }

    @Test("a document written by a newer build with an unknown count decodes safely")
    func decodesUnexpectedValue() throws {
        // The format is a contract with other tools, and a sibling app on another
        // platform could write anything. Decoding must not throw; the value is
        // whatever was written, and M5 is what bounds it before the diarizer sees it.
        let json = """
        {
          "app": "0.1.0",
          "channels": ["room"],
          "displays": [],
          "input": {"device": "Mic"},
          "mode": "onsite",
          "screenshots": 0,
          "speakers": {"expected": 12},
          "started": "2026-09-09T14:30:12+02:00",
          "state": "recording",
          "trigger": {"kind": "manual"}
        }
        """
        let meta = try MeetingMeta.decode(from: Data(json.utf8))
        #expect(meta.speakers?.expected == 12)
    }
}
