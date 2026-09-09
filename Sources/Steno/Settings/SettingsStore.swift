import Foundation
import Observation
import StenoCore

/// Which Parakeet checkpoint transcription uses. Specification §7.
enum ASRVersion: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Multilingual, German included. The default.
    case v3
    /// The older English-first checkpoint, kept because it is faster.
    case v2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v3: return "Parakeet v3 (multilingual)"
        case .v2: return "Parakeet v2"
        }
    }
}

/// What `audio.wav` is turned into once the transcript is written.
///
/// Recording is always lossless WAV — it streams, it survives a crash, and the two
/// channels stay sample-exact. The archive format only decides what is kept
/// afterwards, and it never touches transcript quality because transcription has
/// already run on the WAV by then.
enum AudioArchiveFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// AAC-LC in an `.m4a` container. Roughly a twelfth of the WAV.
    case aac
    /// FLAC: lossless, roughly half the WAV.
    case flac
    /// Keep the original WAV.
    case wav

    var id: String { rawValue }

    /// The file `meta.json` will point at.
    var audioFileName: String {
        switch self {
        case .aac: return "audio.m4a"
        case .flac: return "audio.flac"
        case .wav: return "audio.wav"
        }
    }
}

/// Everything the user can configure, as one Codable value.
///
/// It is stored as a single JSON blob under one `UserDefaults` key rather than as
/// twenty separate keys, so that reading it is one decode and adding a setting is one
/// property. Decoding is per-key tolerant: a blob written by an older build is missing
/// the keys added since, and each of those falls back to its default instead of
/// throwing the whole thing away.
struct StenoSettings: Codable, Sendable, Equatable {
    // MARK: Specification §7, in that order

    /// Recording root. Every meeting folder is created inside it, and Steno writes
    /// nothing outside it except the model cache.
    var rootFolderPath: String
    /// Apps whose microphone use triggers a suggestion.
    var watchlist: [WatchedApp]
    /// `AVCaptureDevice.uniqueID` of the input used for `onsite`. `nil` = system default.
    var onsiteInputDeviceUID: String?
    /// Minimum seconds between two screenshots of a display without the mouse.
    var screenshotNormalMinInterval: TimeInterval
    /// Minimum seconds between two screenshots of the display holding the mouse.
    var screenshotActiveMinInterval: TimeInterval
    /// Minimum changed share of the display area, without the mouse. 0…1.
    var screenshotNormalMinChange: Double
    /// Minimum changed share of the display area, with the mouse. 0…1.
    var screenshotActiveMinChange: Double
    /// Longer edge of a saved screenshot, in pixels.
    var screenshotMaxEdge: Int
    /// JPEG quality of a saved screenshot. 0…1.
    var jpegQuality: Double
    var asrVersion: ASRVersion
    /// Mirrors `SMAppService.mainApp.status`; the service is the authority.
    var launchAtLogin: Bool
    /// Seconds without a watched process reading the microphone before an `online`
    /// recording stops itself.
    var autoStopDelay: TimeInterval
    /// Whether starting an `onsite` recording asks how many people are in the room.
    var showSpeakerCountPicker: Bool

    // MARK: Additions from the plan

    var audioArchiveFormat: AudioArchiveFormat
    /// Never / ask / always, matched against the app and the meeting title.
    var rules: [RecordingRule]
    /// Whether the title of the currently running calendar event may be read. Off by
    /// default, and its own permission prompt: it is the only way to get a title out of
    /// Zoom or Google Meet, and it is nobody's business otherwise.
    var useCalendarTitles: Bool
    /// Whether a known meeting title is appended to the folder name as a slug.
    var includeTitleInFolderName: Bool
    /// Whether a notification is posted when a transcript is finished or fails.
    var notificationsEnabled: Bool
    /// Save one screenshot per display at least this often, whatever changed.
    var anchorInterval: TimeInterval
    /// Stored in M0, wired to Sparkle in M7.
    var checkForUpdatesAutomatically: Bool

    // MARK: - Defaults

    static let `default` = StenoSettings(
        rootFolderPath: Self.defaultRootFolderPath,
        watchlist: WatchedApp.defaults,
        onsiteInputDeviceUID: nil,
        screenshotNormalMinInterval: ScreenshotGateConfig.default.normalMinInterval,
        screenshotActiveMinInterval: ScreenshotGateConfig.default.activeMinInterval,
        screenshotNormalMinChange: ScreenshotGateConfig.default.normalMinChange,
        screenshotActiveMinChange: ScreenshotGateConfig.default.activeMinChange,
        screenshotMaxEdge: 1920,
        jpegQuality: 0.8,
        asrVersion: .v3,
        launchAtLogin: false,
        autoStopDelay: 30,
        showSpeakerCountPicker: false,
        audioArchiveFormat: .aac,
        rules: [],
        useCalendarTitles: false,
        includeTitleInFolderName: true,
        notificationsEnabled: true,
        anchorInterval: ScreenshotGateConfig.default.anchorInterval,
        checkForUpdatesAutomatically: true
    )

    /// `~/Meetings`, expanded. Stored as a path rather than a URL so the blob stays
    /// readable in `defaults read de.21m.steno`.
    static var defaultRootFolderPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings", isDirectory: true)
            .stenoPath
    }

    // MARK: - Derived

    var rootFolderURL: URL {
        URL(fileURLWithPath: (rootFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The thresholds the screenshot gate in `StenoCore` runs on, so that the gate has
    /// one source of truth and the settings window is not it.
    var screenshotGateConfig: ScreenshotGateConfig {
        ScreenshotGateConfig(
            normalMinInterval: screenshotNormalMinInterval,
            activeMinInterval: screenshotActiveMinInterval,
            normalMinChange: screenshotNormalMinChange,
            activeMinChange: screenshotActiveMinChange,
            anchorInterval: anchorInterval
        )
    }

    // MARK: - Coding

    /// Every key falls back to its default, so a blob from an older build still
    /// decodes and only the settings it never knew about are reset.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StenoSettings.default
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens the optional `decodeIfPresent` returns, so a missing
            // key and a failed decode both land in the `else` branch.
            guard let decoded = try? c.decodeIfPresent(T.self, forKey: key) else { return fallback }
            return decoded
        }
        rootFolderPath = value(.rootFolderPath, d.rootFolderPath)
        watchlist = value(.watchlist, d.watchlist)
        // A present-but-null UID means "system default" just as an absent key does.
        onsiteInputDeviceUID = try? c.decodeIfPresent(String.self, forKey: .onsiteInputDeviceUID)
        screenshotNormalMinInterval = value(.screenshotNormalMinInterval, d.screenshotNormalMinInterval)
        screenshotActiveMinInterval = value(.screenshotActiveMinInterval, d.screenshotActiveMinInterval)
        screenshotNormalMinChange = value(.screenshotNormalMinChange, d.screenshotNormalMinChange)
        screenshotActiveMinChange = value(.screenshotActiveMinChange, d.screenshotActiveMinChange)
        screenshotMaxEdge = value(.screenshotMaxEdge, d.screenshotMaxEdge)
        jpegQuality = value(.jpegQuality, d.jpegQuality)
        asrVersion = value(.asrVersion, d.asrVersion)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        autoStopDelay = value(.autoStopDelay, d.autoStopDelay)
        showSpeakerCountPicker = value(.showSpeakerCountPicker, d.showSpeakerCountPicker)
        audioArchiveFormat = value(.audioArchiveFormat, d.audioArchiveFormat)
        rules = value(.rules, d.rules)
        useCalendarTitles = value(.useCalendarTitles, d.useCalendarTitles)
        includeTitleInFolderName = value(.includeTitleInFolderName, d.includeTitleInFolderName)
        notificationsEnabled = value(.notificationsEnabled, d.notificationsEnabled)
        anchorInterval = value(.anchorInterval, d.anchorInterval)
        checkForUpdatesAutomatically = value(.checkForUpdatesAutomatically, d.checkForUpdatesAutomatically)
    }

    init(
        rootFolderPath: String,
        watchlist: [WatchedApp],
        onsiteInputDeviceUID: String?,
        screenshotNormalMinInterval: TimeInterval,
        screenshotActiveMinInterval: TimeInterval,
        screenshotNormalMinChange: Double,
        screenshotActiveMinChange: Double,
        screenshotMaxEdge: Int,
        jpegQuality: Double,
        asrVersion: ASRVersion,
        launchAtLogin: Bool,
        autoStopDelay: TimeInterval,
        showSpeakerCountPicker: Bool,
        audioArchiveFormat: AudioArchiveFormat,
        rules: [RecordingRule],
        useCalendarTitles: Bool,
        includeTitleInFolderName: Bool,
        notificationsEnabled: Bool,
        anchorInterval: TimeInterval,
        checkForUpdatesAutomatically: Bool
    ) {
        self.rootFolderPath = rootFolderPath
        self.watchlist = watchlist
        self.onsiteInputDeviceUID = onsiteInputDeviceUID
        self.screenshotNormalMinInterval = screenshotNormalMinInterval
        self.screenshotActiveMinInterval = screenshotActiveMinInterval
        self.screenshotNormalMinChange = screenshotNormalMinChange
        self.screenshotActiveMinChange = screenshotActiveMinChange
        self.screenshotMaxEdge = screenshotMaxEdge
        self.jpegQuality = jpegQuality
        self.asrVersion = asrVersion
        self.launchAtLogin = launchAtLogin
        self.autoStopDelay = autoStopDelay
        self.showSpeakerCountPicker = showSpeakerCountPicker
        self.audioArchiveFormat = audioArchiveFormat
        self.rules = rules
        self.useCalendarTitles = useCalendarTitles
        self.includeTitleInFolderName = includeTitleInFolderName
        self.notificationsEnabled = notificationsEnabled
        self.anchorInterval = anchorInterval
        self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
    }
}

/// The settings, observable, persisted on every change.
///
/// Reads come from memory; every write re-encodes the blob and hands it to
/// `UserDefaults`. That is cheap enough for a settings window and means a crash never
/// loses a setting the user just changed.
@MainActor
@Observable
final class SettingsStore {
    /// The `UserDefaults` key the blob lives under.
    static let defaultsKey = "settings"
    /// Whether the onboarding window has already been shown once.
    static let onboardingShownKey = "onboardingShown"

    private let defaults: UserDefaults
    private var isLoading = false

    /// The settings. Assigning to any property persists the whole blob.
    var settings: StenoSettings {
        didSet {
            guard !isLoading, settings != oldValue else { return }
            persist()
        }
    }

    /// Set when writing to `UserDefaults` or to the login-item service failed, so the
    /// settings window can say so instead of silently pretending it worked.
    var lastError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults) -> StenoSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return .default }
        do {
            return try JSONDecoder().decode(StenoSettings.self, from: data)
        } catch {
            // A blob that cannot be decoded at all is worth reporting and replacing;
            // a blob that is merely out of date decodes fine, because every key in
            // `StenoSettings.init(from:)` falls back to its default.
            Log.app.error("settings blob unreadable, falling back to defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(settings), forKey: Self.defaultsKey)
        } catch {
            lastError = error.localizedDescription
            Log.app.error("could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-reads the blob, for a test or after an external `defaults write`.
    func reload() {
        isLoading = true
        settings = Self.load(from: defaults)
        isLoading = false
    }

    func resetToDefaults() {
        settings = .default
    }

    // MARK: - Onboarding

    var hasShownOnboarding: Bool {
        get { defaults.bool(forKey: Self.onboardingShownKey) }
        set { defaults.set(newValue, forKey: Self.onboardingShownKey) }
    }

    // MARK: - Convenience

    var rootFolderURL: URL { settings.rootFolderURL }

    var screenshotGateConfig: ScreenshotGateConfig { settings.screenshotGateConfig }

    /// Points the recording root at a folder the user picked.
    func setRootFolder(_ url: URL) {
        settings.rootFolderPath = url.stenoPath
    }

    // MARK: - Launch at login

    /// The authority is `SMAppService`, not the stored blob: the user can remove the
    /// login item in System Settings without Steno ever hearing about it.
    var launchAtLoginEnabled: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            do {
                try LaunchAtLogin.set(newValue)
                settings.launchAtLogin = LaunchAtLogin.isEnabled
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
                // Keep the blob honest about what the service actually reports.
                settings.launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    /// Brings the stored value in line with the service, once, at launch.
    func syncLaunchAtLogin() {
        let actual = LaunchAtLogin.isEnabled
        if settings.launchAtLogin != actual { settings.launchAtLogin = actual }
    }
}
