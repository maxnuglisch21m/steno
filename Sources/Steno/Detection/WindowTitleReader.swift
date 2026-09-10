import AppKit
import CoreGraphics
import Foundation
import StenoCore

/// Reads the meeting name off the triggering app's windows.
///
/// Detection is Core-Audio-only and knows the app but not the meeting, and
/// `CGWindowListCopyWindowInfo` is where the meeting's name is written down without
/// asking anyone's calendar. It works well for Teams (`Weekly Sync | Microsoft Teams`)
/// and for a browser tab; Zoom writes nothing but `Zoom Meeting`, and Google Meet
/// writes the room code — which is what `MeetingTitleCleaner.isGeneric` is for, and
/// which is simply the case where a meeting has no name: the folder is then named after
/// the app, and nothing else changes, because nothing waits for this any more.
///
/// Needs Screen Recording. Without it macOS still returns the window list, but with
/// every `kCGWindowName` removed, so the reader would silently see nothing but empty
/// titles; `CGPreflightScreenCaptureAccess()` is checked first so that "no permission"
/// and "no title" are not the same answer. Preflight never prompts.
@MainActor
enum WindowTitleReader {
    /// How long the title is chased after the trigger fires.
    ///
    /// Teams shows a pre-join window whose title is the app's name and only renames it
    /// once the call is actually joined, so the first read is routinely useless. Ten
    /// seconds is the plan's figure; the search stops the moment a usable title
    /// appears, which for a joined Teams call is the first attempt.
    ///
    /// Nobody waits for it. `MeetingDetectionController` shows the suggestion first and
    /// runs this beside it — which is what makes ten seconds an acceptable budget
    /// rather than ten seconds of the user staring at nothing while their meeting
    /// starts.
    static let searchTimeout: TimeInterval = 10
    /// How long to wait between attempts.
    static let searchInterval: Duration = .seconds(2)

    /// Whether titles can be read at all.
    static var isAvailable: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - One pass

    /// Every window title belonging to these processes, largest window first.
    ///
    /// Filtered the way the plan describes: on-screen windows, desktop elements
    /// excluded, layer 0 only — which drops menu-bar items, tooltips, and the floating
    /// call banner Teams puts in front of everything — and a non-empty name.
    ///
    /// Sorted by area, because the meeting window is the big one and the notification
    /// that happens to be in front of it is not.
    static func titles(forPIDs pids: [pid_t]) -> [String] {
        guard !pids.isEmpty, isAvailable else { return [] }
        let wanted = Set(pids.map { Int($0) })
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        struct Candidate {
            var title: String
            var area: Double
        }

        let candidates: [Candidate] = raw.compactMap { window in
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                wanted.contains(ownerPID),
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let name = window[kCGWindowName as String] as? String,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? Double) ?? 0
            let height = (bounds?["Height"] as? Double) ?? 0
            return Candidate(title: name, area: width * height)
        }

        return candidates
            .sorted { $0.area > $1.area }
            .map(\.title)
    }

    /// The best title these processes offer right now, decoration removed, or `nil`
    /// when they offer nothing but the app's own name.
    static func title(forPIDs pids: [pid_t]) -> String? {
        MeetingTitleCleaner.best(of: titles(forPIDs: pids))
    }

    // MARK: - Chasing the title

    /// Reads the title repeatedly until it says something, or until the budget runs out.
    ///
    /// - Parameters:
    ///   - pids: the detected meeting's processes.
    ///   - refresh: asked before each retry for an up-to-date process list, because a
    ///     browser opens a new helper for the call after the trigger has already fired.
    ///   - timeout: total budget. The first attempt is immediate, so a timeout of zero
    ///     still reads once.
    /// - Returns: a usable meeting title, or `nil`.
    static func resolveTitle(
        forPIDs pids: [pid_t],
        refresh: (() -> [pid_t])? = nil,
        timeout: TimeInterval = searchTimeout,
        interval: Duration = searchInterval
    ) async -> String? {
        guard isAvailable else {
            Log.detection.notice("no Screen Recording permission; window titles are not read")
            return nil
        }
        var current = pids
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var attempt = 0
        while true {
            attempt += 1
            if let title = title(forPIDs: current) {
                // The title itself is never logged: specification-adjacent rule from
                // `Log`, "no window titles". How long it took is fair game.
                Log.detection.info("window title found on attempt \(attempt, privacy: .public)")
                return title
            }
            guard ContinuousClock.now < deadline else {
                Log.detection.info(
                    "no usable window title after \(attempt, privacy: .public) attempts"
                )
                return nil
            }
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return nil }
            if let refresh { current = refresh() }
        }
    }
}
