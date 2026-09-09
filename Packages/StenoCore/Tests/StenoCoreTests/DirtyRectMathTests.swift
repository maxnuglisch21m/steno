import Foundation
import Testing

@testable import StenoCore

@Suite("DirtyRectMath")
struct DirtyRectMathTests {
    static let frame = PixelSize(width: 1000, height: 1000)

    @Test("no rects means nothing changed")
    func empty() {
        #expect(DirtyRectMath.changedFraction(rects: [], frameSize: Self.frame) == 0)
    }

    @Test("a rect covering the whole frame is 1.0")
    func full() {
        let rect = PixelRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: Self.frame) == 1)
    }

    @Test("a tenth of the frame is 0.1")
    func partial() {
        // 1000 × 100 of 1000 × 1000.
        let rect = PixelRect(x: 0, y: 0, width: 1000, height: 100)
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: Self.frame) == 0.1)
    }

    @Test("disjoint rects add up")
    func disjoint() {
        let rects = [
            PixelRect(x: 0, y: 0, width: 100, height: 100),
            PixelRect(x: 500, y: 500, width: 200, height: 100)
        ]
        // 10 000 + 20 000 of 1 000 000.
        #expect(DirtyRectMath.changedFraction(rects: rects, frameSize: Self.frame) == 0.03)
    }

    @Test("overlapping rects are summed, not unioned — the specification's rule")
    func overlapping() {
        let rects = [
            PixelRect(x: 0, y: 0, width: 200, height: 100),
            PixelRect(x: 100, y: 0, width: 200, height: 100)
        ]
        // Union would be 30 000; the sum is 40 000, i.e. 0.04.
        #expect(DirtyRectMath.changedFraction(rects: rects, frameSize: Self.frame) == 0.04)
    }

    @Test("a sum beyond the frame area is capped at 1.0")
    func capped() {
        let rects = Array(repeating: PixelRect(x: 0, y: 0, width: 1000, height: 1000), count: 5)
        #expect(DirtyRectMath.changedFraction(rects: rects, frameSize: Self.frame) == 1)
    }

    @Test("a rect hanging off the right edge is clamped")
    func clampedRight() {
        let rect = PixelRect(x: 900, y: 0, width: 400, height: 1000)
        // Only 100 px of width are inside the frame.
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: Self.frame) == 0.1)
    }

    @Test("a rect starting before the origin is clamped")
    func clampedOrigin() {
        let rect = PixelRect(x: -500, y: -500, width: 1000, height: 1000)
        // 500 × 500 of the rect overlaps the frame.
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: Self.frame) == 0.25)
    }

    @Test("a rect entirely outside the frame contributes nothing")
    func outside() {
        let rect = PixelRect(x: 2000, y: 2000, width: 100, height: 100)
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: Self.frame) == 0)
    }

    @Test("a frame with no area is 0 rather than a division by zero")
    func emptyFrame() {
        let rect = PixelRect(x: 0, y: 0, width: 100, height: 100)
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: PixelSize(width: 0, height: 0)) == 0)
        #expect(DirtyRectMath.changedFraction(rects: [rect], frameSize: PixelSize(width: -10, height: 10)) == 0)
    }

    @Test("negative and non-finite dimensions have no area")
    func degenerateRects() {
        let rects = [
            PixelRect(x: 0, y: 0, width: -100, height: 100),
            PixelRect(x: 0, y: 0, width: .nan, height: 100),
            PixelRect(x: .infinity, y: 0, width: 100, height: 100)
        ]
        #expect(DirtyRectMath.changedFraction(rects: rects, frameSize: Self.frame) == 0)
    }

    @Test("a real 4K frame with one window redrawn is a few per cent")
    func realistic() {
        let frame = PixelSize(width: 3840, height: 2160)
        // A 1200 × 800 window repainting on a 4K display.
        let rect = PixelRect(x: 400, y: 300, width: 1200, height: 800)
        let changed = DirtyRectMath.changedFraction(rects: [rect], frameSize: frame)
        #expect(changed > 0.11 && changed < 0.12)
    }

    @Test("clamping keeps a rect inside the frame")
    func clamping() {
        let clamped = PixelRect(x: -10, y: -10, width: 50, height: 50)
            .clamped(to: PixelSize(width: 20, height: 20))
        #expect(clamped == PixelRect(x: 0, y: 0, width: 20, height: 20))
    }
}
