import Foundation
import Testing

@testable import Steno

/// Which member of the `online` aggregate device keeps time.
///
/// The decision is a pure function of the microphone's nominal sample rate, which is
/// the only way it can be checked at all: reproducing it for real needs a Bluetooth
/// headset in its hands-free profile, and a test machine has neither.
@Suite("Aggregate clock")
struct AggregateClockTests {
    @Test("a 48 kHz microphone keeps the clock, as it always did")
    func fullRateMicLeads() {
        #expect(AggregateClock.master(micSampleRate: 48_000) == .microphone)
    }

    @Test("a microphone above 48 kHz keeps it too")
    func higherRateMicLeads() {
        #expect(AggregateClock.master(micSampleRate: 96_000) == .microphone)
        #expect(AggregateClock.master(micSampleRate: 192_000) == .microphone)
    }

    @Test("a Bluetooth headset at 16 kHz hands the clock to the tap")
    func bluetoothHandsOver() {
        // The Poly BT700 in a Teams call, which is the recording this exists for.
        #expect(AggregateClock.master(micSampleRate: 16_000) == .tap)
    }

    @Test("everything below 48 kHz hands the clock to the tap")
    func anySlowMicHandsOver() {
        for rate in [8_000.0, 16_000, 22_050, 24_000, 32_000, 44_100, 47_999] {
            #expect(AggregateClock.master(micSampleRate: rate) == .tap)
        }
    }

    @Test("a device that will not say its rate keeps the arrangement that works")
    func unknownRateChangesNothing() {
        // An unknown rate is not evidence of a slow one, and rearranging the clock on
        // no evidence is how a working recording breaks.
        #expect(AggregateClock.master(micSampleRate: 0) == .microphone)
        #expect(AggregateClock.master(micSampleRate: -1) == .microphone)
    }

    @Test("the target is the rate the file is written at")
    func targetIsTheFileRate() {
        #expect(AggregateClock.targetSampleRate == WAVWriter.sampleRate)
        // And the boundary is exact: 48 kHz leads, a hair under does not.
        #expect(AggregateClock.master(micSampleRate: 44_100, target: 44_100) == .microphone)
        #expect(AggregateClock.master(micSampleRate: 44_100, target: 48_000) == .tap)
    }
}
