import AppKit
import Carbon.HIToolbox
import Foundation

/// The three global hotkeys from specification §7: ⌥⌘R, ⌥⌘V, ⌥⌘S.
///
/// **Why Carbon.** `RegisterEventHotKey` is the only system API that delivers a key
/// combination to an app that is not frontmost. The alternatives are worse: a SwiftUI
/// `.keyboardShortcut` on a menu item only fires while that menu is open, and
/// `NSEvent.addGlobalMonitorForEvents` needs Accessibility permission — a fourth TCC
/// prompt, for something the user did not ask for. Carbon's hotkey API is old, but it
/// ships in the system, it is not deprecated, and it needs no third-party code and no
/// extra permission. It stays in this one file so the rest of the app never sees it.
///
/// The shortcuts have to work while the menu is closed — that is the entire point of
/// "start recording" being a hotkey — so registration happens at launch and is undone
/// on quit rather than being tied to a window.
@MainActor
final class HotKeys {
    enum Action: UInt32, Sendable, CaseIterable {
        /// ⌥⌘R — start an online meeting.
        case startOnline = 1
        /// ⌥⌘V — start an on-site meeting.
        case startOnsite = 2
        /// ⌥⌘S — stop the recording.
        case stop = 3

        /// The virtual key code, from `Carbon.HIToolbox`'s `kVK_ANSI_*`.
        var keyCode: UInt32 {
            switch self {
            case .startOnline: return UInt32(kVK_ANSI_R)
            case .startOnsite: return UInt32(kVK_ANSI_V)
            case .stop: return UInt32(kVK_ANSI_S)
            }
        }

        /// ⌥⌘ for all three. Carbon wants its own modifier bits, not `NSEvent`'s.
        var modifiers: UInt32 { UInt32(optionKey | cmdKey) }

        var shortcutDescription: String {
            switch self {
            case .startOnline: return "⌥⌘R"
            case .startOnsite: return "⌥⌘V"
            case .stop: return "⌥⌘S"
            }
        }
    }

    /// A four-character signature identifying our hotkeys among everyone else's.
    /// `'Sten'`, spelled out because `OSType` literals are not a thing in Swift.
    private static let signature: OSType = {
        let bytes: [UInt8] = Array("Sten".utf8)
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    private var registrations: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var box: Dispatcher?

    /// The `OSStatus` each `RegisterEventHotKey` returned, in `Action` order. All
    /// zeroes is the pass criterion, and it is logged at launch so a failure to
    /// register — usually another app holding the same combination — is visible.
    private(set) var registrationStatuses: [Action: OSStatus] = [:]

    /// Whether every hotkey took.
    var allRegistered: Bool {
        registrationStatuses.count == Action.allCases.count
            && registrationStatuses.values.allSatisfy { $0 == noErr }
    }

    init() {}

    // MARK: - Registration

    /// Installs the event handler and registers all three hotkeys.
    ///
    /// - Parameter handler: run on the main actor when a hotkey fires.
    func register(handler: @escaping @Sendable @MainActor (Action) -> Void) {
        guard eventHandler == nil else { return }

        let dispatcher = Dispatcher(handler: handler)
        box = dispatcher

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The callback is a C function pointer and can capture nothing, so the
        // dispatcher is passed through `userData` as an unretained pointer. `box`
        // above owns it, and `unregister()` outlives every event that could arrive.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr else { return result }
                Unmanaged<Dispatcher>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .fire(rawAction: hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(dispatcher).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            Log.app.error("hotkey event handler could not be installed: \(status, privacy: .public)")
            box = nil
            return
        }

        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let registerStatus = RegisterEventHotKey(
                action.keyCode,
                action.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            registrationStatuses[action] = registerStatus
            if registerStatus == noErr {
                registrations.append(reference)
            } else {
                Log.app.error(
                    """
                    hotkey \(action.shortcutDescription, privacy: .public) not registered, \
                    status \(registerStatus, privacy: .public) — another app may hold it
                    """
                )
            }
        }

        Log.app.notice(
            """
            hotkeys registered: \
            \(Action.allCases.map { "\($0.shortcutDescription)=\(self.registrationStatuses[$0] ?? -1)" }
                .joined(separator: " "), privacy: .public)
            """
        )
    }

    /// Releases the hotkeys and the handler. Called when the app quits, so the
    /// combinations go back to whoever wants them next.
    func unregister() {
        for reference in registrations {
            if let reference { UnregisterEventHotKey(reference) }
        }
        registrations.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        registrationStatuses.removeAll()
        box = nil
        Log.app.debug("hotkeys unregistered")
    }

    /// Carries the handler across the C callback boundary.
    ///
    /// The Carbon callback runs on the main thread, but it is a C function pointer
    /// with no isolation the compiler can see, so the hop to the main actor is
    /// explicit. `Task` rather than `assumeIsolated`, because starting a recording is
    /// not something to do inside an event-handler frame.
    private final class Dispatcher: Sendable {
        private let handler: @Sendable @MainActor (Action) -> Void

        init(handler: @escaping @Sendable @MainActor (Action) -> Void) {
            self.handler = handler
        }

        func fire(rawAction: UInt32) {
            guard let action = Action(rawValue: rawAction) else { return }
            let handler = self.handler
            Task { @MainActor in handler(action) }
        }
    }
}
