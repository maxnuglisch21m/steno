import AppKit
import StenoCore
import Testing

@testable import Steno

/// The status item has to have an image in every phase — an item without one is
/// invisible and unclickable, which would strand the whole interface.
@Suite("MenuBarIconRenderer")
struct MenuBarIconRendererTests {
    private static let phases: [AppState.Phase] = [
        .idle,
        .recording(mode: .onsite, started: Date()),
        .recording(mode: .online, started: Date()),
        .processing(progress: nil, label: "Verarbeitung"),
        .processing(progress: 0, label: "Verarbeitung"),
        .processing(progress: 0.42, label: "Verarbeitung"),
        .processing(progress: 1, label: "Verarbeitung")
    ]

    @Test("every phase produces a drawable image of menu-bar height")
    func everyPhaseHasAnImage() {
        for phase in Self.phases {
            let image = MenuBarIconRenderer.image(for: phase, elapsed: 754)
            #expect(image.size.height == MenuBarIconRenderer.height)
            #expect(image.size.width > 0)
            // A size alone is not enough: the image has to rasterize.
            #expect(image.tiffRepresentation != nil, "\(phase) should rasterize")
            #expect(!(image.accessibilityDescription ?? "").isEmpty)
        }
    }

    @Test("the monochrome phases are template images, so the menu bar tints them")
    func monochromePhasesAreTemplates() {
        #expect(MenuBarIconRenderer.image(for: .idle).isTemplate)
        #expect(MenuBarIconRenderer.image(for: .processing(progress: 0.5, label: "x")).isTemplate)
    }

    /// Specification §7 asks for a red dot while recording. A template image is a
    /// single alpha mask by definition and cannot carry a colour, so this one image is
    /// not a template — it takes its glyph and text colour from `NSColor.labelColor`
    /// in the drawing handler instead, which is what keeps light and dark working.
    @Test("the recording image is not a template, because the red dot has to stay red")
    func recordingImageIsColoured() {
        let image = MenuBarIconRenderer.image(
            for: .recording(mode: .online, started: Date()),
            elapsed: 12
        )
        #expect(!image.isTemplate)
    }

    @Test("the recording image carries the clock, so it grows past the hour")
    func recordingImageWidthFollowsTheClock() {
        let short = MenuBarIconRenderer.recordingImage(mode: .online, clock: "00:12")
        let long = MenuBarIconRenderer.recordingImage(mode: .online, clock: "1:02:03")
        #expect(long.size.width > short.size.width)
    }

    @Test("an on-site recording is wider than an online one, because of the room glyph")
    func onsiteCarriesARoomGlyph() {
        let online = MenuBarIconRenderer.recordingImage(mode: .online, clock: "12:34")
        let onsite = MenuBarIconRenderer.recordingImage(mode: .onsite, clock: "12:34")
        #expect(onsite.size.width > online.size.width)
    }

    @Test("two clocks of the same length render the same width, so the item does not jitter")
    func clockUsesMonospacedDigits() {
        let a = MenuBarIconRenderer.recordingImage(mode: .online, clock: "00:11")
        let b = MenuBarIconRenderer.recordingImage(mode: .online, clock: "58:07")
        #expect(a.size.width == b.size.width)
    }

    @Test(
        "the clock reads as mm:ss and grows an hours field",
        arguments: [
            (0.0, "00:00"),
            (9.4, "00:09"),
            (59.9, "00:59"),
            (60.0, "01:00"),
            (754.0, "12:34"),
            (3599.0, "59:59"),
            (3600.0, "1:00:00"),
            (3723.0, "1:02:03"),
            (-5.0, "00:00")
        ]
    )
    func clockFormatting(seconds: Double, expected: String) {
        #expect(AppState.clock(seconds) == expected)
    }
}
