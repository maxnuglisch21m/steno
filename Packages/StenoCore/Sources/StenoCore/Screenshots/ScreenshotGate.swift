import Foundation

/// The thresholds that decide whether a captured frame is worth keeping.
/// Defaults are the values from the specification §4.
public struct ScreenshotGateConfig: Sendable, Hashable, Codable {
    /// Minimum seconds between two saved images of a display without the mouse.
    public var normalMinInterval: TimeInterval
    /// Minimum seconds between two saved images of the display holding the mouse.
    public var activeMinInterval: TimeInterval
    /// Minimum share of the display area that must have changed, without the mouse.
    public var normalMinChange: Double
    /// Minimum share of the display area that must have changed, with the mouse.
    public var activeMinChange: Double
    /// Save one image per display at least this often, whatever changed. Without it a
    /// static monitor would go a whole meeting without a single frame.
    public var anchorInterval: TimeInterval

    public init(
        normalMinInterval: TimeInterval = 5,
        activeMinInterval: TimeInterval = 2,
        normalMinChange: Double = 0.02,
        activeMinChange: Double = 0.005,
        anchorInterval: TimeInterval = 120
    ) {
        self.normalMinInterval = normalMinInterval
        self.activeMinInterval = activeMinInterval
        self.normalMinChange = normalMinChange
        self.activeMinChange = activeMinChange
        self.anchorInterval = anchorInterval
    }

    public static let `default` = ScreenshotGateConfig()

    /// The interval and change threshold that apply to a display.
    public func thresholds(isActive: Bool) -> (minInterval: TimeInterval, minChange: Double) {
        isActive
            ? (activeMinInterval, activeMinChange)
            : (normalMinInterval, normalMinChange)
    }
}

/// Why a frame is being kept.
public enum ScreenshotSaveReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// Enough of the display changed, and enough time has passed.
    case change
    /// The anchor interval elapsed — or this is the display's first frame — so the
    /// frame is kept regardless of what changed.
    case anchor
}

public enum ScreenshotDecision: Sendable, Hashable {
    case save(reason: ScreenshotSaveReason)
    case skip

    public var isSave: Bool {
        if case .save = self { return true }
        return false
    }

    public var reason: ScreenshotSaveReason? {
        if case .save(let reason) = self { return reason }
        return nil
    }
}

/// Decides which captured frames become files.
///
/// ScreenCaptureKit already filters out unchanged displays for us — it reports frame
/// status `.idle` for them — so this gate only sees candidates and answers a narrower
/// question: has enough changed, and has enough time passed, for this frame to be
/// worth a file? The display holding the mouse gets shorter intervals and a lower
/// change threshold, because that is where the meeting is actually happening.
///
/// The decision itself is a pure function of its inputs; the value type keeps the
/// per-display timestamps so a caller does not have to.
public struct ScreenshotGate: Sendable {
    public var config: ScreenshotGateConfig
    /// When each display last had a frame saved, keyed by `CGDirectDisplayID`.
    public private(set) var lastSavedAt: [UInt32: Date]

    public init(config: ScreenshotGateConfig = .default, lastSavedAt: [UInt32: Date] = [:]) {
        self.config = config
        self.lastSavedAt = lastSavedAt
    }

    /// The pure decision, with no state of its own.
    ///
    /// - Parameters:
    ///   - isActive: whether this display currently holds the mouse.
    ///   - changedPct: share of the display area covered by the frame's dirty rects, 0…1.
    ///   - now: the frame's timestamp.
    ///   - lastSavedAt: when this display last had a frame saved; `nil` for its first frame.
    ///   - config: the thresholds to apply.
    public static func decide(
        isActive: Bool,
        changedPct: Double,
        now: Date,
        lastSavedAt: Date?,
        config: ScreenshotGateConfig = .default
    ) -> ScreenshotDecision {
        // The first frame of a display is always kept: it is the anchor everything
        // after it is measured against.
        guard let lastSavedAt else { return .save(reason: .anchor) }

        let elapsed = now.timeIntervalSince(lastSavedAt)
        // A frame that arrives before the last saved one — a clock change, or a
        // reordered buffer — is not a reason to save.
        guard elapsed >= 0 else { return .skip }

        if elapsed >= config.anchorInterval { return .save(reason: .anchor) }

        let (minInterval, minChange) = config.thresholds(isActive: isActive)
        if elapsed >= minInterval, changedPct >= minChange { return .save(reason: .change) }

        return .skip
    }

    /// Decides for one display and records the timestamp when the answer is to save.
    ///
    /// - Parameters:
    ///   - displayID: `CGDirectDisplayID` of the display the frame came from.
    ///   - isActive: whether that display currently holds the mouse.
    ///   - changedPct: share of the display area that changed, 0…1.
    ///   - now: the frame's timestamp.
    public mutating func decide(
        displayID: UInt32,
        isActive: Bool,
        changedPct: Double,
        now: Date
    ) -> ScreenshotDecision {
        let decision = Self.decide(
            isActive: isActive,
            changedPct: changedPct,
            now: now,
            lastSavedAt: lastSavedAt[displayID],
            config: config
        )
        if decision.isSave { lastSavedAt[displayID] = now }
        return decision
    }

    /// Forgets a display, so that a display reconnected mid-meeting gets a fresh
    /// anchor frame rather than being measured against a stale timestamp.
    public mutating func forget(displayID: UInt32) {
        lastSavedAt[displayID] = nil
    }

    public mutating func reset() {
        lastSavedAt.removeAll()
    }
}
