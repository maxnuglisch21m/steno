import Foundation
import Testing

@testable import StenoCore

@Suite("ScreensFileNamer")
struct ScreensFileNamerTests {
    @Test("the first frame of a second carries no suffix")
    func firstFrame() {
        var namer = ScreensFileNamer()
        #expect(namer.nextFileName(elapsed: 18.42, display: 1, active: true) == "000018_d1_active.jpg")
    }

    @Test("the clock is the offset from the start, not a wall clock")
    func countsFromTheStart() {
        var namer = ScreensFileNamer()
        #expect(namer.nextFileName(elapsed: 0, display: 0, active: false) == "000000_d0.jpg")
        #expect(namer.nextFileName(elapsed: 5.53, display: 1, active: true) == "000005_d1_active.jpg")
    }

    @Test(
        "the clock matches the transcript's for the same instant",
        arguments: [0.0, 5.53, 59.99, 60.0, 3599.99, 3600.0, 3723.0, 359_999.0]
    )
    func agreesWithTheTranscript(elapsed: TimeInterval) {
        var namer = ScreensFileNamer()
        let name = namer.nextFileName(elapsed: elapsed, display: 1, active: false)
        // `[HH:MM:SS]` with the colons taken out is exactly the name's prefix, which is
        // what lets a reader line an image up with a line of speech by eye.
        let stamp = TranscriptMarkdownFormatter.clock(elapsed).replacingOccurrences(of: ":", with: "")
        #expect(name == "\(stamp)_d1.jpg")
    }

    @Test(
        "hours count upwards rather than wrapping",
        arguments: [
            (0.0, "000000"),
            (3599.99, "005959"),
            (3600.0, "010000"),
            (3723.0, "010203"),
            // A twenty-six-hour recording keeps counting instead of rolling over.
            (93_784.0, "260304")
        ]
    )
    func clockRange(elapsed: TimeInterval, expected: String) {
        var namer = ScreensFileNamer()
        #expect(namer.nextFileName(elapsed: elapsed, display: 0, active: false) == "\(expected)_d0.jpg")
    }

    @Test("a second frame of the same display in the same second gets _2")
    func sameSecondCollision() {
        var namer = ScreensFileNamer()
        let first = namer.nextFileName(elapsed: 12.0, display: 0, active: false)
        // 400 ms later, still the same second of the recording.
        let second = namer.nextFileName(elapsed: 12.4, display: 0, active: false)
        let third = namer.nextFileName(elapsed: 12.8, display: 0, active: false)
        #expect(first == "000012_d0.jpg")
        #expect(second == "000012_d0_2.jpg")
        #expect(third == "000012_d0_3.jpg")
    }

    @Test("the suffix counts even when the active flag changes within the second")
    func activeFlagChangesWithinSecond() {
        var namer = ScreensFileNamer()
        let first = namer.nextFileName(elapsed: 12.0, display: 2, active: false)
        let second = namer.nextFileName(elapsed: 12.2, display: 2, active: true)
        #expect(first == "000012_d2.jpg")
        #expect(second == "000012_d2_active_2.jpg")
        #expect(first != second)
    }

    @Test("a new second starts counting again")
    func newSecondResets() {
        var namer = ScreensFileNamer()
        _ = namer.nextFileName(elapsed: 12.0, display: 0, active: false)
        _ = namer.nextFileName(elapsed: 12.3, display: 0, active: false)
        #expect(namer.nextFileName(elapsed: 13.0, display: 0, active: false) == "000013_d0.jpg")
    }

    @Test("displays are counted apart")
    func displaysAreIndependent() {
        var namer = ScreensFileNamer()
        #expect(namer.nextFileName(elapsed: 12, display: 0, active: false) == "000012_d0.jpg")
        #expect(namer.nextFileName(elapsed: 12, display: 1, active: false) == "000012_d1.jpg")
    }

    @Test("a long run of names is never repeated")
    func neverRepeats() {
        var namer = ScreensFileNamer()
        var seen = Set<String>()
        for step in 0..<200 {
            // Five frames per second across two displays, which is far more than the
            // 1 fps the streams run at — the point is that nothing collides.
            let elapsed = Double(step) * 0.2
            for display in 0...1 {
                let name = namer.nextFileName(elapsed: elapsed, display: display, active: display == 1)
                #expect(seen.insert(name).inserted, "repeated \(name)")
            }
        }
        #expect(seen.count == 400)
    }

    @Test("a forgotten display starts clean")
    func forgetting() {
        var namer = ScreensFileNamer()
        _ = namer.nextFileName(elapsed: 12, display: 0, active: false)
        namer.forget(display: 0)
        #expect(namer.nextFileName(elapsed: 12, display: 0, active: false) == "000012_d0.jpg")
    }

    @Test("the entry built from a made-unique name keeps the screens/ prefix")
    func entryFromFileName() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            fileName: "000018_d1_active_2.jpg",
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(entry.file == "screens/000018_d1_active_2.jpg")
        #expect(entry.fileName == "000018_d1_active_2.jpg")
    }

    @Test(
        "the sequence suffix goes before the extension",
        arguments: [(1, "000012_d0.jpg"), (2, "000012_d0_2.jpg"), (12, "000012_d0_12.jpg")]
    )
    func sequenceSuffix(sequence: Int, expected: String) {
        #expect(
            ScreensIndexEntry.fileName(t: 12, display: 0, active: false, sequence: sequence) == expected
        )
    }
}
