import AppKit
import Foundation
import StenoCore

/// Draws the status-item image for each of the three phases in specification §7.
///
/// The images are built with AppKit rather than assembled from SwiftUI views because a
/// status item wants one `NSImage` of a known size, and because the recording state
/// needs a glyph, a coloured dot, and monospaced digits side by side — which is three
/// draw calls, not a view hierarchy.
///
/// Light and dark are handled by `NSImage(size:flipped:drawingHandler:)`: the handler
/// is invoked again whenever the destination's appearance changes, so
/// `NSColor.labelColor` resolves correctly in both without two sets of assets.
///
/// Nothing here is actor-isolated. `NSImage`'s drawing handler is a plain,
/// non-isolated closure that AppKit may call whenever it needs the bitmap again — on
/// an appearance change, for instance — and every type it touches (`NSImage`,
/// `NSColor`, `NSFont`, `NSBezierPath`) is a drawing type rather than a view.
enum MenuBarIconRenderer {
    /// Menu-bar images are 18 pt tall; anything larger gets clipped by the bar.
    static let height: CGFloat = 18
    /// Point size of the microphone glyph inside that height.
    static let glyphPointSize: CGFloat = 15
    /// Point size of the `mm:ss` text.
    static let clockPointSize: CGFloat = 11
    static let dotDiameter: CGFloat = 5

    /// The image for a phase.
    ///
    /// - Parameters:
    ///   - phase: what Steno is doing.
    ///   - elapsed: seconds recorded so far, for the `mm:ss` text. Ignored otherwise.
    static func image(for phase: AppState.Phase, elapsed: TimeInterval = 0) -> NSImage {
        switch phase {
        case .idle:
            return idleImage()
        case .recording(let mode, _):
            return recordingImage(mode: mode, clock: AppState.clock(elapsed))
        case .processing(let progress, _):
            return processingImage(progress: progress)
        }
    }

    // MARK: - Idle

    /// A microphone outline, as a template image so the menu bar tints it itself.
    static func idleImage() -> NSImage {
        let image = symbol("mic", fallback: "mic.fill")
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Steno: bereit")
        return image
    }

    // MARK: - Recording

    /// A filled microphone, a red dot, `mm:ss`, and for `onsite` a small room glyph.
    ///
    /// This is the one image that is **not** a template. A template image is a single
    /// alpha mask by definition, and specification §7 asks for a red dot — colour and
    /// template are mutually exclusive. Light and dark still work, because the drawing
    /// handler re-runs per appearance and takes the glyph and text colour from
    /// `NSColor.labelColor`.
    static func recordingImage(mode: MeetingMode, clock: String) -> NSImage {
        let mic = symbol("mic.fill", fallback: "mic")
        let room: NSImage? = mode == .onsite ? symbol("person.2.fill", fallback: "person.2") : nil
        let text = clockAttributedString(clock)
        let textSize = text.size()

        let spacing: CGFloat = 3
        var width = mic.size.width
        if let room { width += spacing + room.size.width }
        width += spacing + dotDiameter + spacing + textSize.width

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0

            draw(mic, at: &x, color: .labelColor)
            if let room {
                x += spacing
                draw(room, at: &x, color: .labelColor)
            }

            x += spacing
            // Recording means recording: the dot is red in both appearances, which is
            // the whole reason this image is not a template.
            NSColor.systemRed.setFill()
            let dot = NSRect(
                x: x,
                y: (height - dotDiameter) / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            NSBezierPath(ovalIn: dot).fill()
            x += dotDiameter + spacing

            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = String(
            format: String(localized: "Steno: Aufnahme läuft, %@"),
            clock
        )
        return image
    }

    // MARK: - Processing

    /// A progress ring, drawn with `NSBezierPath` so it needs no asset and no library.
    ///
    /// `progress == nil` means the step has no measurable share yet; the ring then
    /// shows a short arc so it still reads as "busy" rather than as "0 %".
    static func processingImage(progress: Double?) -> NSImage {
        let diameter: CGFloat = 14
        let lineWidth: CGFloat = 2
        let fraction = progress.map { min(max($0, 0), 1) } ?? 0.15

        let image = NSImage(size: NSSize(width: height, height: height), flipped: false) { _ in
            let inset = (height - diameter) / 2 + lineWidth / 2
            let box = NSRect(x: inset, y: inset, width: height - 2 * inset, height: height - 2 * inset)
            let center = NSPoint(x: box.midX, y: box.midY)
            let radius = box.width / 2

            // The track. A quarter of the ink of the arc, so the arc reads as progress
            // against it in either appearance.
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            // The arc, clockwise from twelve o'clock, as every progress ring on the
            // platform runs.
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        // Monochrome, so the menu bar can tint it for light and dark itself.
        image.isTemplate = true
        image.accessibilityDescription = progress
            .map {
                String(
                    format: String(localized: "Steno: Verarbeitung, %d %%"),
                    Int(($0 * 100).rounded())
                )
            }
            ?? String(localized: "Steno: Verarbeitung")
        return image
    }

    // MARK: - Drawing helpers

    private static func clockAttributedString(_ clock: String) -> NSAttributedString {
        NSAttributedString(
            string: clock,
            attributes: [
                // Monospaced digits, or the whole image would resize on every tick.
                .font: NSFont.monospacedDigitSystemFont(ofSize: clockPointSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    /// Draws a glyph at `x` in `color`, advancing `x` past it.
    private static func draw(_ glyph: NSImage, at x: inout CGFloat, color: NSColor) {
        let size = glyph.size
        let rect = NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
        // A template symbol draws as an alpha mask, so compositing the colour on top
        // of it with `.sourceAtop` tints exactly the glyph and nothing around it.
        glyph.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        x += size.width
    }

    /// An SF Symbol at the menu-bar glyph size.
    ///
    /// Both names are checked because a symbol missing at runtime would otherwise
    /// leave the status item with no image at all and no way to click it.
    private static func symbol(_ name: String, fallback: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(configuration) ?? image
        }
        if let image = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(configuration) ?? image
        }
        Log.app.error("SF Symbol \(name, privacy: .public) is unavailable")
        // A filled square is wrong, but it is clickable, which is what matters.
        let placeholder = NSImage(size: NSSize(width: glyphPointSize, height: glyphPointSize), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        placeholder.isTemplate = true
        return placeholder
    }
}
