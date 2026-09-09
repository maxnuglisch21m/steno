import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation

/// The four things Steno needs before it can record. Specification §8, plus the
/// models, which are not a permission but are the fourth thing that has to be in
/// place before a recording produces a transcript.
enum Permission: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// `NSMicrophoneUsageDescription`. Needed by both modes.
    case microphone
    /// `NSAudioCaptureUsageDescription`, i.e. Core Audio process taps. `online` only.
    case systemAudio
    /// ScreenCaptureKit and `CGWindowList`. Needed for screenshots in both modes.
    case screenRecording
    /// ASR and diarization models on disk. Not a TCC permission; a download.
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return String(localized: "Mikrofon")
        case .systemAudio: return String(localized: "Systemaudio")
        case .screenRecording: return String(localized: "Bildschirmaufnahme")
        case .models: return String(localized: "Modelle")
        }
    }

    /// One sentence, in terms of what Steno does with it.
    var explanation: String {
        switch self {
        case .microphone:
            return String(localized: "Nimmt deine Stimme auf. Beide Modi brauchen es.")
        case .systemAudio:
            return String(localized: "Nimmt den Ton der Meeting-App auf, damit die anderen Teilnehmer im Transkript stehen. Nur für Online-Meetings.")
        case .screenRecording:
            return String(localized: "Speichert Screenshots der Bildschirme und liest Fenstertitel für Regeln.")
        case .models:
            return String(localized: "Spracherkennung und Sprechertrennung laufen offline auf diesem Mac. Die Modelle werden einmal geladen.")
        }
    }

    /// Which modes are blocked while this one is missing.
    var blockedModes: Set<MeetingModeRequirement> {
        switch self {
        case .microphone: return [.online, .onsite]
        case .systemAudio: return [.online]
        case .screenRecording: return [.online, .onsite]
        case .models: return []
        }
    }

    /// The System Settings pane that grants it. `models` has none.
    var systemSettingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone: return URL(string: base + "Privacy_Microphone")
        case .systemAudio: return URL(string: base + "Privacy_AudioCapture")
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")
        case .models: return nil
        }
    }

    /// Opens the matching System Settings pane.
    @MainActor
    func openSystemSettings() {
        guard let url = systemSettingsURL else { return }
        Log.app.notice("opening System Settings for \(self.rawValue, privacy: .public)")
        NSWorkspace.shared.open(url)
    }
}

/// Which of the two modes a permission blocks. Mirrors `StenoCore.MeetingMode` without
/// dragging the recording model into the permission code.
enum MeetingModeRequirement: String, Sendable, Hashable, CaseIterable {
    case online
    case onsite
}

/// What is known about one permission.
enum PermissionState: String, Sendable, Hashable, CaseIterable {
    /// Granted. Recording can proceed.
    case granted
    /// The user said no. Only System Settings can change that.
    case denied
    /// Never asked. Steno may prompt.
    case undetermined
    /// Not established yet — the probe has not run, or it failed for a reason that is
    /// not a permission answer.
    case unknown

    var isGranted: Bool { self == .granted }

    /// Whether asking again could plausibly help.
    var isRequestable: Bool { self == .undetermined || self == .unknown }
}

/// All four states at once, so the menu and the onboarding window read one value.
struct PermissionSnapshot: Sendable, Hashable {
    var microphone: PermissionState
    var systemAudio: PermissionState
    var screenRecording: PermissionState
    var models: PermissionState

    init(
        microphone: PermissionState = .unknown,
        systemAudio: PermissionState = .unknown,
        screenRecording: PermissionState = .unknown,
        models: PermissionState = .unknown
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.screenRecording = screenRecording
        self.models = models
    }

    subscript(permission: Permission) -> PermissionState {
        get {
            switch permission {
            case .microphone: return microphone
            case .systemAudio: return systemAudio
            case .screenRecording: return screenRecording
            case .models: return models
            }
        }
        set {
            switch permission {
            case .microphone: microphone = newValue
            case .systemAudio: systemAudio = newValue
            case .screenRecording: screenRecording = newValue
            case .models: models = newValue
            }
        }
    }

    /// Nothing is known yet.
    static let unknown = PermissionSnapshot()

    /// Everything granted. Used by tests and by nothing else.
    static let allGranted = PermissionSnapshot(
        microphone: .granted,
        systemAudio: .granted,
        screenRecording: .granted,
        models: .granted
    )

    /// Whether all three TCC permissions are in place. The models are not part of it:
    /// a recording without them still captures everything and is transcribed later.
    var allRecordingPermissionsGranted: Bool {
        microphone.isGranted && systemAudio.isGranted && screenRecording.isGranted
    }

    /// The first permission that blocks a mode, in the order the onboarding lists them.
    func firstMissing(for requirement: MeetingModeRequirement) -> Permission? {
        Permission.allCases.first { permission in
            permission.blockedModes.contains(requirement) && !self[permission].isGranted
        }
    }
}

/// Reads and requests the permissions, and keeps the answer fresh.
///
/// Refreshing happens at launch, whenever the app becomes active — the user may have
/// just flipped a switch in System Settings — and every five seconds while the
/// onboarding window is open, which is the one place where a check mark is expected to
/// turn green without a click.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var snapshot: PermissionSnapshot = .unknown
    /// Set when the system-audio probe failed for a reason that is not an answer, so
    /// the onboarding row can say what happened instead of showing a bare circle.
    private(set) var systemAudioProbeDetail: String?

    /// Whether the models are on disk. Injected because `ModelManager` owns that
    /// question and this class owns none of it.
    private let modelsInstalled: @MainActor () -> Bool

    /// The probe creates and destroys a real global tap, which is what makes the TCC
    /// prompt appear; the answer is cached so that a five-second refresh loop does not
    /// do that over and over.
    private var cachedSystemAudio: PermissionState?
    private var isProbingSystemAudio = false

    private var refreshTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    init(modelsInstalled: @escaping @MainActor () -> Bool) {
        self.modelsInstalled = modelsInstalled
    }

    // MARK: - Reading

    /// Re-reads every permission. The system-audio probe only runs when it has to.
    func refresh(probeSystemAudio: Bool = true) async {
        var next = snapshot
        next.microphone = Self.microphoneState()
        next.screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .undetermined
        next.models = modelsInstalled() ? .granted : .undetermined

        if let cachedSystemAudio, cachedSystemAudio.isGranted {
            // Once granted, it stays granted for the life of the process: revoking it
            // in System Settings kills the app's audio access, and macOS asks the user
            // to quit it anyway.
            next.systemAudio = cachedSystemAudio
        } else if probeSystemAudio {
            next.systemAudio = await probeSystemAudioAccess()
        } else {
            next.systemAudio = cachedSystemAudio ?? .unknown
        }

        if next != snapshot {
            snapshot = next
            Log.app.info(
                """
                permissions: mic=\(next.microphone.rawValue, privacy: .public) \
                systemAudio=\(next.systemAudio.rawValue, privacy: .public) \
                screen=\(next.screenRecording.rawValue, privacy: .public) \
                models=\(next.models.rawValue, privacy: .public)
                """
            )
        }
    }

    /// Applies a snapshot directly. Tests only — nothing in the app calls this.
    func override(_ snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
        cachedSystemAudio = snapshot.systemAudio
    }

    private static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .unknown
        }
    }

    // MARK: - Requesting

    /// Asks for a permission, by whatever route macOS provides for it.
    func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.app.notice("microphone request answered: \(granted, privacy: .public)")
        case .systemAudio:
            // There is no request API. Creating the tap *is* the request: the first
            // attempt is what makes macOS show the prompt.
            cachedSystemAudio = nil
            _ = await probeSystemAudioAccess()
        case .screenRecording:
            // Returns immediately with the current answer and shows the prompt on the
            // first call. macOS only hands the app the new access after a relaunch,
            // which the onboarding window says.
            let granted = CGRequestScreenCaptureAccess()
            Log.app.notice("screen recording request answered: \(granted, privacy: .public)")
        case .models:
            // Owned by ModelManager; the onboarding button calls it directly.
            break
        }
        await refresh()
    }

    // MARK: - The system-audio probe

    /// Whether a Core Audio process tap can be created.
    ///
    /// There is no `authorizationStatus` for audio capture, so the only honest answer
    /// comes from trying: build a global tap that excludes nothing, and destroy it
    /// again immediately. Success means the permission is granted. A failure is either
    /// a refusal or an undetermined state that has just produced a prompt — either
    /// way, not granted, and the next refresh will see the new answer.
    func probeSystemAudioAccess() async -> PermissionState {
        guard !isProbingSystemAudio else { return cachedSystemAudio ?? .unknown }
        isProbingSystemAudio = true
        defer { isProbingSystemAudio = false }

        let result = await Task.detached(priority: .userInitiated) {
            SystemAudioProbe.run()
        }.value

        systemAudioProbeDetail = result.detail
        cachedSystemAudio = result.state
        return result.state
    }

    // MARK: - Staying fresh

    /// Starts refreshing every `interval` seconds. Used while the onboarding window is
    /// open, and stopped when it closes.
    func startPeriodicRefresh(every interval: Duration = .seconds(5)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                // Re-probing costs a tap create/destroy, but TCC only ever prompts
                // once, so a denied answer stays silent from here on.
                await self.refresh()
            }
        }
    }

    func stopPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Refreshes whenever the app is brought forward — the usual way back from
    /// System Settings.
    func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` means this runs on the main thread, where the main actor
            // is; the compiler cannot infer that through NotificationCenter.
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }
}

/// The throwaway global tap that answers "may we capture system audio?".
///
/// Kept separate from `PermissionMonitor` because it is the one piece of this file
/// that runs off the main actor: `AudioHardwareCreateProcessTap` blocks while the
/// audio daemon answers, and on an undetermined permission it blocks for as long as
/// the user takes to dismiss the prompt.
enum SystemAudioProbe {
    struct Result: Sendable {
        var state: PermissionState
        /// The raw `OSStatus`, for the report and the log. `noErr` on success.
        var status: OSStatus
        /// A human-readable note when the status was not an answer we understand.
        var detail: String?
    }

    static func run() -> Result {
        // An empty exclusion list means "everything the system is playing". Nothing is
        // read from the tap: it is created and destroyed in the same breath.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Steno permission probe"
        // Muting nothing and mixing down nothing keeps the probe inaudible to the user.
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        if status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) {
            let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
            if destroyStatus != noErr {
                Log.audio.error("probe tap could not be destroyed: \(destroyStatus, privacy: .public)")
            }
            Log.audio.info("system-audio probe succeeded")
            return Result(state: .granted, status: status, detail: nil)
        }

        Log.audio.notice("system-audio probe refused with status \(status, privacy: .public)")
        // `nope` (`kAudioHardwareIllegalOperationError`) is what the audio daemon
        // answers when the permission is not in place. It covers both "denied" and
        // "not decided yet", and the two are indistinguishable from here — the first
        // call is also what triggers the prompt.
        let refusals: Set<OSStatus> = [
            OSStatus(kAudioHardwareIllegalOperationError),
            OSStatus(kAudioHardwareUnknownPropertyError),
            OSStatus(kAudioHardwareBadObjectError),
            // TCC's own "not permitted" code, which some releases return instead.
            -10_851
        ]
        if refusals.contains(status) {
            return Result(state: .undetermined, status: status, detail: nil)
        }
        return Result(
            state: .unknown,
            status: status,
            detail: String(
                format: String(localized: "Systemaudio-Prüfung ergab Status %d."),
                Int(status)
            )
        )
    }
}
