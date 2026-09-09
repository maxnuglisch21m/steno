import AVFoundation
import Foundation
import Observation

/// One selectable audio input.
struct AudioInputDevice: Sendable, Hashable, Identifiable {
    /// `AVCaptureDevice.uniqueID`. Stable across reboots, which is why it and not the
    /// name is what gets stored in the settings.
    var uid: String
    var name: String

    var id: String { uid }
}

/// The audio inputs the Mac currently has, kept up to date.
///
/// Specification §3b.2 calls the input device the most effective quality lever there
/// is for a room recording, and it costs nothing in code — a boundary microphone on
/// the table beats any amount of model tuning. So every device is offered, not just
/// the built-in array, and the list refreshes when hardware is plugged in or pulled
/// out while the settings window is open.
@MainActor
@Observable
final class AudioInputDeviceList {
    private(set) var devices: [AudioInputDevice] = []

    private var observers: [any NSObjectProtocol] = []

    init() {
        refresh()
    }

    func refresh() {
        devices = AudioInputDevices.available()
    }

    /// Starts watching for hardware changes. Called when the settings window opens.
    ///
    /// The observers are never removed: this list is owned by `AppEnvironment` and
    /// lives as long as the app, so there is nothing to tear down and no window in
    /// which a notification could arrive for a deallocated observer.
    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` guarantees this runs on the main thread, which is
                // where the main actor is; the compiler cannot see that through
                // `NotificationCenter`'s non-isolated closure, so it is stated here.
                MainActor.assumeIsolated {
                    AudioInputDevices.invalidateCache()
                    self?.refresh()
                }
            }
            observers.append(observer)
        }
    }

    /// The name to show for the stored UID, whether or not that device is attached.
    func displayName(forUID uid: String?) -> String {
        AudioInputDevices.displayName(forUID: uid, in: devices)
    }
}

/// Enumerating audio inputs, without any state of its own.
enum AudioInputDevices {
    /// The label for "whatever macOS considers the input right now".
    static var systemDefaultName: String {
        String(localized: "Systemvorgabe")
    }

    /// A cache, because a recorder asks for the device name at the moment it starts —
    /// off the main actor — and `AVCaptureDevice.devices(for:)` is not free.
    ///
    /// `nonisolated(unsafe)` rather than an actor because every access in this file
    /// goes through `cacheLock`, which is what makes it safe; an actor would force the
    /// recorder's `start` to await a hop for a string it needs synchronously.
    private nonisolated(unsafe) static var cache: [AudioInputDevice]?
    private static let cacheLock = NSLock()

    static func available() -> [AudioInputDevice] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache { return cache }
        // `AVCaptureDevice.devices(for:)` is what the specification names, but it has
        // been deprecated since macOS 10.15; a discovery session is the same list.
        // `.external` is in there alongside `.microphone` because a USB boundary
        // microphone — the device §3b.2 is actually about — reports as one.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let discovered = session.devices.map {
            AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName)
        }
        Log.audio.debug("audio inputs found: \(discovered.count, privacy: .public)")
        cache = discovered
        return discovered
    }

    static func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    /// The device macOS would pick on its own.
    static func systemDefault() -> AudioInputDevice? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        return AudioInputDevice(uid: device.uniqueID, name: device.localizedName)
    }

    /// A name for `meta.json` and for the settings window.
    ///
    /// A stored UID whose device is no longer attached still gets a name — the UID
    /// itself — rather than silently reading as the system default, because a
    /// recording made on a different microphone than the one that was configured is
    /// worth being able to see afterwards.
    static func displayName(
        forUID uid: String?,
        in devices: [AudioInputDevice]? = nil
    ) -> String {
        guard let uid else {
            return systemDefault()?.name ?? systemDefaultName
        }
        let list = devices ?? available()
        if let match = list.first(where: { $0.uid == uid }) { return match.name }
        return uid
    }
}
