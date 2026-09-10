import Foundation
import StenoCore
import Testing

@testable import Steno

/// `SettingsStore` against a `UserDefaults` suite of its own, never `.standard`: these
/// tests must not touch the settings of the app installed on the machine running them.
@Suite("SettingsStore", .serialized)
@MainActor
struct SettingsStoreTests {
    /// A fresh suite per test, removed again afterwards.
    private static func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "de.21m.steno.tests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh store starts on the documented defaults")
    func defaults() {
        let store = SettingsStore(defaults: Self.makeDefaults())
        let settings = store.settings

        #expect(settings.rootFolderPath.hasSuffix("/Meetings"))
        #expect(settings.watchlist == WatchedApp.defaults)
        #expect(settings.onsiteInputDeviceUID == nil)
        #expect(settings.screenshotNormalMinInterval == 5)
        #expect(settings.screenshotActiveMinInterval == 2)
        #expect(settings.screenshotNormalMinChange == 0.02)
        #expect(settings.screenshotActiveMinChange == 0.005)
        #expect(settings.screenshotMaxEdge == 1920)
        #expect(settings.jpegQuality == 0.8)
        #expect(settings.asrVersion == .v3)
        #expect(settings.autoStopDelay == 30)
        #expect(settings.showSpeakerCountPicker == false)
        #expect(settings.audioArchiveFormat == .aac)
        #expect(settings.rules.isEmpty)
        #expect(settings.useCalendarTitles == false)
        #expect(settings.includeTitleInFolderName == true)
        #expect(settings.notificationsEnabled == true)
        #expect(settings.anchorInterval == 120)
        #expect(settings.checkForUpdatesAutomatically == true)
    }

    @Test("every setting survives a round trip through UserDefaults")
    func roundTrip() {
        let defaults = Self.makeDefaults()
        let rule = RecordingRule(
            appBundleId: "com.microsoft.teams2",
            pattern: "Daily",
            isRegex: true,
            action: .never,
            enabled: false
        )

        do {
            let store = SettingsStore(defaults: defaults)
            store.settings.rootFolderPath = "/tmp/steno-test-root"
            store.settings.watchlist = [WatchedApp(bundleId: "com.brave.Browser", name: "Brave")]
            store.settings.onsiteInputDeviceUID = "AppleUSBAudioEngine:Boundary"
            store.settings.screenshotNormalMinInterval = 9
            store.settings.screenshotActiveMinInterval = 3
            store.settings.screenshotNormalMinChange = 0.04
            store.settings.screenshotActiveMinChange = 0.01
            store.settings.screenshotMaxEdge = 2560
            store.settings.jpegQuality = 0.65
            store.settings.asrVersion = .v2
            store.settings.autoStopDelay = 45
            store.settings.showSpeakerCountPicker = true
            store.settings.audioArchiveFormat = .flac
            store.settings.rules = [rule]
            store.settings.useCalendarTitles = true
            store.settings.includeTitleInFolderName = false
            store.settings.notificationsEnabled = false
            store.settings.anchorInterval = 240
            store.settings.checkForUpdatesAutomatically = false
        }

        // A second store reads what the first one wrote, which is the whole point of
        // the blob: one key, one decode, nothing left in memory.
        let reloaded = SettingsStore(defaults: defaults)
        let settings = reloaded.settings
        #expect(settings.rootFolderPath == "/tmp/steno-test-root")
        #expect(settings.watchlist.map(\.bundleId) == ["com.brave.Browser"])
        #expect(settings.onsiteInputDeviceUID == "AppleUSBAudioEngine:Boundary")
        #expect(settings.screenshotNormalMinInterval == 9)
        #expect(settings.screenshotActiveMinInterval == 3)
        #expect(settings.screenshotNormalMinChange == 0.04)
        #expect(settings.screenshotActiveMinChange == 0.01)
        #expect(settings.screenshotMaxEdge == 2560)
        #expect(settings.jpegQuality == 0.65)
        #expect(settings.asrVersion == .v2)
        #expect(settings.autoStopDelay == 45)
        #expect(settings.showSpeakerCountPicker == true)
        #expect(settings.audioArchiveFormat == .flac)
        #expect(settings.rules == [rule])
        #expect(settings.useCalendarTitles == true)
        #expect(settings.includeTitleInFolderName == false)
        #expect(settings.notificationsEnabled == false)
        #expect(settings.anchorInterval == 240)
        #expect(settings.checkForUpdatesAutomatically == false)
    }

    @Test("a blob missing keys keeps them at their defaults instead of failing")
    func toleratesAnOlderBlob() throws {
        let defaults = Self.makeDefaults()
        // What a build that only knew about the specification's settings would write.
        let older = """
        {"rootFolderPath":"/tmp/older","jpegQuality":0.5,"asrVersion":"v2"}
        """
        defaults.set(Data(older.utf8), forKey: SettingsStore.defaultsKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.rootFolderPath == "/tmp/older")
        #expect(store.settings.jpegQuality == 0.5)
        #expect(store.settings.asrVersion == .v2)
        // Everything the older build never heard of falls back.
        #expect(store.settings.audioArchiveFormat == .aac)
        #expect(store.settings.anchorInterval == 120)
        #expect(store.settings.watchlist == WatchedApp.defaults)
    }

    @Test("an unreadable blob falls back to the defaults rather than throwing")
    func toleratesGarbage() {
        let defaults = Self.makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.defaultsKey)
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings == .default)
    }

    @Test("the screenshot gate config is derived from the five screenshot settings")
    func derivesGateConfig() {
        let store = SettingsStore(defaults: Self.makeDefaults())
        store.settings.screenshotNormalMinInterval = 7
        store.settings.screenshotActiveMinInterval = 4
        store.settings.screenshotNormalMinChange = 0.03
        store.settings.screenshotActiveMinChange = 0.002
        store.settings.anchorInterval = 90

        let config = store.screenshotGateConfig
        #expect(config.normalMinInterval == 7)
        #expect(config.activeMinInterval == 4)
        #expect(config.normalMinChange == 0.03)
        #expect(config.activeMinChange == 0.002)
        #expect(config.anchorInterval == 90)
        // And it is the type StenoCore's gate takes, unchanged.
        #expect(config.thresholds(isActive: true).minInterval == 4)
    }

    @Test("the root folder can be pointed somewhere else")
    func setsRootFolder() {
        let store = SettingsStore(defaults: Self.makeDefaults())
        store.setRootFolder(URL(fileURLWithPath: "/Volumes/Extern/Meetings", isDirectory: true))
        #expect(store.rootFolderURL.stenoPath == "/Volumes/Extern/Meetings")
    }

    @Test("the onboarding flag is remembered")
    func onboardingFlag() {
        let defaults = Self.makeDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.hasShownOnboarding == false)
        store.hasShownOnboarding = true
        #expect(SettingsStore(defaults: defaults).hasShownOnboarding == true)
    }

    @Test("the archive formats name the files meta.json will point at")
    func archiveFileNames() {
        #expect(AudioArchiveFormat.aac.audioFileName == "audio.m4a")
        #expect(AudioArchiveFormat.flac.audioFileName == "audio.flac")
        #expect(AudioArchiveFormat.wav.audioFileName == "audio.wav")
    }

    // MARK: - Language (M6)

    @Test("the language setting maps onto the tag the recognizer takes")
    func languageCodes() {
        #expect(TranscriptionLanguage.german.languageCode == "de")
        #expect(TranscriptionLanguage.english.languageCode == "en")
        // "Automatisch" is the absence of a hint, not a hint that says "automatic".
        #expect(TranscriptionLanguage.automatic.languageCode == nil)
    }

    @Test("German is the default, because the app is")
    func languageDefault() {
        #expect(StenoSettings.default.transcriptionLanguage == .german)
    }

    @Test("the language survives a round trip through UserDefaults")
    func languagePersists() {
        let defaults = Self.makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.settings.transcriptionLanguage = .english
        #expect(SettingsStore(defaults: defaults).settings.transcriptionLanguage == .english)
    }

    @Test("a blob written before the setting existed decodes to the default")
    func languageFallsBackWhenAbsent() throws {
        // Every key falls back on its own, so an older build's settings are not lost
        // for want of one it never knew about.
        let json = Data("{\"rootFolderPath\":\"/tmp/Meetings\"}".utf8)
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: json)
        #expect(decoded.transcriptionLanguage == .german)
        #expect(decoded.rootFolderPath == "/tmp/Meetings")
    }

    @Test("every language the setting offers is one FluidAudio knows")
    func languagesReachTheRecognizer() {
        for language in TranscriptionLanguage.allCases {
            let mapped = FluidASR.fluidLanguage(language.languageCode)
            #expect((mapped != nil) == (language.languageCode != nil), "\(language)")
        }
        #expect(FluidASR.fluidLanguage("de")?.rawValue == "de")
        // A region subtag means the same thing to a script filter as the language does.
        #expect(FluidASR.fluidLanguage("de-DE")?.rawValue == "de")
        #expect(FluidASR.fluidLanguage("EN")?.rawValue == "en")
        // A tag with no filter behind it is dropped rather than guessed at: filtering
        // for the wrong script would throw away the right words.
        #expect(FluidASR.fluidLanguage("xx") == nil)
        #expect(FluidASR.fluidLanguage("") == nil)
    }

}
