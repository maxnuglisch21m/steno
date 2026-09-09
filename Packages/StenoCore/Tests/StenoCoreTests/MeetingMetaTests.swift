import Foundation
import Testing

@testable import StenoCore

@Suite("MeetingMeta")
struct MeetingMetaTests {
    static let berlin = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-09T14:30:12+02:00
    static let started = Date(timeIntervalSince1970: 1_788_957_012)
    /// 2026-09-09T15:12:44+02:00
    static let ended = Date(timeIntervalSince1970: 1_788_959_564)

    static func onsiteMeta() -> MeetingMeta {
        MeetingMeta(
            mode: .onsite,
            started: started,
            ended: ended,
            duration: 2552.0,
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon", microphoneMode: "wideSpectrum"),
            displays: [
                DisplayInfo(index: 0, id: 1, px: [3840, 2160]),
                DisplayInfo(index: 1, id: 2, px: [2560, 1440])
            ],
            screenshots: 214,
            app: "1.1",
            state: .done
        )
    }

    // MARK: - Shape

    @Test("carries every key the specification lists, and no unexpected ones")
    func specificationKeys() throws {
        let data = try Self.onsiteMeta().jsonData(timeZone: Self.berlin)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let required: Set<String> = [
            "mode", "started", "ended", "duration", "trigger", "channels",
            "input", "displays", "screenshots", "app", "state"
        ]
        #expect(required.isSubset(of: Set(object.keys)))
        // The optional additions are omitted when unset, so a specification-only
        // reader sees exactly the specified document.
        #expect(Set(object.keys) == required)
    }

    @Test("matches the specification's onsite example")
    func onsiteExample() throws {
        let data = try Self.onsiteMeta().jsonData(timeZone: Self.berlin)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["mode"] as? String == "onsite")
        #expect(object["started"] as? String == "2026-09-09T14:30:12+02:00")
        #expect(object["ended"] as? String == "2026-09-09T15:12:44+02:00")
        #expect(object["duration"] as? Double == 2552.0)
        #expect(object["channels"] as? [String] == ["room"])
        #expect(object["screenshots"] as? Int == 214)
        #expect(object["app"] as? String == "1.1")
        #expect(object["state"] as? String == "done")

        let trigger = try #require(object["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "manual")
        #expect(trigger["bundleId"] == nil)
        #expect(trigger["name"] == nil)

        let input = try #require(object["input"] as? [String: Any])
        #expect(input["device"] as? String == "MacBook Pro Mikrofon")
        #expect(input["microphoneMode"] as? String == "wideSpectrum")

        let displays = try #require(object["displays"] as? [[String: Any]])
        #expect(displays.count == 2)
        #expect(displays[0]["index"] as? Int == 0)
        #expect(displays[0]["id"] as? Int == 1)
        #expect(displays[0]["px"] as? [Int] == [3840, 2160])
        #expect(displays[1]["px"] as? [Int] == [2560, 1440])
    }

    @Test("matches the specification's online example")
    func onlineExample() throws {
        let meta = MeetingMeta(
            mode: .online,
            started: Self.started,
            trigger: .auto(bundleId: "com.microsoft.teams2", name: "Teams"),
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "1.1"
        )
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: try meta.jsonData(timeZone: Self.berlin)
            ) as? [String: Any]
        )

        #expect(object["channels"] as? [String] == ["system", "mic"])
        let trigger = try #require(object["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "auto")
        #expect(trigger["bundleId"] as? String == "com.microsoft.teams2")
        #expect(trigger["name"] as? String == "Teams")
    }

    @Test("derives the channels from the mode")
    func channelsFollowMode() {
        #expect(MeetingMode.online.channels == [.system, .mic])
        #expect(MeetingMode.onsite.channels == [.room])
        #expect(MeetingMode.online.supportsSelfSpeaker)
        #expect(!MeetingMode.onsite.supportsSelfSpeaker)
    }

    @Test("keeps channels that were passed explicitly")
    func explicitChannels() {
        let meta = MeetingMeta(
            mode: .online,
            started: Self.started,
            trigger: .manual,
            channels: [.room],
            input: AudioInputInfo(device: "USB"),
            app: "0.1.0"
        )
        #expect(meta.channels == [.room])
    }

    @Test("writes the added fields when they are set")
    func additions() throws {
        var meta = Self.onsiteMeta()
        meta.title = "Weekly Sync"
        meta.audio = "audio.m4a"
        meta.appBuild = "42"
        meta.os = "15.4"
        meta.models = ModelIdentifiers(asr: "parakeet-tdt-0.6b-v3", diarizer: "pyannote-community-1")
        meta.error = nil

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: try meta.jsonData(timeZone: Self.berlin)
            ) as? [String: Any]
        )
        #expect(object["title"] as? String == "Weekly Sync")
        #expect(object["audio"] as? String == "audio.m4a")
        #expect(object["appBuild"] as? String == "42")
        #expect(object["os"] as? String == "15.4")
        #expect(object["error"] == nil)
        let models = try #require(object["models"] as? [String: Any])
        #expect(models["asr"] as? String == "parakeet-tdt-0.6b-v3")
        #expect(models["diarizer"] as? String == "pyannote-community-1")
    }

    // MARK: - Dates

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        var meta = Self.onsiteMeta()
        meta.title = "Küchenumbau"
        meta.audio = "audio.flac"
        meta.error = "input device disappeared"

        let decoded = try MeetingMeta.decode(from: try meta.jsonData(timeZone: Self.berlin))
        #expect(decoded == meta)
    }

    @Test("writes dates with a numeric offset rather than as UTC")
    func localOffsetTimestamps() throws {
        let json = String(
            decoding: try Self.onsiteMeta().jsonData(timeZone: Self.berlin),
            as: UTF8.self
        )
        #expect(json.contains("2026-09-09T14:30:12+02:00"))
        #expect(!json.contains("12:30:12Z"))
    }

    @Test(
        "reads back a timestamp written in any zone",
        arguments: [0, 3600, 7200, -25200, 19800]
    )
    func timestampsSurviveTimeZones(offset: Int) throws {
        let zone = TimeZone(secondsFromGMT: offset)!
        let decoded = try MeetingMeta.decode(from: try Self.onsiteMeta().jsonData(timeZone: zone))
        #expect(decoded.started == Self.started)
        #expect(decoded.ended == Self.ended)
    }

    @Test(
        "parses the ISO-8601 forms a recording folder can contain",
        arguments: [
            "2026-09-09T14:30:12+02:00",
            "2026-09-09T12:30:12Z",
            "2026-09-09T12:30:12+00:00",
            "2026-09-09T14:30:12.000+02:00"
        ]
    )
    func parsesTimestampForms(text: String) throws {
        #expect(ISO8601Timestamp.date(from: text) == Self.started)
    }

    @Test("rejects a timestamp it cannot parse")
    func rejectsBadTimestamp() {
        #expect(ISO8601Timestamp.date(from: "9 September 2026") == nil)
        #expect(ISO8601Timestamp.date(from: "") == nil)

        let data = Data(#"{"mode":"onsite","started":"yesterday","trigger":{"kind":"manual"},"channels":["room"],"input":{"device":"x"},"displays":[],"screenshots":0,"app":"1.0","state":"recording"}"#.utf8)
        #expect(throws: (any Error).self) { try MeetingMeta.decode(from: data) }
    }

    @Test("a fresh recording carries no end and no duration")
    func recordingHasNoEnd() throws {
        let meta = MeetingMeta(
            mode: .onsite,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "0.1.0"
        )
        #expect(meta.state == .recording)
        #expect(meta.ended == nil)
        #expect(meta.duration == nil)

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: try meta.jsonData(timeZone: Self.berlin)
            ) as? [String: Any]
        )
        #expect(object["ended"] == nil)
        #expect(object["duration"] == nil)
    }

    @Test("output is stable across encodes, so rewrites stay diffable")
    func stableOutput() throws {
        let meta = Self.onsiteMeta()
        let first = try meta.jsonData(timeZone: Self.berlin)
        let second = try meta.jsonData(timeZone: Self.berlin)
        #expect(first == second)
    }

    @Test("does not escape the slash in a path-like value")
    func doesNotEscapeSlashes() throws {
        var meta = Self.onsiteMeta()
        meta.title = "Q4/2026"
        let json = String(decoding: try meta.jsonData(timeZone: Self.berlin), as: UTF8.self)
        #expect(json.contains("Q4/2026"))
    }

    // MARK: - Lifecycle helpers

    @Test("finishing capture derives the duration")
    func finishCapture() {
        var meta = MeetingMeta(
            mode: .onsite,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "USB"),
            app: "0.1.0"
        )
        meta.finishCapture(at: Self.ended)
        #expect(meta.ended == Self.ended)
        #expect(meta.duration == 2552.0)
    }

    @Test("failing records the reason together with the state")
    func failRecordsReason() throws {
        var meta = MeetingMeta(
            mode: .onsite,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "USB"),
            app: "0.1.0"
        )
        try meta.fail(reason: "input device disappeared")
        #expect(meta.state == .failed)
        #expect(meta.error == "input device disappeared")
    }

    @Test("an illegal transition leaves the metadata untouched")
    func illegalTransitionLeavesMetaAlone() {
        var meta = Self.onsiteMeta()  // done
        #expect(throws: MeetingState.IllegalTransition(from: .done, to: .failed)) {
            try meta.fail(reason: "too late")
        }
        #expect(meta.state == .done)
        #expect(meta.error == nil)
    }

    @Test("display dimensions are readable as width and height")
    func displayDimensions() {
        let display = DisplayInfo(index: 1, id: 2, width: 2560, height: 1440)
        #expect(display.px == [2560, 1440])
        #expect(display.width == 2560)
        #expect(display.height == 1440)
        #expect(DisplayInfo(index: 0, id: 1, px: []).width == nil)
    }

    // MARK: - stopReason

    @Test("the stop reason survives a JSON round trip")
    func stopReasonRoundTrip() throws {
        for reason in MeetingStopReason.allCases {
            var meta = MeetingMeta(
                mode: .online,
                started: Self.started,
                trigger: .auto(bundleId: "com.microsoft.teams2", name: "Teams"),
                input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
                app: "0.1.0",
                title: "Weekly Sync"
            )
            meta.finishCapture(at: Self.ended, reason: reason)
            let decoded = try MeetingMeta.decode(from: try meta.jsonData())
            #expect(decoded.stopReason == reason)
            #expect(decoded.title == "Weekly Sync")
            #expect(decoded.trigger == MeetingTrigger.auto(bundleId: "com.microsoft.teams2", name: "Teams"))
        }
    }

    @Test("the stop reason is written with the spelling the format documents")
    func stopReasonSpelling() throws {
        var meta = MeetingMeta(
            mode: .online,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "0.1.0"
        )
        meta.finishCapture(at: Self.ended, reason: .deviceLost)
        let json = String(decoding: try meta.jsonData(), as: UTF8.self)
        #expect(json.contains("\"stopReason\" : \"deviceLost\""))
    }

    @Test("a recording that never stopped carries no stop reason")
    func noStopReasonWhileRecording() throws {
        let meta = MeetingMeta(
            mode: .online,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "0.1.0"
        )
        #expect(meta.stopReason == nil)
        let json = String(decoding: try meta.jsonData(), as: UTF8.self)
        #expect(!json.contains("stopReason"))
    }

    @Test("finishing without a reason keeps the one already recorded")
    func finishKeepsExistingReason() {
        var meta = MeetingMeta(
            mode: .online,
            started: Self.started,
            trigger: .manual,
            input: AudioInputInfo(device: "MacBook Pro Mikrofon"),
            app: "0.1.0"
        )
        meta.finishCapture(at: Self.ended, reason: .sleep)
        meta.finishCapture(at: Self.ended)
        #expect(meta.stopReason == .sleep)
    }
}
