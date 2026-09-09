import AVFoundation
import Foundation
import Testing

@testable import Steno

/// Specification §3b.1 in full. The mode itself is a system-wide setting that lives in
/// Control Center and cannot be set from an app, so the decision is taken over an
/// injected value and only the reading of the real property is left untested.
@Suite("MicrophoneModeCheck")
struct MicrophoneModeCheckTests {
    // MARK: - The decision table

    @Test("wide spectrum records in silence")
    func wideSpectrumProceeds() {
        // Minimal processing, the whole room: exactly what an onsite recording wants,
        // so there is nothing to say about it.
        #expect(MicrophoneModeCheck.decision(for: .wideSpectrum) == .proceed)
    }

    @Test("standard records and puts a hint in the menu")
    func standardHints() throws {
        let decision = MicrophoneModeCheck.decision(for: .standard)
        #expect(decision != .proceed)
        #expect(!decision.isBlocking)
        let hint = try #require(decision.hint)
        #expect(hint == MicrophoneModeCheck.standardHint)
        // The sentence has to name both modes: the one in force and the better one.
        // Compared through the localized display names, not German literals — the
        // test bundle follows the runner's locale and CI runs in English.
        #expect(MicrophoneModeCheck.standardHint.contains(MicrophoneMode.standard.displayName))
        #expect(MicrophoneModeCheck.standardHint.contains(MicrophoneMode.wideSpectrum.displayName))
    }

    @Test("voice isolation blocks")
    func voiceIsolationBlocks() {
        // The whole reason the check exists: macOS damps every voice but the closest,
        // which is the opposite of a room recording. Refusing beats producing a file
        // that looks fine and has no other participants in it.
        #expect(MicrophoneModeCheck.decision(for: .voiceIsolation) == .block)
        #expect(MicrophoneModeCheck.decision(for: .voiceIsolation).isBlocking)
        #expect(MicrophoneModeCheck.decision(for: .voiceIsolation).hint == nil)
    }

    @Test("an unrecognized mode is not treated as hostile")
    func unknownProceeds() {
        // A macOS release adding a fourth mode must not make Steno refuse to record.
        #expect(MicrophoneModeCheck.decision(for: nil) == .proceed)
    }

    @Test("only voice isolation blocks", arguments: MicrophoneMode.allCases)
    func exactlyOneBlockingMode(mode: MicrophoneMode) {
        #expect(MicrophoneModeCheck.decision(for: mode).isBlocking == (mode == .voiceIsolation))
    }

    // MARK: - The strings that end up in the interface and in meta.json

    @Test("the blocked reason is the sentence from the specification")
    func blockedReasonWording() throws {
        // The German catalog is asked for directly: the test bundle follows the
        // runner's locale, and CI runs in English.
        let german = try #require(
            Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:))
        )
        let key = "Sprachisolierung dämpft die anderen Teilnehmer."
        #expect(german.localizedString(forKey: key, value: nil, table: nil) == key)
        #expect(!MicrophoneModeCheck.blockedReason.isEmpty)
        #expect(StartBlocker.voiceIsolationActive.localizedReason == MicrophoneModeCheck.blockedReason)
    }

    @Test("every mode has a name and a meta value", arguments: MicrophoneMode.allCases)
    func modesAreNamed(mode: MicrophoneMode) {
        #expect(!mode.displayName.isEmpty)
        #expect(mode.metaValue == mode.rawValue)
    }

    @Test("the meta values are the ones docs/FORMAT.md lists")
    func metaValues() {
        // These strings are part of the on-disk contract, not interface text: a reader
        // of `meta.input.microphoneMode` matches them literally.
        #expect(MicrophoneMode.standard.metaValue == "standard")
        #expect(MicrophoneMode.wideSpectrum.metaValue == "wideSpectrum")
        #expect(MicrophoneMode.voiceIsolation.metaValue == "voiceIsolation")
    }

    // MARK: - Bridging AVFoundation

    @Test("maps every AVFoundation mode")
    func mapsAVFoundationModes() {
        #expect(MicrophoneMode(AVCaptureDevice.MicrophoneMode.standard) == .standard)
        #expect(MicrophoneMode(AVCaptureDevice.MicrophoneMode.wideSpectrum) == .wideSpectrum)
        #expect(MicrophoneMode(AVCaptureDevice.MicrophoneMode.voiceIsolation) == .voiceIsolation)
    }

    @Test("reading the live mode does not throw or hang")
    func readsTheLiveMode() {
        // Whatever this Mac is set to, both reads have to answer — the menu calls
        // `active()` on every redraw.
        _ = MicrophoneModeCheck.active()
        _ = MicrophoneModeCheck.preferred()
    }
}
