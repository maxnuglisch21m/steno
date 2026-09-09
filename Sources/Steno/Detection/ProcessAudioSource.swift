import CoreAudio
import Foundation
import StenoCore

/// Where detection's picture of "who is reading the microphone" comes from.
///
/// One protocol with two implementations, for the same reason `AudioRecorder` has
/// three: the interesting half of detection is timing, and timing tested against a
/// real Mac means starting Teams and waiting. `CoreAudioProcessSource` is the real
/// thing (specification §2, steps 1–3); `FakeProcessAudioSource` is a list a test or
/// `--simulate-detection` writes by hand.
///
/// Main-actor isolated throughout. Core Audio delivers its listener blocks on a
/// dispatch queue of its own choosing, and the hop happens inside the source, so that
/// nothing above it ever has to think about which thread it is on.
@MainActor
protocol ProcessAudioSource: AnyObject {
    /// Every audio process the system knows about right now, with the three properties
    /// specification §2 asks for.
    func snapshot() -> [AudioProcessDescriptor]

    /// Begins reporting changes. `onChange` runs on the main actor, once per change,
    /// and says nothing about what changed — the caller re-reads the snapshot.
    func start(onChange: @escaping @MainActor () -> Void)

    /// Stops reporting and removes every listener.
    func stop()

    /// Whether changes actually arrive by themselves.
    ///
    /// `false` means the caller has to poll, and is worth a line in the log: it is the
    /// difference between detection that reacts in milliseconds and detection that
    /// reacts within a couple of seconds.
    var isEventDriven: Bool { get }
}

/// The real source: the HAL's process list, plus a listener on every watched process.
///
/// Specification §2, step 3 — "Event-getrieben, kein Polling", with a poll allowed as
/// a first cut. Both are here: the listeners are installed and, if the HAL refuses
/// them, `isEventDriven` says so and `MeetingDetector` falls back to its two-second
/// poll instead. Nothing about the detector's behaviour changes either way; only how
/// quickly it notices.
///
/// Two kinds of listener are installed:
///
/// 1. `kAudioHardwarePropertyProcessObjectList` on the system object, which fires when
///    a process starts or stops using audio at all. Steno then re-syncs the second
///    kind, because the set of objects to watch has changed.
/// 2. `kAudioProcessPropertyIsRunningInput` on every process object, which is the
///    actual signal: this app just started, or stopped, reading a microphone.
///
/// The second set is installed on *every* process rather than only on watchlist
/// members, because a process object exists before its bundle identifier can be read
/// reliably and because an app can start using audio at any time; there are a few
/// dozen of them on a busy Mac, and a property listener costs nothing while it is
/// quiet.
@MainActor
final class CoreAudioProcessSource: ProcessAudioSource {
    /// Where the HAL delivers its listener blocks. Its own queue, so a slow handler
    /// cannot hold up anything else, and utility priority because nothing here is
    /// real-time.
    private let listenerQueue = DispatchQueue(label: "de.21m.steno.detection", qos: .utility)

    private var onChange: (@MainActor () -> Void)?
    private var listListener: AudioObjectPropertyListenerBlock?
    /// One entry per process object being watched, so listeners can be removed again.
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private(set) var isEventDriven = false
    private var isRunning = false

    init() {}

    deinit {
        // Listeners hold a block that fires into this object; leaving one behind after
        // deallocation is a crash waiting for the next microphone change. `stop()` is
        // what the app calls, and this is the belt.
        MainActor.assumeIsolated { removeAllListeners() }
    }

    // MARK: - Reading

    func snapshot() -> [AudioProcessDescriptor] {
        RunningMeetingApps.current()
    }

    // MARK: - Listening

    func start(onChange: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.onChange = onChange

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleProcessListChanged()
            }
        }
        listListener = AudioObjectID.system.addListener(
            kAudioHardwarePropertyProcessObjectList,
            on: listenerQueue,
            block: block
        )
        isEventDriven = listListener != nil
        syncProcessListeners()

        if isEventDriven {
            Log.detection.notice(
                "detection is event-driven: \(self.processListeners.count, privacy: .public) process listeners installed"
            )
        } else {
            Log.detection.error("the HAL refused a process-list listener; detection falls back to polling")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeAllListeners()
        onChange = nil
        isEventDriven = false
    }

    private func handleProcessListChanged() {
        guard isRunning else { return }
        // A new process may already be reading input, so the listeners are re-synced
        // before anyone is told: otherwise the app that just appeared would only be
        // noticed at the next change of something else.
        syncProcessListeners()
        onChange?()
    }

    private func handleInputChanged() {
        guard isRunning else { return }
        onChange?()
    }

    /// Brings the per-process listeners in line with the current process list.
    private func syncProcessListeners() {
        guard isRunning else { return }
        let current: Set<AudioObjectID>
        do {
            current = Set(try AudioObjectID.processObjectList())
        } catch {
            Log.detection.error(
                "could not re-read the process list: \(String(describing: error), privacy: .public)"
            )
            return
        }

        for objectID in processListeners.keys where !current.contains(objectID) {
            removeListener(from: objectID)
        }

        for objectID in current where processListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleInputChanged()
                }
            }
            guard objectID.addListener(
                kAudioProcessPropertyIsRunningInput,
                on: listenerQueue,
                block: block
            ) != nil else {
                // A process that vanished between the list and this call. Not an error,
                // and not worth a fallback to polling on its own.
                continue
            }
            processListeners[objectID] = block
        }
    }

    private func removeListener(from objectID: AudioObjectID) {
        guard let block = processListeners.removeValue(forKey: objectID) else { return }
        objectID.removeListener(
            kAudioProcessPropertyIsRunningInput,
            on: listenerQueue,
            block: block
        )
    }

    private func removeAllListeners() {
        if let listListener {
            AudioObjectID.system.removeListener(
                kAudioHardwarePropertyProcessObjectList,
                on: listenerQueue,
                block: listListener
            )
            self.listListener = nil
        }
        for objectID in processListeners.keys {
            removeListener(from: objectID)
        }
    }
}

/// A process list a test writes by hand.
///
/// Used by the detector tests and by `--simulate-detection`, which is the only way to
/// exercise the popup, the rules, and auto-stop end to end without starting a real
/// meeting on this Mac.
@MainActor
final class FakeProcessAudioSource: ProcessAudioSource {
    private(set) var processes: [AudioProcessDescriptor]
    private var onChange: (@MainActor () -> Void)?
    let isEventDriven = true
    private(set) var isRunning = false

    init(processes: [AudioProcessDescriptor] = []) {
        self.processes = processes
    }

    func snapshot() -> [AudioProcessDescriptor] { processes }

    func start(onChange: @escaping @MainActor () -> Void) {
        isRunning = true
        self.onChange = onChange
    }

    func stop() {
        isRunning = false
        onChange = nil
    }

    /// Replaces the list and reports the change, as the HAL would.
    func set(_ processes: [AudioProcessDescriptor]) {
        self.processes = processes
        onChange?()
    }

    /// Pretends one app started or stopped reading the microphone.
    func setInput(_ isRunningInput: Bool, bundleId: String, pid: pid_t = 4242) {
        var updated = processes.filter { $0.bundleId != bundleId }
        updated.append(
            AudioProcessDescriptor(pid: pid, bundleId: bundleId, isRunningInput: isRunningInput)
        )
        set(updated)
    }
}
