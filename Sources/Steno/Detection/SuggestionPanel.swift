import AppKit
import Foundation
import SwiftUI

/// The suggestion from specification §2: a borderless panel in the top-right corner,
/// above everything, that offers to record the meeting that has just started.
///
/// ```
/// Teams-Meeting läuft. Aufnehmen?          („Weekly Sync“ läuft in Teams. Aufnehmen?)
/// [ Aufnehmen ]  [ Ignorieren ]
/// Teilnehmer informieren.
/// ```
///
/// Three properties matter and each one is a deliberate choice:
///
/// - **It does not steal focus.** `.nonactivatingPanel` plus `NSApp` never being
///   activated means the meeting keeps the keyboard: a panel that pulled focus out of
///   Teams while the user was typing a greeting would be worse than no panel at all.
///   The panel still becomes key, which is what makes Return and Escape work.
/// - **It goes away by itself.** Twenty seconds without a click is an answer, and the
///   answer is no (specification §2). Nobody has to dismiss anything.
/// - **It says "tell the participants".** Not decoration: recording a meeting without
///   saying so is illegal in most of Europe, and the one place to put that sentence is
///   the moment recording is offered.
@MainActor
final class SuggestionPanel {
    static let shared = SuggestionPanel()

    /// How long the panel stays up without an answer. Specification §2.
    static let defaultTimeout: TimeInterval = 20
    /// Distance from the top and right edges of the usable screen.
    static let margin: CGFloat = 12
    static let size = NSSize(width: 320, height: 132)
    private static let fadeDuration: TimeInterval = 0.15

    /// What the user said, or what the clock said for them.
    enum Answer: String, Sendable, Equatable {
        case record
        case ignore
    }

    private var panel: NSPanel?
    private var timeoutTask: Task<Void, Never>?
    private var answer: ((Answer) -> Void)?

    /// Whether a suggestion is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// The panel's frame, for the debug log — the one way to check the placement from
    /// outside without looking at the screen.
    var frameDescription: String? {
        guard let panel else { return nil }
        let frame = panel.frame
        return "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }

    private init() {}

    // MARK: - Showing

    /// Shows the suggestion. A second call replaces whatever was up, answering the
    /// first with `ignore` so no caller is left waiting for a click that can no longer
    /// happen.
    func show(
        appName: String,
        title: String?,
        timeout: TimeInterval = SuggestionPanel.defaultTimeout,
        onAnswer: @escaping (Answer) -> Void
    ) {
        if panel != nil { finish(.ignore) }
        answer = onAnswer

        let content = SuggestionView(
            appName: appName,
            title: title,
            record: { [weak self] in self?.finish(.record) },
            ignore: { [weak self] in self?.finish(.ignore) }
        )

        let panel = SuggestionNSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onReturn = { [weak self] in self?.finish(.record) }
        panel.onEscape = { [weak self] in self?.finish(.ignore) }
        panel.contentView = NSHostingView(rootView: content)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the menu bar's own status items, so a meeting that starts while a menu
        // is open is still visible.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Visible on every Space and over a full-screen app, which is where a meeting
        // usually is. `.stationary` keeps it from sliding around during Space changes.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .utilityWindow
        panel.setFrameOrigin(Self.origin(for: Self.size))
        panel.alphaValue = 0
        self.panel = panel

        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`, then key
        // separately: the app is an accessory and must not be activated, but the panel
        // does need to be key for Return and Escape to reach it.
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }

        Log.detection.notice(
            """
            suggestion shown for \(appName, privacy: .public) \
            (\(title == nil ? "no title" : "with title", privacy: .public)) at \
            \(self.frameDescription ?? "?", privacy: .public), \(Int(timeout), privacy: .public) s
            """
        )

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            Log.detection.notice("suggestion timed out; treated as ignore")
            self?.finish(.ignore)
        }
    }

    /// Takes the panel down without answering. Used when a recording started some
    /// other way and the question no longer means anything.
    func dismiss() {
        finish(nil)
    }

    #if DEBUG
    /// Answers the panel from the outside. `--auto-answer` and nothing else.
    func answerForTesting(_ value: Answer) {
        finish(value)
    }
    #endif

    // MARK: - Answering

    private func finish(_ value: Answer?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let callback = answer
        answer = nil

        if let panel {
            self.panel = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            } completionHandler: {
                // `NSAnimationContext` calls this back on the main thread but types it
                // as a plain closure, so the isolation has to be asserted rather than
                // hopped through a `Task` that would leave the panel on screen for
                // another turn of the run loop.
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.contentView = nil
                }
            }
        }
        if let value { callback?(value) }
    }

    // MARK: - Placement

    /// Top-right of the screen that has the menu bar, inside the usable area.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, so the margin is
    /// measured from what the user can actually see rather than from the glass edge.
    static func origin(for size: NSSize) -> NSPoint {
        let screen = menuBarScreen
        guard let visible = screen?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
    }

    /// The screen with the menu bar on it: the one whose frame starts at the origin.
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// A panel that can hold the keyboard without its app being activated.
///
/// `NSPanel` refuses to become key by default when it has no title bar, which would
/// leave Return and Escape doing nothing. Overriding `canBecomeKey` is the documented
/// way round it, and `.nonactivatingPanel` in the style mask is what keeps the app
/// itself in the background while it happens.
private final class SuggestionNSPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            onReturn?()
        case 53:  // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Escape also arrives here, via the responder chain, when a control has focus.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// The panel's content. Specification §2's three lines, and nothing else.
private struct SuggestionView: View {
    let appName: String
    let title: String?
    let record: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(String(localized: "Aufnehmen"), action: record)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "Ignorieren"), action: ignore)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
            }

            Text(String(localized: "Teilnehmer informieren."))
                .font(.footnote)
                .italic()
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: SuggestionPanel.size.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    /// "Teams-Meeting läuft. Aufnehmen?", or the same sentence with the meeting's own
    /// name in it once one is known.
    private var headline: String {
        guard let title, !title.isEmpty else {
            return String(
                format: String(localized: "%@-Meeting läuft. Aufnehmen?"),
                appName
            )
        }
        return String(
            format: String(localized: "„%1$@“ läuft in %2$@. Aufnehmen?"),
            title,
            appName
        )
    }
}
