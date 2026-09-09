import Foundation
import Testing

@testable import StenoCore

@Suite("ScreensFileNamer")
struct ScreensFileNamerTests {
    static let berlin = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-09 14:30:12 +02:00
    static let capturedAt = Date(timeIntervalSince1970: 1_788_957_012)

    @Test("the first frame of a second carries no suffix")
    func firstFrame() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        #expect(
            namer.nextFileName(capturedAt: Self.capturedAt, display: 1, active: true)
                == "143012_d1_active.jpg"
        )
    }

    @Test("a second frame of the same display in the same second gets _2")
    func sameSecondCollision() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        let first = namer.nextFileName(capturedAt: Self.capturedAt, display: 0, active: false)
        // 400 ms later, still the same wall-clock second.
        let second = namer.nextFileName(
            capturedAt: Self.capturedAt.addingTimeInterval(0.4),
            display: 0,
            active: false
        )
        let third = namer.nextFileName(
            capturedAt: Self.capturedAt.addingTimeInterval(0.8),
            display: 0,
            active: false
        )
        #expect(first == "143012_d0.jpg")
        #expect(second == "143012_d0_2.jpg")
        #expect(third == "143012_d0_3.jpg")
    }

    @Test("the suffix counts even when the active flag changes within the second")
    func activeFlagChangesWithinSecond() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        let first = namer.nextFileName(capturedAt: Self.capturedAt, display: 2, active: false)
        let second = namer.nextFileName(
            capturedAt: Self.capturedAt.addingTimeInterval(0.2),
            display: 2,
            active: true
        )
        #expect(first == "143012_d2.jpg")
        #expect(second == "143012_d2_active_2.jpg")
        #expect(first != second)
    }

    @Test("a new second starts counting again")
    func newSecondResets() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        _ = namer.nextFileName(capturedAt: Self.capturedAt, display: 0, active: false)
        _ = namer.nextFileName(capturedAt: Self.capturedAt.addingTimeInterval(0.3), display: 0, active: false)
        let next = namer.nextFileName(
            capturedAt: Self.capturedAt.addingTimeInterval(1),
            display: 0,
            active: false
        )
        #expect(next == "143013_d0.jpg")
    }

    @Test("displays are counted apart")
    func displaysAreIndependent() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        let zero = namer.nextFileName(capturedAt: Self.capturedAt, display: 0, active: false)
        let one = namer.nextFileName(capturedAt: Self.capturedAt, display: 1, active: false)
        #expect(zero == "143012_d0.jpg")
        #expect(one == "143012_d1.jpg")
    }

    @Test("a long run of names is never repeated")
    func neverRepeats() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        var seen = Set<String>()
        for step in 0..<200 {
            // Five frames per second across two displays, which is far more than the
            // 1 fps the streams run at — the point is that nothing collides.
            let at = Self.capturedAt.addingTimeInterval(Double(step) * 0.2)
            for display in 0...1 {
                let name = namer.nextFileName(capturedAt: at, display: display, active: display == 1)
                #expect(seen.insert(name).inserted, "repeated \(name)")
            }
        }
        #expect(seen.count == 400)
    }

    @Test("a forgotten display starts clean")
    func forgetting() {
        var namer = ScreensFileNamer(timeZone: Self.berlin)
        _ = namer.nextFileName(capturedAt: Self.capturedAt, display: 0, active: false)
        namer.forget(display: 0)
        #expect(
            namer.nextFileName(capturedAt: Self.capturedAt, display: 0, active: false)
                == "143012_d0.jpg"
        )
    }

    @Test("the entry built from a made-unique name keeps the screens/ prefix")
    func entryFromFileName() {
        let entry = ScreensIndexEntry(
            t: 18.42,
            fileName: "143012_d1_active_2.jpg",
            display: 1,
            active: true,
            changed: 0.31
        )
        #expect(entry.file == "screens/143012_d1_active_2.jpg")
        #expect(entry.fileName == "143012_d1_active_2.jpg")
    }

    @Test(
        "the sequence suffix goes before the extension",
        arguments: [(1, "143012_d0.jpg"), (2, "143012_d0_2.jpg"), (12, "143012_d0_12.jpg")]
    )
    func sequenceSuffix(sequence: Int, expected: String) {
        #expect(
            ScreensIndexEntry.fileName(
                capturedAt: Self.capturedAt,
                display: 0,
                active: false,
                timeZone: Self.berlin,
                sequence: sequence
            ) == expected
        )
    }
}
