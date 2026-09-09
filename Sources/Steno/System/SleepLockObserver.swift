import AppKit
import Foundation

/// Sleep and the lock screen, which are the two ways a recording ends without anyone
/// touching Steno.
///
/// **Sleep.** `NSWorkspace.willSleepNotification` is delivered before the machine
/// suspends, and macOS waits for its observers — briefly, but long enough to close a
/// WAV file properly. A recording that is not stopped here does not pause: the audio
/// hardware stops delivering, the file keeps its unfinished header, and the folder is
/// left for M6's crash recovery to guess at. So the recording is stopped, the reason
/// is written into `meta.json` as `"stopReason": "sleep"`, and the meeting is finished
/// the same way a manual stop would finish it.
///
/// **The lock screen.** `com.apple.screenIsLocked` is a distributed notification, not
/// an `NSWorkspace` one, and it is the only public signal there is. It says nothing
/// about audio — a locked Mac keeps recording the meeting, which is correct — but it
/// does mean the screen shows the lock wallpaper, and M4 has no business writing two
/// hundred screenshots of it. The flag lands in `AppState`; the screenshot capturer
/// reads it.
@MainActor
final class SleepLockObserver {
    /// Called on `willSleepNotification`, before the machine suspends.
    private let onWillSleep: () -> Void
    /// Called when the screen locks and when it unlocks.
    private let onLockChange: (Bool) -> Void

    private var tokens: [any NSObjectProtocol] = []
    private var distributedTokens: [any NSObjectProtocol] = []

    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    init(onWillSleep: @escaping () -> Void, onLockChange: @escaping (Bool) -> Void) {
        self.onWillSleep = onWillSleep
        self.onLockChange = onLockChange
    }

    deinit {
        // Observers outliving their target would fire into a deallocated object on the
        // next lid close. `stop()` is the ordinary path; this is the guarantee.
        MainActor.assumeIsolated { removeObservers() }
    }

    func start() {
        guard tokens.isEmpty, distributedTokens.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(
            workspace.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.app.notice("the Mac is going to sleep")
                    self?.onWillSleep()
                }
            }
        )

        let distributed = DistributedNotificationCenter.default()
        for (name, isLocked) in [
            (Self.screenLockedNotification, true),
            (Self.screenUnlockedNotification, false)
        ] {
            distributedTokens.append(
                distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        Log.app.notice("screen \(isLocked ? "locked" : "unlocked", privacy: .public)")
                        self?.onLockChange(isLocked)
                    }
                }
            )
        }
        Log.app.debug("sleep and lock observers installed")
    }

    func stop() {
        removeObservers()
    }

    private func removeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for token in tokens { workspace.removeObserver(token) }
        tokens.removeAll()

        let distributed = DistributedNotificationCenter.default()
        for token in distributedTokens { distributed.removeObserver(token) }
        distributedTokens.removeAll()
    }
}
