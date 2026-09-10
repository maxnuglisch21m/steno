import Foundation
import Testing

@testable import StenoCore

@Suite("ScreensIndexEntry")
struct ScreensIndexEntryTests {
    static let berlin = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-09 14:30:12 +02:00
    static let started = Date(timeIntervalSince1970: 1_788_957_012)
    /// 18.42 s into that recording: 14:30:30 +02:00.
    static let capturedAt = started.addingTimeInterval(18.42)

    @Test("serializes the documented line")
    func specificationLine() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            at: Self.capturedAt,
            file: "screens/000018_d1_active.jpg",
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(
            entry.jsonLine(timeZone: Self.berlin)
                == #"{"t":18.42,"at":"2026-09-09T14:30:30+02:00","file":"screens/000018_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        )
    }

    @Test("an entry with no wall clock writes no at key")
    func lineWithoutAt() {
        // What an index written before the names counted from `meta.started` holds,
        // read back and written out again.
        let entry = ScreensIndexEntry(
            t: 18.42,
            file: "screens/143012_d1_active.jpg",
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(
            entry.jsonLine(timeZone: Self.berlin)
                == #"{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        )
    }

    @Test("at is written in the zone it is given, like meta.json's timestamps")
    func atUsesTheGivenZone() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            at: Self.capturedAt,
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(entry.jsonLine(timeZone: TimeZone(secondsFromGMT: 0)!).contains(#""at":"2026-09-09T12:30:30Z""#))
        #expect(
            entry.jsonLine(timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
                .contains(#""at":"2026-09-09T07:30:30-05:00""#)
        )
    }

    @Test("the line data ends in a newline, ready to append")
    func lineData() {
        let entry = ScreensIndexEntry(
            t: 1,
            at: Self.capturedAt,
            file: "screens/000001_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        let text = String(decoding: entry.jsonLineData(timeZone: Self.berlin), as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text == entry.jsonLine(timeZone: Self.berlin) + "\n")
    }

    @Test(
        "builds file names as HHMMSS_d<index>[_active].jpg",
        arguments: [
            (1, true, "000018_d1_active.jpg"),
            (0, false, "000018_d0.jpg"),
            (2, true, "000018_d2_active.jpg"),
            (10, false, "000018_d10.jpg")
        ]
    )
    func fileNames(display: Int, active: Bool, expected: String) {
        #expect(ScreensIndexEntry.fileName(t: 18.42, display: display, active: active) == expected)
        #expect(
            ScreensIndexEntry.relativePath(t: 18.42, display: display, active: active)
                == "screens/" + expected
        )
    }

    @Test(
        "pads and floors the clock",
        arguments: [
            (0.0, "000000_d0.jpg"),
            (0.99, "000000_d0.jpg"),
            (5.53, "000005_d0.jpg"),
            (3723.0, "010203_d0.jpg"),
            (3599.99, "005959_d0.jpg"),
            (3600.0, "010000_d0.jpg")
        ]
    )
    func padsClock(t: TimeInterval, expected: String) {
        #expect(ScreensIndexEntry.fileName(t: t, display: 0, active: false) == expected)
    }

    @Test("derives the file from the offset and keeps the wall clock beside it")
    func derivesFile() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            at: Self.capturedAt,
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(entry.file == "screens/000018_d1_active.jpg")
        #expect(entry.fileName == "000018_d1_active.jpg")
        #expect(entry.at == Self.capturedAt)
    }

    @Test("the file name is readable back off a bare name too")
    func fileNameWithoutPrefix() {
        let entry = ScreensIndexEntry(
            t: 0,
            file: "000000_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        #expect(entry.fileName == "000000_d0.jpg")
    }

    @Test(
        "renders numbers with two decimals",
        arguments: [
            (0.0, "0.00"),
            (1.0, "1.00"),
            (18.42, "18.42"),
            (18.425, "18.43"),
            (0.005, "0.01"),
            (2552.0, "2552.00"),
            (0.31, "0.31")
        ]
    )
    func numberFormatting(value: Double, expected: String) {
        let entry = ScreensIndexEntry(t: value, file: "f.jpg", display: 0, active: false, changed: value)
        #expect(entry.jsonLine().contains("\"t\":\(expected),"))
        #expect(entry.jsonLine().hasSuffix("\"changed\":\(expected)}"))
    }

    @Test("decodes one line")
    func decodesLine() throws {
        let line =
            #"{"t":18.42,"at":"2026-09-09T14:30:30+02:00","file":"screens/000018_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        let entry = try ScreensIndexEntry.decode(line: line)
        #expect(entry.t == 18.42)
        #expect(entry.at == Self.started.addingTimeInterval(18))
        #expect(entry.file == "screens/000018_d1_active.jpg")
        #expect(entry.display == 1)
        #expect(entry.active)
        #expect(entry.changed == 0.31)
    }

    @Test("decodes a line from before the names counted from the start")
    func decodesLineWithoutAt() throws {
        let line =
            #"{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        let entry = try ScreensIndexEntry.decode(line: line)
        #expect(entry.at == nil)
        #expect(entry.file == "screens/143012_d1_active.jpg")
    }

    @Test("round-trips through its own line format")
    func roundTrip() throws {
        let entries = [
            ScreensIndexEntry(t: 0, at: Self.started, display: 0, active: false, changed: 0),
            ScreensIndexEntry(t: 18.42, at: Self.started.addingTimeInterval(18), display: 1, active: true, changed: 0.31),
            ScreensIndexEntry(t: 2552, at: Self.started.addingTimeInterval(2552), display: 2, active: false, changed: 1),
            // No wall clock at all: still a line, and still the same entry back.
            ScreensIndexEntry(t: 5.5, file: "screens/143017_d0.jpg", display: 0, active: true, changed: 0.44)
        ]
        for entry in entries {
            let line = entry.jsonLine(timeZone: Self.berlin)
            #expect(try ScreensIndexEntry.decode(line: line) == entry)
        }
    }

    @Test("decodes a whole index")
    func decodesFile() throws {
        let jsonl = [
            ScreensIndexEntry(t: 0, at: Self.started, display: 0, active: false, changed: 0),
            ScreensIndexEntry(t: 5, at: Self.started.addingTimeInterval(5), display: 0, active: true, changed: 0.44)
        ].map { $0.jsonLine(timeZone: Self.berlin) }.joined(separator: "\n") + "\n"

        let entries = try ScreensIndexEntry.decode(jsonl: jsonl)
        #expect(entries.count == 2)
        #expect(entries.map(\.t) == [0, 5])
        #expect(entries.map(\.file) == ["screens/000000_d0.jpg", "screens/000005_d0_active.jpg"])
    }

    @Test("skips blank lines")
    func skipsBlankLines() throws {
        let jsonl = """
        {"t":0.00,"file":"screens/a.jpg","display":0,"active":false,"changed":0.00}

        {"t":5.00,"file":"screens/b.jpg","display":0,"active":false,"changed":0.10}

        """
        #expect(try ScreensIndexEntry.decode(jsonl: jsonl).count == 2)
    }

    @Test("a truncated final line fails strictly and is dropped leniently")
    func truncatedFinalLine() throws {
        // What a kill during an append leaves behind.
        let jsonl = """
        {"t":0.00,"file":"screens/a.jpg","display":0,"active":false,"changed":0.00}
        {"t":5.00,"file":"screens/b.jpg","displ
        """
        #expect(throws: (any Error).self) { try ScreensIndexEntry.decode(jsonl: jsonl) }

        let salvaged = try ScreensIndexEntry.decode(jsonl: jsonl, lenient: true)
        #expect(salvaged.count == 1)
        #expect(salvaged[0].file == "screens/a.jpg")
    }

    @Test("an unparseable at fails the line rather than being ignored")
    func rejectsABrokenAt() {
        let line =
            #"{"t":1.00,"at":"9 September 2026","file":"screens/a.jpg","display":0,"active":false,"changed":0.00}"#
        #expect(throws: (any Error).self) { try ScreensIndexEntry.decode(line: line) }
    }

    @Test("escapes what JSON requires escaping")
    func escaping() throws {
        let entry = ScreensIndexEntry(
            t: 1,
            file: #"screens/a"b\c.jpg"#,
            display: 0,
            active: false,
            changed: 0
        )
        #expect(entry.jsonLine().contains(#"screens/a\"b\\c.jpg"#))
        // Still valid JSON, and still round-trips.
        #expect(try ScreensIndexEntry.decode(line: entry.jsonLine()) == entry)
    }

    @Test("does not escape the slash that every path contains")
    func doesNotEscapeSlash() {
        let entry = ScreensIndexEntry(
            t: 1,
            at: Self.capturedAt,
            file: "screens/000001_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        #expect(!entry.jsonLine(timeZone: Self.berlin).contains(#"\/"#))
    }

    @Test("survives a non-finite number rather than writing invalid JSON")
    func nonFiniteNumbers() throws {
        let entry = ScreensIndexEntry(
            t: .nan,
            file: "screens/a.jpg",
            display: 0,
            active: false,
            changed: .infinity
        )
        #expect(!entry.jsonLine().contains("nan"))
        #expect(!entry.jsonLine().contains("inf"))
        _ = try ScreensIndexEntry.decode(line: entry.jsonLine())
    }

    @Test("a non-finite offset still names a file")
    func nonFiniteFileName() {
        #expect(ScreensIndexEntry.fileName(t: .nan, display: 0, active: false) == "000000_d0.jpg")
        #expect(ScreensIndexEntry.fileName(t: -5, display: 0, active: false) == "000000_d0.jpg")
    }

    @Test("the directory name matches the layout")
    func directoryName() {
        #expect(ScreensIndexEntry.directoryName == "screens")
    }

    // MARK: - Trimming a truncated index (M6)

    private static func line(_ t: Double) -> String {
        ScreensIndexEntry(t: t, at: started.addingTimeInterval(t), display: 0, active: false, changed: 0.5)
            .jsonLine(timeZone: berlin)
    }

    private static func complete(_ text: String) -> Int {
        ScreensIndexEntry.completeByteCount(ofJSONL: Array(text.utf8))
    }

    @Test("leaves an intact index alone")
    func trimsNothingFromAnIntactIndex() throws {
        let text = Self.line(1) + "\n" + Self.line(2) + "\n"
        #expect(Self.complete(text) == text.utf8.count)
    }

    @Test("cuts off an unterminated final fragment")
    func trimsAFragment() throws {
        let good = Self.line(1) + "\n" + Self.line(2) + "\n"
        let text = good + "{\"t\":18.42,\"file\":\"scre"
        let kept = Self.complete(text)
        #expect(kept == good.utf8.count)

        let repaired = String(decoding: Array(text.utf8)[0..<kept], as: UTF8.self)
        #expect(try ScreensIndexEntry.decode(jsonl: repaired).count == 2)
    }

    @Test("cuts off a final line that ends properly and still holds half a record")
    func trimsATerminatedFragment() throws {
        let good = Self.line(1) + "\n"
        let text = good + "{\"t\":18.42,\"file\":\"scre\n"
        #expect(Self.complete(text) == good.utf8.count)
    }

    @Test("a lone fragment leaves nothing")
    func trimsEverything() {
        #expect(Self.complete("{\"t\":1") == 0)
        #expect(Self.complete("") == 0)
    }

    @Test("a complete final line without a newline is still a fragment")
    func requiresTheTerminator() {
        // The newline is written in the same call as the JSON, so its absence means
        // the write did not finish — whatever the bytes before it happen to parse as.
        let text = Self.line(1) + "\n" + Self.line(2)
        #expect(Self.complete(text) == (Self.line(1) + "\n").utf8.count)
    }

    @Test("keeps a trailing blank line rather than hunting for something to cut")
    func keepsBlankLines() {
        let text = Self.line(1) + "\n\n"
        #expect(Self.complete(text) == text.utf8.count)
    }

    @Test("the kept prefix always parses strictly")
    func keptPrefixParsesStrictly() throws {
        let full = Self.line(1) + "\n" + Self.line(2) + "\n" + Self.line(3) + "\n"
        let bytes = Array(full.utf8)
        // Every possible truncation point, which is every way a crash can land.
        for cut in 0...bytes.count {
            let kept = ScreensIndexEntry.completeByteCount(ofJSONL: bytes[0..<cut])
            let text = String(decoding: bytes[0..<kept], as: UTF8.self)
            _ = try ScreensIndexEntry.decode(jsonl: text)
        }
    }
}
