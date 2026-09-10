import Foundation
import Testing

@testable import StenoCore

@Suite("ScreensIndexEntry")
struct ScreensIndexEntryTests {
    static let berlin = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-09 14:30:12 +02:00
    static let capturedAt = Date(timeIntervalSince1970: 1_788_957_012)

    @Test("serializes exactly the line from the specification")
    func specificationLine() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            file: "screens/143012_d1_active.jpg",
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(
            entry.jsonLine
                == #"{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        )
    }

    @Test("the line data ends in a newline, ready to append")
    func lineData() {
        let entry = ScreensIndexEntry(
            t: 1,
            file: "screens/143012_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        let text = String(decoding: entry.jsonLineData, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text == entry.jsonLine + "\n")
    }

    @Test(
        "builds file names as HHmmss_d<index>[_active].jpg",
        arguments: [
            (1, true, "143012_d1_active.jpg"),
            (0, false, "143012_d0.jpg"),
            (2, true, "143012_d2_active.jpg"),
            (10, false, "143012_d10.jpg")
        ]
    )
    func fileNames(display: Int, active: Bool, expected: String) {
        #expect(
            ScreensIndexEntry.fileName(
                capturedAt: Self.capturedAt,
                display: display,
                active: active,
                timeZone: Self.berlin
            ) == expected
        )
        #expect(
            ScreensIndexEntry.relativePath(
                capturedAt: Self.capturedAt,
                display: display,
                active: active,
                timeZone: Self.berlin
            ) == "screens/" + expected
        )
    }

    @Test("pads the clock components")
    func padsClock() {
        // 2026-01-02 03:04:05 +00:00
        let early = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(
            ScreensIndexEntry.fileName(
                capturedAt: early,
                display: 0,
                active: false,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ) == "030405_d0.jpg"
        )
    }

    @Test("derives the file from the capture time")
    func derivesFile() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            capturedAt: Self.capturedAt,
            display: 1,
            active: true,
            changed: 0.31,
            timeZone: Self.berlin
        )
        #expect(entry.file == "screens/143012_d1_active.jpg")
        #expect(entry.fileName == "143012_d1_active.jpg")
    }

    @Test("the file name is readable back off a bare name too")
    func fileNameWithoutPrefix() {
        let entry = ScreensIndexEntry(
            t: 0,
            file: "143012_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        #expect(entry.fileName == "143012_d0.jpg")
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
        #expect(entry.jsonLine.contains("\"t\":\(expected),"))
        #expect(entry.jsonLine.hasSuffix("\"changed\":\(expected)}"))
    }

    @Test("decodes one line")
    func decodesLine() throws {
        let line =
            #"{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}"#
        let entry = try ScreensIndexEntry.decode(line: line)
        #expect(entry.t == 18.42)
        #expect(entry.file == "screens/143012_d1_active.jpg")
        #expect(entry.display == 1)
        #expect(entry.active)
        #expect(entry.changed == 0.31)
    }

    @Test("round-trips through its own line format")
    func roundTrip() throws {
        let entries = [
            ScreensIndexEntry(t: 0, file: "screens/143012_d0.jpg", display: 0, active: false, changed: 0),
            ScreensIndexEntry(t: 18.42, file: "screens/143012_d1_active.jpg", display: 1, active: true, changed: 0.31),
            ScreensIndexEntry(t: 2552.5, file: "screens/151244_d2.jpg", display: 2, active: false, changed: 1)
        ]
        for entry in entries {
            #expect(try ScreensIndexEntry.decode(line: entry.jsonLine) == entry)
        }
    }

    @Test("decodes a whole index")
    func decodesFile() throws {
        let jsonl = [
            ScreensIndexEntry(t: 0, file: "screens/143012_d0.jpg", display: 0, active: false, changed: 0),
            ScreensIndexEntry(t: 5.5, file: "screens/143017_d0.jpg", display: 0, active: true, changed: 0.44)
        ].map(\.jsonLine).joined(separator: "\n") + "\n"

        let entries = try ScreensIndexEntry.decode(jsonl: jsonl)
        #expect(entries.count == 2)
        #expect(entries.map(\.t) == [0, 5.5])
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

    @Test("escapes what JSON requires escaping")
    func escaping() throws {
        let entry = ScreensIndexEntry(
            t: 1,
            file: #"screens/a"b\c.jpg"#,
            display: 0,
            active: false,
            changed: 0
        )
        #expect(entry.jsonLine.contains(#"screens/a\"b\\c.jpg"#))
        // Still valid JSON, and still round-trips.
        #expect(try ScreensIndexEntry.decode(line: entry.jsonLine) == entry)
    }

    @Test("does not escape the slash that every path contains")
    func doesNotEscapeSlash() {
        let entry = ScreensIndexEntry(
            t: 1,
            file: "screens/143012_d0.jpg",
            display: 0,
            active: false,
            changed: 0
        )
        #expect(!entry.jsonLine.contains(#"\/"#))
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
        #expect(!entry.jsonLine.contains("nan"))
        #expect(!entry.jsonLine.contains("inf"))
        _ = try ScreensIndexEntry.decode(line: entry.jsonLine)
    }

    @Test("the directory name matches the layout")
    func directoryName() {
        #expect(ScreensIndexEntry.directoryName == "screens")
    }

    // MARK: - Trimming a truncated index (M6)

    private static func line(_ t: Double) -> String {
        ScreensIndexEntry(t: t, file: "screens/a.jpg", display: 0, active: false, changed: 0.5)
            .jsonLine
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
