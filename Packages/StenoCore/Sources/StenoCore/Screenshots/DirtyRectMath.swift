import Foundation

/// A size in pixels. Deliberately not `CGSize`: everything in `StenoCore` is
/// Foundation-only, so the same arithmetic can be tested without CoreGraphics and
/// reused by a sibling implementation on another platform.
public struct PixelSize: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(width: Int, height: Int) {
        self.init(width: Double(width), height: Double(height))
    }

    /// Negative or non-finite dimensions have no area rather than a nonsensical one.
    public var area: Double {
        guard width.isFinite, height.isFinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    public var isEmpty: Bool { area <= 0 }
}

/// A rectangle in pixels, origin at the top-left of the frame — the coordinate space
/// ScreenCaptureKit's `SCStreamFrameInfo.dirtyRects` uses.
public struct PixelRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    /// The part of this rectangle that lies inside a frame of `size`.
    ///
    /// A dirty rect can extend past the frame — a window being dragged off the edge,
    /// or a rect reported in a slightly larger surface than the content — and counting
    /// the part that is not there would inflate the changed share.
    public func clamped(to size: PixelSize) -> PixelRect {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            return PixelRect(x: 0, y: 0, width: 0, height: 0)
        }
        let left = max(0, min(x, size.width))
        let top = max(0, min(y, size.height))
        let right = max(left, min(x + max(0, width), size.width))
        let bottom = max(top, min(y + max(0, height), size.height))
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// How much of a captured frame changed, from the dirty rectangles ScreenCaptureKit
/// attaches to it.
///
/// The specification (§4.4) says to **sum** the dirty rects rather than to union them.
/// That is not an approximation nobody noticed: the rects the compositor reports are
/// the damage regions it redrew, they rarely overlap, and unioning them would cost a
/// region intersection per frame per display to change a number that is compared
/// against a 2 % threshold. Where they do overlap the sum overstates the change, which
/// biases towards keeping a frame — the safe direction for a recorder — and the result
/// is capped at 1.0 so `changed` in `screens.jsonl` stays a share of the display.
public enum DirtyRectMath {
    /// The share of `frameSize` covered by `rects`, clamped to the frame and capped
    /// at 1.0. An empty frame or no rects is 0.
    public static func changedFraction(rects: [PixelRect], frameSize: PixelSize) -> Double {
        let frameArea = frameSize.area
        guard frameArea > 0, !rects.isEmpty else { return 0 }
        var changed = 0.0
        for rect in rects {
            changed += rect.clamped(to: frameSize).area
            // A single full-frame rect already answers the question; a hundred more
            // cannot make it truer, and this keeps a pathological frame cheap.
            if changed >= frameArea { return 1 }
        }
        return min(1, changed / frameArea)
    }
}
