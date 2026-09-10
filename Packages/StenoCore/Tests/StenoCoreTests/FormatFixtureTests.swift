import Foundation
import Testing

@testable import StenoCore

/// `docs/format-fixtures/` against the types that define the format.
///
/// The fixture folder is what `docs/FORMAT.md` describes, written out once by the
/// encoders in this package. Two things are checked, and the second is the point: the
/// files decode into the values a downstream reader would expect, **and** re-encoding
/// them produces the same bytes. The second half is what turns the fixture into a
/// regression test — a key renamed, a number that stops being rounded, a date format
/// that drifts to `Z` all change the bytes, and a format change that is not deliberate
/// then fails here instead of in someone else's parser.
@Suite("format fixtures")
struct FormatFixtureTests {
    /// `docs/format-fixtures/2026-09-09_1430_Teams_Weekly-Sync`, found relative to this
    /// file so the test needs no bundle resources and no build-phase copy.
    static let folder: URL = {
        URL(fileURLWithPath: #filePath)
            // …/Packages/StenoCore/Tests/StenoCoreTests/FormatFixtureTests.swift
            .deletingLastPathComponent()  // StenoCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // StenoCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("docs/format-fixtures/2026-09-09_1430_Teams_Weekly-Sync", isDirectory: true)
    }()

    /// The zone the fixture was written in. `meta.json` carries a numeric offset, and
    /// re-encoding has to be told which one to use.
    static let zone = TimeZone(secondsFromGMT: 2 * 3600)!

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.folder.appendingPathComponent(name))
    }

    @Test("the fixture folder holds one of each documented file")
    func fixtureIsComplete() {
        for name in ["meta.json", "screens.jsonl", "transcript.json", "transcript.md"] {
            #expect(
                FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(name).path),
                "docs/format-fixtures is missing \(name)"
            )
        }
    }

    // MARK: - meta.json

    @Test("meta.json decodes into the meeting it describes")
    func decodesMeta() throws {
        let meta = try MeetingMeta.decode(from: data("meta.json"))

        #expect(meta.mode == .online)
        #expect(meta.state == .done)
        #expect(meta.channels == [.system, .mic])
        #expect(meta.trigger.kind == .auto)
        #expect(meta.trigger.bundleId == "com.microsoft.teams2")
        #expect(meta.title == "Weekly Sync")
        #expect(meta.audio == "audio.m4a")
        #expect(meta.screenshots == 3)
        #expect(meta.duration == 152)
        #expect(meta.stopReason == .auto)
        #expect(meta.models?.asr == "parakeet-tdt-0.6b-v3")
        #expect(meta.models?.diarizer == "pyannote-community-1")
        #expect(
            ISO8601Timestamp.string(from: meta.started, timeZone: Self.zone)
                == "2026-09-09T14:30:12+02:00"
        )
    }

    @Test("re-encoding meta.json reproduces the file byte for byte")
    func metaRoundTripsToTheSameBytes() throws {
        let original = try data("meta.json")
        let encoded = try MeetingMeta.decode(from: original).jsonData(timeZone: Self.zone)
        #expect(encoded == original)
    }

    // MARK: - screens.jsonl

    @Test("screens.jsonl has one entry per line, each naming a file under screens/")
    func decodesScreensIndex() throws {
        let text = try String(decoding: data("screens.jsonl"), as: UTF8.self)
        let entries = try ScreensIndexEntry.decode(jsonl: text)

        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.file.hasPrefix("screens/") })
        #expect(entries.allSatisfy { $0.at != nil })
        #expect(entries.map(\.display) == [0, 1, 1])
        #expect(entries.map(\.active) == [false, true, true])
        // Sorted by time, which is what makes `t` usable as the bridge to the transcript.
        #expect(entries.map(\.t) == entries.map(\.t).sorted())
        #expect(entries.allSatisfy { (0...1).contains($0.changed) })
    }

    @Test("re-encoding the index reproduces the file byte for byte")
    func screensIndexRoundTrips() throws {
        let original = try data("screens.jsonl")
        let text = String(decoding: original, as: UTF8.self)
        let lines = try ScreensIndexEntry.decode(jsonl: text).map { $0.jsonLine(timeZone: Self.zone) }
        #expect(Data((lines.joined(separator: "\n") + "\n").utf8) == original)
    }

    @Test("every file name carries its own t as a clock")
    func screensFileNamesCountFromTheStart() throws {
        let entries = try ScreensIndexEntry.decode(
            jsonl: String(decoding: try data("screens.jsonl"), as: UTF8.self)
        )

        for entry in entries {
            // The name's clock is the transcript's stamp for the same instant, with the
            // colons taken out — that is the whole reason it is not a wall clock.
            let stamp = TranscriptMarkdownFormatter.clock(entry.t).replacingOccurrences(of: ":", with: "")
            #expect(entry.fileName.hasPrefix(stamp + "_d\(entry.display)"))
        }
    }

    @Test("at is the wall clock of the same instant t names")
    func screensWallClockAgreesWithT() throws {
        let meta = try MeetingMeta.decode(from: data("meta.json"))
        let entries = try ScreensIndexEntry.decode(
            jsonl: String(decoding: try data("screens.jsonl"), as: UTF8.self)
        )

        for entry in entries {
            let at = try #require(entry.at)
            let drift = at.timeIntervalSince(meta.started.addingTimeInterval(entry.t))
            // `at` carries whole seconds and `t` two decimals, so the two agree to
            // within the second `at` was floored to.
            #expect(drift <= 0 && drift > -1)
        }
    }

    // MARK: - transcript.json

    @Test("transcript.json decodes into the transcript it describes")
    func decodesTranscript() throws {
        let transcript = try Transcript.decode(from: data("transcript.json"))

        #expect(transcript.mode == .online)
        #expect(transcript.utterances.count == 3)
        #expect(transcript.speakers == ["S1", "ME", "S2"])
        #expect(transcript.models.asr == "parakeet-tdt-0.6b-v3")
        #expect(transcript.models.diarizer == "pyannote-community-1")
        #expect(transcript.confidence.asrRoom == 0.89)
        // `online` has a microphone channel, so `asr_mic` is a number rather than null.
        #expect(transcript.confidence.asrMic == 0.94)
        #expect(transcript.diarization.count == 3)
    }

    @Test("every utterance is consistent with its own tokens")
    func utterancesAgreeWithTheirTokens() throws {
        let transcript = try Transcript.decode(from: data("transcript.json"))

        for utterance in transcript.utterances {
            #expect(utterance.end >= utterance.start)
            #expect(!utterance.tokens.isEmpty)
            #expect(utterance.tokens.first?.t == utterance.start)
            #expect(utterance.tokens.map(\.t) == utterance.tokens.map(\.t).sorted())
            #expect(utterance.text == utterance.tokens.map(\.w).joined(separator: " "))
            #expect(SpeakerLabel.isReserved(utterance.speaker) || utterance.speaker.hasPrefix("S"))
        }
        // Utterances are sorted by start, which every reader relies on.
        #expect(transcript.utterances.map(\.start) == transcript.utterances.map(\.start).sorted())
    }

    @Test("every time in the transcript carries at most two decimals")
    func timesAreRounded() throws {
        let transcript = try Transcript.decode(from: data("transcript.json"))

        func isRounded(_ value: TimeInterval) -> Bool {
            abs(value - Transcript.round(value, Transcript.timeDecimals)) < 1e-9
        }

        for utterance in transcript.utterances {
            #expect(isRounded(utterance.start))
            #expect(isRounded(utterance.end))
            #expect(utterance.tokens.allSatisfy { isRounded($0.t) })
        }
        for segment in transcript.diarization {
            #expect(isRounded(segment.start))
            #expect(isRounded(segment.end))
        }
    }

    @Test("re-encoding transcript.json reproduces the file byte for byte")
    func transcriptRoundTripsToTheSameBytes() throws {
        let original = try data("transcript.json")
        #expect(try Transcript.decode(from: original).jsonData() == original)
    }

    // MARK: - transcript.md

    @Test("transcript.md is what the formatter produces for transcript.json")
    func markdownMatchesTheTranscript() throws {
        let transcript = try Transcript.decode(from: data("transcript.json"))
        let meta = try MeetingMeta.decode(from: data("meta.json"))
        let rendered = TranscriptMarkdownFormatter(timeZone: Self.zone).markdown(
            for: transcript,
            started: meta.started,
            duration: meta.duration
        )

        #expect(rendered == String(decoding: try data("transcript.md"), as: UTF8.self))
    }

    @Test("every speech line reads [HH:MM:SS] speaker: text")
    func markdownLineShape() throws {
        let text = String(decoding: try data("transcript.md"), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let speech = lines.filter { $0.hasPrefix("[") }

        #expect(speech.count == 3)
        for line in speech {
            #expect(line.count > 12)
            // `[00:00:12]` — ten characters, then a space, then the speaker.
            let stamp = line.prefix(10)
            #expect(stamp.first == "[" && stamp.last == "]")
            #expect(stamp.dropFirst().dropLast().split(separator: ":").count == 3)
        }
        #expect(text.hasPrefix("# Steno transcript\n"))
        #expect(text.contains("- Mode: online"))
        #expect(text.contains("- ASR model: parakeet-tdt-0.6b-v3"))
    }

    // MARK: - Across the files

    @Test("meta.json and transcript.json agree about the meeting")
    func filesAgree() throws {
        let meta = try MeetingMeta.decode(from: data("meta.json"))
        let transcript = try Transcript.decode(from: data("transcript.json"))

        #expect(meta.mode == transcript.mode)
        #expect(meta.models == transcript.models)
        // `ME` exists in `online` mode and only there — specification §5.
        #expect(transcript.speakers.contains(SpeakerLabel.me) == meta.mode.supportsSelfSpeaker)
        // Nothing is spoken after the recording ended.
        #expect(transcript.lastSpeechEnd <= (meta.duration ?? .infinity))
    }

    @Test("every screenshot falls inside the recording")
    func screenshotsFallInsideTheRecording() throws {
        let meta = try MeetingMeta.decode(from: data("meta.json"))
        let entries = try ScreensIndexEntry.decode(
            jsonl: String(decoding: try data("screens.jsonl"), as: UTF8.self)
        )

        #expect(entries.count == meta.screenshots)
        let displays = Set(meta.displays.map(\.index))
        for entry in entries {
            #expect(entry.t >= 0)
            #expect(entry.t <= (meta.duration ?? .infinity))
            #expect(displays.contains(entry.display))
        }
    }
}
