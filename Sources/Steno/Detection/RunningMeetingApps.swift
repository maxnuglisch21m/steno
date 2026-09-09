import CoreAudio
import Foundation
import StenoCore

/// One process as Core Audio sees it. Specification §2, step 2.
///
/// A value type rather than a handle, so the filtering below is a pure function over
/// a list that a test can write by hand — the HAL is asked for the list in exactly one
/// place, `current()`.
struct AudioProcessDescriptor: Sendable, Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    /// `kAudioProcessPropertyBundleID`. Absent for processes without a bundle, which
    /// is most of the system's audio plumbing.
    var bundleId: String?
    /// `kAudioProcessPropertyIsRunningInput` — whether it is reading a microphone
    /// right now. This is the signal the whole of detection rests on.
    var isRunningInput: Bool

    init(objectID: AudioObjectID = .unknown, pid: pid_t, bundleId: String?, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleId = bundleId
        self.isRunningInput = isRunningInput
    }
}

/// Which watchlist app, if any, is in a meeting right now.
///
/// M3 turns this into detection proper — listeners, the five-second debounce, the
/// suggestion popup. M2 needs one much smaller thing from it: when the user starts an
/// `online` recording by hand, what should the tap point at? Tapping the app that is
/// actually in a meeting gives a clean ch0 with nothing but the meeting in it, which
/// is worth a great deal more than a system-wide tap that also records the music the
/// user forgot was playing.
enum RunningMeetingApps {
    /// A watchlist app that is reading the microphone, with every process of it that is.
    struct Match: Sendable, Equatable {
        /// Every process belonging to `app` that is reading input, in the order the
        /// HAL listed them. Never empty.
        var processes: [AudioProcessDescriptor]
        var app: WatchedApp

        /// The first of them. Kept because most callers want one PID and because the
        /// HAL lists the parent before its helpers.
        var process: AudioProcessDescriptor { processes[0] }

        var pids: [pid_t] { processes.map(\.pid) }
    }

    // MARK: - The filter (pure)

    /// Every watchlist app currently reading input, in watchlist order, at most once
    /// each.
    ///
    /// One app can own several audio process objects — a browser runs its audio in a
    /// helper process, and both may carry the same bundle identifier — so matches are
    /// collapsed per app. Two *different* watchlist apps reading input at the same
    /// time is the ambiguous case, and the one this function exists to expose.
    static func matches(
        in processes: [AudioProcessDescriptor],
        watchlist: [WatchedApp]
    ) -> [Match] {
        watchlist.compactMap { app in
            let owned = processes.filter { process in
                guard process.isRunningInput, let bundleId = process.bundleId else { return false }
                return app.matches(processBundleId: bundleId)
            }
            return owned.isEmpty ? nil : Match(processes: owned, app: app)
        }
    }

    /// Every process belonging to a watchlist app, whether or not it is reading input.
    ///
    /// This is what a tap target is built from: the app is in a meeting because *one*
    /// of its processes reads the microphone, but the meeting is played back through
    /// whichever process it likes, so the tap has to cover all of them.
    static func processes(
        of app: WatchedApp,
        in processes: [AudioProcessDescriptor]
    ) -> [AudioProcessDescriptor] {
        processes.filter { process in
            guard let bundleId = process.bundleId else { return false }
            return app.matches(processBundleId: bundleId)
        }
    }

    /// The one watchlist app in a meeting, or `nil` when there is none or more than
    /// one.
    ///
    /// Ambiguity resolves to `nil` on purpose: with Teams and Zoom both live, a guess
    /// records the wrong one and nobody finds out until the transcript is empty. The
    /// caller falls back to a system-wide tap, which captures both.
    static func soleMatch(
        in processes: [AudioProcessDescriptor],
        watchlist: [WatchedApp]
    ) -> Match? {
        let found = matches(in: processes, watchlist: watchlist)
        return found.count == 1 ? found[0] : nil
    }

    /// The tap target for a manual `online` start: the single meeting app if there is
    /// one, and everything the Mac is playing if there is not.
    static func target(
        in processes: [AudioProcessDescriptor],
        watchlist: [WatchedApp]
    ) -> TapTarget {
        guard let match = soleMatch(in: processes, watchlist: watchlist) else { return .systemWide }
        return target(for: match.app, in: processes)
    }

    /// The tap target for one watchlist app: every process it owns.
    ///
    /// Falls back to a system-wide tap when the app has no audio process left at all —
    /// which happens when the meeting ended between the trigger and the start, and
    /// when a detection was injected for an app that is not running.
    static func target(
        for app: WatchedApp,
        in processes: [AudioProcessDescriptor]
    ) -> TapTarget {
        let owned = self.processes(of: app, in: processes)
        guard !owned.isEmpty else { return .systemWide }
        return .process(pids: owned.map(\.pid), bundleId: app.bundleId, name: app.name)
    }

    /// The tap target for one named bundle identifier, whether or not it is on the
    /// watchlist and whether or not it is reading input.
    ///
    /// Used by `--tap-target`, and by nothing else: forcing a target is a debugging
    /// affordance, not a recording mode.
    static func target(
        forBundleId bundleId: String,
        in processes: [AudioProcessDescriptor],
        watchlist: [WatchedApp]
    ) -> TapTarget? {
        let owned = processes.filter {
            guard let candidate = $0.bundleId else { return false }
            return WatchedApp.matches(watchedBundleId: bundleId, processBundleId: candidate)
        }
        guard !owned.isEmpty else { return nil }
        let name = watchlist.first { $0.bundleId == bundleId }?.name
            ?? String(bundleId.split(separator: ".").last ?? "App")
        return .process(pids: owned.map(\.pid), bundleId: bundleId, name: name)
    }

    // MARK: - Asking Core Audio

    /// Reads the process list from the HAL. The only impure part of this file.
    ///
    /// A process object whose properties cannot be read is skipped rather than
    /// failing the whole list: processes come and go while the list is being walked,
    /// and one that ended half a millisecond ago is not an error.
    static func current() -> [AudioProcessDescriptor] {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioObjectID.processObjectList()
        } catch {
            Log.detection.error("could not read the process list: \(String(describing: error), privacy: .public)")
            return []
        }
        return objectIDs.compactMap { objectID in
            guard let pid: pid_t = try? objectID.read(
                kAudioProcessPropertyPID,
                defaultValue: pid_t(-1),
                what: "reading a process PID"
            ), pid > 0 else { return nil }
            let bundleId = try? objectID.readString(
                kAudioProcessPropertyBundleID,
                what: "reading a process bundle identifier"
            )
            let isRunningInput = (try? objectID.readBool(
                kAudioProcessPropertyIsRunningInput,
                what: "reading whether a process reads input"
            )) ?? false
            return AudioProcessDescriptor(
                objectID: objectID,
                pid: pid,
                bundleId: (bundleId?.isEmpty ?? true) ? nil : bundleId,
                isRunningInput: isRunningInput
            )
        }
    }

    /// What a manual `online` start should tap, asked of the live system.
    static func currentTarget(watchlist: [WatchedApp]) -> TapTarget {
        let processes = current()
        let target = target(in: processes, watchlist: watchlist)
        switch target {
        case .process(_, let bundleId, let name):
            Log.detection.notice(
                """
                tapping \(name, privacy: .public) (\(bundleId, privacy: .public)) — \
                the only watchlist app reading input
                """
            )
        case .systemWide:
            let live = matches(in: processes, watchlist: watchlist).count
            Log.detection.notice(
                "tapping the whole system: \(live, privacy: .public) watchlist apps are reading input"
            )
        }
        return target
    }
}
