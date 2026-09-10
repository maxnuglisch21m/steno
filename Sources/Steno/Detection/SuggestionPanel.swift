import AppKit
import Foundation
import Observation
import SwiftUI

/// The suggestion from specification §2: a borderless panel in the top-right corner,
/// above everything, that offers to record the meeting that has just started.
///
/// ```
/// Teams-Meeting erkannt. Aufnehmen und transkribieren?
/// [ Aufnehmen ]  [ Ignorieren ]
/// Teilnehmer informieren.
/// ```
///
/// The headline gains the meeting's name if one turns up while the panel is on screen
/// — `„Weekly Sync“ in Teams erkannt.` — which is what `updateTitle(_:)` is for. It is
/// never waited for: the window title of a Teams call can take eight seconds to
/// appear, and a question asked eight seconds late is a question asked after the
/// meeting has started.
///
/// Three further properties matter and each one is a deliberate choice:
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
    /// The panel's width, which is fixed, and the height its position is measured
    /// from. The height the panel ends up with comes from the text — see `show`.
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
    /// The headline's changing half, so a title that arrives while the panel is up
    /// rewrites the sentence instead of being lost.
    private var content: SuggestionContent?

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

        let content = SuggestionContent(appName: appName, title: title)
        self.content = content
        let view = SuggestionView(
            content: content,
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
        panel.contentView = NSHostingView(rootView: view)
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
        // `Self.size.height` is the reserve the corner is measured from; the panel's
        // actual height comes from the text. `NSHostingView` installs its own intrinsic
        // constraints as the content view, so the window shrinks to fit the headline
        // and keeps its top edge — measured at 320×115 for both wordings, with and
        // without a meeting name in the sentence. That is what makes a headline that
        // gains a title safe: it is laid out again, and the panel follows.
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

    /// Puts the meeting's name into the sentence, if the panel is still up.
    ///
    /// The title search runs beside the panel rather than in front of it, so this is
    /// the ordinary case rather than a special one: the user sees the generic question
    /// first and the named one a few seconds later, and the buttons never move.
    func updateTitle(_ title: String) {
        guard let content, panel != nil, !title.isEmpty else { return }
        content.title = title
        Log.detection.notice("suggestion headline updated with the meeting title")
    }

    /// Whether the headline currently names the meeting. For the tests and the debug
    /// runs; the title itself never leaves this object.
    var showsTitle: Bool { content?.title?.isEmpty == false }

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
        content = nil

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

/// The headline's two halves, observable so the panel can gain the meeting's name
/// without being taken down and put back up.
@MainActor
@Observable
private final class SuggestionContent {
    let appName: String
    var title: String?

    init(appName: String, title: String?) {
        self.appName = appName
        self.title = title
    }
}

/// The panel's content. Specification §2's three lines, and nothing else.
private struct SuggestionView: View {
    @Bindable var content: SuggestionContent
    let record: () -> Void
    let ignore: () -> Void

    private var appName: String { content.appName }
    private var title: String? { content.title }

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

    /// "Teams-Meeting erkannt. Aufnehmen und transkribieren?", or the same question
    /// with the meeting's own name in it once one is known.
    private var headline: String {
        guard let title, !title.isEmpty else {
            return String(
                format: String(localized: "%@-Meeting erkannt. Aufnehmen und transkribieren?"),
                appName
            )
        }
        return String(
            format: String(localized: "„%1$@“ in %2$@ erkannt. Aufnehmen und transkribieren?"),
            title,
            appName
        )
    }
}
