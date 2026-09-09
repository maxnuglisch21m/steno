import Foundation
import Testing

@testable import StenoCore

@Suite("ScreenshotGate")
struct ScreenshotGateTests {
    static let t0 = Date(timeIntervalSince1970: 1_788_957_012)
    static let config = ScreenshotGateConfig.default

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("uses the thresholds from the specification")
    func defaults() {
        #expect(Self.config.normalMinInterval == 5)
        #expect(Self.config.activeMinInterval == 2)
        #expect(Self.config.normalMinChange == 0.02)
        #expect(Self.config.activeMinChange == 0.005)
        #expect(Self.config.anchorInterval == 120)
    }

    @Test("the first frame of a display is always kept, as its anchor")
    func firstFrameAlwaysSaves() {
        for isActive in [true, false] {
            for changed in [0.0, 0.001, 0.5, 1.0] {
                let decision = ScreenshotGate.decide(
                    isActive: isActive,
                    changedPct: changed,
                    now: Self.at(0),
                    lastSavedAt: nil,
                    config: Self.config
                )
                #expect(decision == .save(reason: .anchor))
            }
        }
    }

    @Test(
        "decides on interval and changed area",
        arguments: [
            // (elapsed, changedPct, isActive, expected)

            // Normal display: 5 s and 2 %.
            (5.0, 0.02, false, ScreenshotDecision.save(reason: .change)),
            (5.0, 0.5, false, .save(reason: .change)),
            (30.0, 0.02, false, .save(reason: .change)),
            (4.9, 0.5, false, .skip),          // too soon
            (5.0, 0.019, false, .skip),        // too little changed
            (5.0, 0.0, false, .skip),
            (119.0, 0.019, false, .skip),      // still short of the anchor
            (0.0, 1.0, false, .skip),

            // Active display: 2 s and 0.5 %.
            (2.0, 0.005, true, .save(reason: .change)),
            (2.0, 0.02, true, .save(reason: .change)),
            (3.0, 0.006, true, .save(reason: .change)),
            (1.9, 1.0, true, .skip),
            (2.0, 0.004, true, .skip),

            // The same frame is judged differently depending on the mouse.
            (3.0, 0.01, true, .save(reason: .change)),
            (3.0, 0.01, false, .skip),

            // Anchor: past 120 s nothing else matters.
            (120.0, 0.0, false, .save(reason: .anchor)),
            (120.0, 0.0, true, .save(reason: .anchor)),
            (600.0, 0.0, false, .save(reason: .anchor)),
            (120.0, 1.0, false, .save(reason: .anchor))
        ]
    )
    func decides(
        elapsed: TimeInterval,
        changedPct: Double,
        isActive: Bool,
        expected: ScreenshotDecision
    ) {
        let decision = ScreenshotGate.decide(
            isActive: isActive,
            changedPct: changedPct,
            now: Self.at(elapsed),
            lastSavedAt: Self.t0,
            config: Self.config
        )
        #expect(decision == expected)
    }

    @Test("the change reason wins when both an anchor and a change would apply")
    func changeBeforeAnchor() {
        // Below the anchor interval, a qualifying change is reported as a change.
        let decision = ScreenshotGate.decide(
            isActive: false,
            changedPct: 0.9,
            now: Self.at(119),
            lastSavedAt: Self.t0,
            config: Self.config
        )
        #expect(decision == .save(reason: .change))
    }

    @Test("a frame older than the last saved one is skipped")
    func rejectsBackwardsTime() {
        let decision = ScreenshotGate.decide(
            isActive: true,
            changedPct: 1.0,
            now: Self.t0.addingTimeInterval(-10),
            lastSavedAt: Self.t0,
            config: Self.config
        )
        #expect(decision == .skip)
    }

    // MARK: - Stateful gate

    @Test("records the timestamp only for frames it keeps")
    func recordsOnlySaves() {
        var gate = ScreenshotGate()
        #expect(gate.decide(displayID: 1, isActive: false, changedPct: 0, now: Self.at(0)).isSave)
        #expect(gate.lastSavedAt[1] == Self.at(0))

        // Skipped frames must not move the clock forward, or a display that changes a
        // little every second would never reach the threshold.
        #expect(gate.decide(displayID: 1, isActive: false, changedPct: 0.5, now: Self.at(1)) == .skip)
        #expect(gate.lastSavedAt[1] == Self.at(0))

        #expect(
            gate.decide(displayID: 1, isActive: false, changedPct: 0.5, now: Self.at(5))
                == .save(reason: .change)
        )
        #expect(gate.lastSavedAt[1] == Self.at(5))
    }

    @Test("tracks each display on its own clock")
    func perDisplayState() {
        var gate = ScreenshotGate()
        #expect(gate.decide(displayID: 1, isActive: true, changedPct: 0, now: Self.at(0)).isSave)
        // A second display is still on its first frame and saves regardless.
        #expect(
            gate.decide(displayID: 2, isActive: false, changedPct: 0, now: Self.at(1))
                == .save(reason: .anchor)
        )
        // Display 1 is not, and 1 s is too soon even for the active display.
        #expect(gate.decide(displayID: 1, isActive: true, changedPct: 1.0, now: Self.at(1)) == .skip)
    }

    @Test("a static display still gets anchor frames every 120 s")
    func staticDisplayGetsAnchors() {
        var gate = ScreenshotGate()
        var saves: [(TimeInterval, ScreenshotSaveReason)] = []
        // An hour of a monitor that never changes, sampled once a second.
        for second in 0...3600 {
            let decision = gate.decide(
                displayID: 7,
                isActive: false,
                changedPct: 0,
                now: Self.at(TimeInterval(second))
            )
            if let reason = decision.reason { saves.append((TimeInterval(second), reason)) }
        }
        #expect(saves.allSatisfy { $0.1 == .anchor })
        // One at the start, then every 120 s.
        #expect(saves.count == 31)
        #expect(Array(saves.map(\.0).prefix(4)) == [0, 120, 240, 360])
        #expect(saves.last?.0 == 3600)
    }

    @Test("moving the mouse to a display makes it react faster")
    func activeDisplaySwitch() {
        var gate = ScreenshotGate()
        // Both displays anchor on their first frame.
        #expect(gate.decide(displayID: 1, isActive: true, changedPct: 0, now: Self.at(0)).isSave)
        #expect(gate.decide(displayID: 2, isActive: false, changedPct: 0, now: Self.at(0)).isSave)

        // A 1 % change after 3 s: kept on the display with the mouse, skipped on the other.
        #expect(
            gate.decide(displayID: 1, isActive: true, changedPct: 0.01, now: Self.at(3))
                == .save(reason: .change)
        )
        #expect(
            gate.decide(displayID: 2, isActive: false, changedPct: 0.01, now: Self.at(3)) == .skip
        )

        // The mouse moves to display 2; now the same change there is kept.
        #expect(
            gate.decide(displayID: 2, isActive: true, changedPct: 0.01, now: Self.at(4))
                == .save(reason: .change)
        )
        // And display 1, without the mouse, needs 5 s and 2 %.
        #expect(
            gate.decide(displayID: 1, isActive: false, changedPct: 0.01, now: Self.at(6)) == .skip
        )
    }

    @Test("saved frames of one display are never closer than its interval")
    func respectsMinimumSpacing() {
        // Acceptance criterion §11.8: no two images of the same display closer than
        // the configured interval — outside of anchor frames, which are further apart
        // than any interval by construction.
        var gate = ScreenshotGate()
        var lastSave: TimeInterval?
        for tenth in 0...6000 {
            let now = TimeInterval(tenth) / 10
            let decision = gate.decide(
                displayID: 3,
                isActive: false,
                changedPct: 0.9,  // always changing
                now: Self.at(now)
            )
            if decision.isSave {
                if let lastSave { #expect(now - lastSave >= Self.config.normalMinInterval) }
                lastSave = now
            }
        }
    }

    @Test("forgetting a display gives it a fresh anchor frame")
    func forgetDisplay() {
        var gate = ScreenshotGate()
        _ = gate.decide(displayID: 5, isActive: false, changedPct: 0, now: Self.at(0))
        #expect(gate.decide(displayID: 5, isActive: false, changedPct: 0, now: Self.at(1)) == .skip)

        // A display unplugged and plugged back in gets a new CGDirectDisplayID's worth
        // of treatment rather than being judged against a stale timestamp.
        gate.forget(displayID: 5)
        #expect(
            gate.decide(displayID: 5, isActive: false, changedPct: 0, now: Self.at(1))
                == .save(reason: .anchor)
        )

        gate.reset()
        #expect(gate.lastSavedAt.isEmpty)
    }

    @Test("honours a custom configuration")
    func customConfig() {
        let config = ScreenshotGateConfig(
            normalMinInterval: 10,
            activeMinInterval: 1,
            normalMinChange: 0.10,
            activeMinChange: 0.01,
            anchorInterval: 60
        )
        var gate = ScreenshotGate(config: config)
        _ = gate.decide(displayID: 1, isActive: false, changedPct: 0, now: Self.at(0))

        #expect(gate.decide(displayID: 1, isActive: false, changedPct: 0.09, now: Self.at(10)) == .skip)
        #expect(
            gate.decide(displayID: 1, isActive: false, changedPct: 0.10, now: Self.at(10))
                == .save(reason: .change)
        )

        var other = ScreenshotGate(config: config)
        _ = other.decide(displayID: 1, isActive: false, changedPct: 0, now: Self.at(0))
        #expect(
            other.decide(displayID: 1, isActive: false, changedPct: 0, now: Self.at(60))
                == .save(reason: .anchor)
        )
    }

    @Test("can be seeded with existing timestamps")
    func seededState() {
        let gate = ScreenshotGate(lastSavedAt: [1: Self.t0])
        #expect(gate.lastSavedAt[1] == Self.t0)
        #expect(gate.lastSavedAt[2] == nil)
    }

    @Test("the decision exposes its reason")
    func decisionAccessors() {
        #expect(ScreenshotDecision.save(reason: .change).isSave)
        #expect(ScreenshotDecision.save(reason: .change).reason == .change)
        #expect(!ScreenshotDecision.skip.isSave)
        #expect(ScreenshotDecision.skip.reason == nil)
    }
}
