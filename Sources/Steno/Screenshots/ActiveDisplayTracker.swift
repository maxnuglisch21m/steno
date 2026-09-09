import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// Which display the mouse is on. Specification §4.5: that display gets the shorter
/// interval and the lower change threshold, because it is where the meeting is
/// actually happening.
///
/// The specification's route is `NSEvent.mouseLocation` → the matching `NSScreen` →
/// `deviceDescription["NSScreenNumber"]`, and that is what this does — with one
/// change forced by where it is called from. The answer is needed once per candidate
/// frame, on the capture queue, and `NSScreen.screens` is main-thread-only, so the
/// screen list is snapshotted on the main actor and refreshed when the screen
/// arrangement changes. Only the pointer position is read live, which is what has to
/// be live: a snapshot of it would be wrong by the time the frame is decided.
///
/// Reading it per frame rather than caching it is deliberate and cheap — the
/// specification says "bei jedem gespeicherten Frame neu prüfen", and the whole thing
/// is an unfair-lock read plus a handful of rectangle tests.
final class ActiveDisplayTracker: Sendable {
    /// One display's screen rectangle, in the bottom-left-origin coordinate space
    /// `NSEvent.mouseLocation` reports in.
    struct Screen: Sendable, Hashable {
        var displayID: CGDirectDisplayID
        var frame: CGRect
    }

    private let screens = Mutex<[Screen]>([])

    init() {}

    /// Re-reads `NSScreen.screens`. Called at start and on every screen-parameter
    /// change; nothing else may touch `NSScreen`.
    @MainActor
    func refresh() {
        let snapshot = NSScreen.screens.compactMap { screen -> Screen? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else { return nil }
            return Screen(displayID: CGDirectDisplayID(number.uint32Value), frame: screen.frame)
        }
        screens.withLock { $0 = snapshot }
        Log.screens.debug("active-display tracker knows \(snapshot.count, privacy: .public) screens")
    }

    /// The display holding the pointer, or `nil` when the pointer is on no known
    /// screen — which happens for a moment while a display is being reconfigured.
    ///
    /// Safe to call from any thread.
    func activeDisplayID() -> CGDirectDisplayID? {
        // Documented as usable off the main thread: it asks the window server for the
        // current cursor location and touches no AppKit state.
        let point = NSEvent.mouseLocation
        return screens.withLock { screens in
            screens.first { $0.frame.contains(point) }?.displayID
        }
    }

    /// Whether the pointer is on `displayID` right now.
    func isActive(_ displayID: CGDirectDisplayID) -> Bool {
        activeDisplayID() == displayID
    }

    /// The snapshot, for the tests and for the debug log line.
    var knownScreens: [Screen] { screens.withLock { $0 } }

    /// Replaces the snapshot without touching `NSScreen`. Tests only.
    func override(_ snapshot: [Screen]) {
        screens.withLock { $0 = snapshot }
    }
}
