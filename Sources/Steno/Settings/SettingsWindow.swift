import AppKit
import StenoCore
import SwiftUI

/// The settings window, owned by an `NSWindowController`.
///
/// Not a SwiftUI `Settings` scene, and not for want of trying: in an `LSUIElement`
/// app whose only other scene is a `MenuBarExtra`, the `Settings` scene never
/// materializes a window. `showSettingsWindow:` finds a responder and returns `true`,
/// and no window is created — verified on macOS 26.6, where `NSApp.windows` holds
/// nothing but the status item's own windows afterwards. An app with no Dock icon and
/// no application menu gains nothing from the scene anyway: `⌘,` comes from the menu
/// item's own keyboard shortcut either way, and owning the window means the debug
/// launch argument can open it and the tests can be sure it exists.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    @discardableResult
    func show(environment: AppEnvironment) -> Bool {
        // The device list is only worth watching while the window that shows it is up.
        environment.inputDevices.refresh()

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return true
        }

        let hosting = NSHostingController(rootView: SettingsView(environment: environment))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Steno-Einstellungen")
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Closing the window keeps it alive, so reopening it is instant and the tab
        // the user was last on is still selected.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.app.debug("settings window opened")
        return true
    }
}

/// The settings window: six tabs.
///
/// Specification §7 asks for "one window, eleven sliders, nothing more". The eleven
/// are all here and come first within their tab; the additions the plan accepted —
/// archive format, title in folder name, notifications, anchor interval, update
/// checks — follow them.
struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Allgemein"), systemImage: "gearshape") }

            RecordingSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Aufnahme"), systemImage: "mic") }

            ScreenshotSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Screenshots"), systemImage: "camera.viewfinder") }

            TranscriptionSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Transkription"), systemImage: "text.bubble") }

            DetectionSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Erkennung"), systemImage: "sensor") }

            UpdateSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Updates"), systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Allgemein

private struct GeneralSettingsTab: View {
    /// Set when the notification prompt came back with a no, so the tab can say so
    /// instead of leaving a toggle that is on and does nothing.
    @State private var notificationsRefused = false
    let environment: AppEnvironment

    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Ablageordner")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(environment.settings.settings.rootFolderPath)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button(String(localized: "Auswählen …"), action: chooseRootFolder)
                            Button(String(localized: "Im Finder zeigen")) {
                                environment.store.openRootFolder(environment.settings.rootFolderURL)
                            }
                        }
                    }
                }
                Text(String(localized: "Jedes Meeting wird als eigener Ordner hier abgelegt. Steno schreibt nirgendwo sonst hin."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Bei der Anmeldung starten"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        environment.settings.launchAtLoginEnabled = newValue
                        launchAtLogin = environment.settings.launchAtLoginEnabled
                    }
                if LaunchAtLogin.requiresApproval {
                    HStack {
                        Text(String(localized: "Warte auf Bestätigung in den Systemeinstellungen."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Öffnen")) {
                            LaunchAtLogin.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }

                Toggle(
                    String(localized: "Mitteilung, wenn ein Transkript fertig ist"),
                    isOn: Binding(
                        get: { environment.settings.settings.notificationsEnabled },
                        set: { isOn in
                            environment.settings.settings.notificationsEnabled = isOn
                            // The one place, together with the onboarding window's
                            // finish button, that asks macOS for permission to post
                            // notifications — and only when the user has just switched
                            // them on. Never at launch, never on its own.
                            guard isOn else { return }
                            Task {
                                let granted = await Notifications.shared.requestAuthorization()
                                if !granted {
                                    notificationsRefused = true
                                }
                            }
                        }
                    )
                )
                if notificationsRefused {
                    HStack {
                        Text(String(localized: "Mitteilungen sind in den Systemeinstellungen abgelehnt."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Öffnen")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                Button(String(localized: "Onboarding erneut anzeigen")) {
                    OnboardingWindowController.shared.show(environment: environment)
                }
                LabeledContent(String(localized: "Version")) {
                    Text(Dependencies.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = environment.settings.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = environment.settings.launchAtLoginEnabled }
    }

    private func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = environment.settings.rootFolderURL
        panel.prompt = String(localized: "Auswählen")
        panel.message = String(localized: "Ordner, in dem Steno die Meetings ablegt.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        environment.changeRootFolder(to: url)
    }
}

// MARK: - Aufnahme

private struct RecordingSettingsTab: View {
    let environment: AppEnvironment

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "Eingabegerät (Vor Ort)"),
                    selection: Binding(
                        get: { settings.settings.onsiteInputDeviceUID ?? "" },
                        set: { settings.settings.onsiteInputDeviceUID = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text(AudioInputDevices.systemDefaultName).tag("")
                    ForEach(environment.inputDevices.devices) { device in
                        Text(verbatim: "\(device.name)").tag(device.uid)
                    }
                }
                Text(String(localized: "Ein Grenzflächenmikrofon auf dem Tisch ist der wirksamste Hebel für die Qualität einer Raumaufnahme."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let uid = settings.settings.onsiteInputDeviceUID {
                    LabeledContent(String(localized: "Gerätekennung")) {
                        Text(uid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Button(String(localized: "Geräte neu einlesen")) {
                    AudioInputDevices.invalidateCache()
                    environment.inputDevices.refresh()
                }
                .controlSize(.small)
            }

            Section {
                LabeledContent(String(localized: "Auto-Stop-Verzögerung")) {
                    HStack {
                        Stepper(
                            value: Binding(
                                get: { settings.settings.autoStopDelay },
                                set: { settings.settings.autoStopDelay = $0 }
                            ),
                            in: 5...300,
                            step: 5
                        ) {
                            Text(
                                String(
                                    format: String(localized: "%d s"),
                                    Int(settings.settings.autoStopDelay)
                                )
                            )
                        }
                    }
                }
                Text(String(localized: "So lange darf keine beobachtete App mehr das Mikrofon lesen, bevor eine Online-Aufnahme sich selbst beendet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(
                    String(localized: "Sprecherzahl vor einer Vor-Ort-Aufnahme abfragen"),
                    isOn: Binding(
                        get: { settings.settings.showSpeakerCountPicker },
                        set: { settings.settings.showSpeakerCountPicker = $0 }
                    )
                )
            }

            Section {
                Picker(
                    String(localized: "Audio-Archivformat"),
                    selection: Binding(
                        get: { settings.settings.audioArchiveFormat },
                        set: { settings.settings.audioArchiveFormat = $0 }
                    )
                ) {
                    Text(String(localized: "AAC (m4a) — klein")).tag(AudioArchiveFormat.aac)
                    Text(String(localized: "FLAC — verlustfrei")).tag(AudioArchiveFormat.flac)
                    Text(String(localized: "WAV — Original behalten")).tag(AudioArchiveFormat.wav)
                }
                Text(String(localized: "Aufgenommen wird immer verlustfreies WAV. Umgewandelt wird erst, wenn das Transkript steht — die Qualität der Erkennung hängt also nicht daran."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(
                    String(localized: "Meeting-Titel in den Ordnernamen aufnehmen"),
                    isOn: Binding(
                        get: { settings.settings.includeTitleInFolderName },
                        set: { settings.settings.includeTitleInFolderName = $0 }
                    )
                )
                Text(String(localized: "Aus „Weekly Sync“ wird 2026-09-09_1430_Teams_Weekly-Sync."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { environment.inputDevices.refresh() }
    }
}

// MARK: - Screenshots

private struct ScreenshotSettingsTab: View {
    let environment: AppEnvironment

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        Form {
            Section {
                secondsStepper(
                    String(localized: "Mindestabstand, normales Display"),
                    value: Binding(
                        get: { settings.settings.screenshotNormalMinInterval },
                        set: { settings.settings.screenshotNormalMinInterval = $0 }
                    ),
                    range: 1...60
                )
                secondsStepper(
                    String(localized: "Mindestabstand, Display mit der Maus"),
                    value: Binding(
                        get: { settings.settings.screenshotActiveMinInterval },
                        set: { settings.settings.screenshotActiveMinInterval = $0 }
                    ),
                    range: 1...60
                )
                Text(String(localized: "Das Display mit dem Mauszeiger wird häufiger gesichert — dort passiert das Meeting."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                percentSlider(
                    String(localized: "Änderungsschwelle, normales Display"),
                    value: Binding(
                        get: { settings.settings.screenshotNormalMinChange },
                        set: { settings.settings.screenshotNormalMinChange = $0 }
                    )
                )
                percentSlider(
                    String(localized: "Änderungsschwelle, Display mit der Maus"),
                    value: Binding(
                        get: { settings.settings.screenshotActiveMinChange },
                        set: { settings.settings.screenshotActiveMinChange = $0 }
                    )
                )
            }

            Section {
                LabeledContent(String(localized: "Maximale Bildkante")) {
                    Stepper(
                        value: Binding(
                            get: { settings.settings.screenshotMaxEdge },
                            set: { settings.settings.screenshotMaxEdge = $0 }
                        ),
                        in: 640...5120,
                        step: 160
                    ) {
                        Text(
                            String(
                                format: String(localized: "%d px"),
                                settings.settings.screenshotMaxEdge
                            )
                        )
                    }
                }

                LabeledContent(String(localized: "JPEG-Qualität")) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { settings.settings.jpegQuality },
                                set: { settings.settings.jpegQuality = $0 }
                            ),
                            in: 0.3...1.0,
                            step: 0.05
                        )
                        Text(String(format: "%.2f", settings.settings.jpegQuality))
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                secondsStepper(
                    String(localized: "Anker-Frame-Intervall"),
                    value: Binding(
                        get: { settings.settings.anchorInterval },
                        set: { settings.settings.anchorInterval = $0 }
                    ),
                    range: 30...600,
                    step: 30
                )
                Text(String(localized: "So oft wird jedes Display gesichert, egal ob sich etwas geändert hat. Ohne das hätte ein statischer Monitor über eine Stunde kein einziges Bild."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func secondsStepper(
        _ title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<Double>,
        step: Double = 1
    ) -> some View {
        LabeledContent(title) {
            Stepper(value: value, in: range, step: step) {
                Text(String(format: String(localized: "%d s"), Int(value.wrappedValue)))
            }
        }
    }

    private func percentSlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0.001...0.2)
                Text(String(format: String(localized: "%.1f %%"), value.wrappedValue * 100))
                    .font(.callout.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

// MARK: - Transkription

private struct TranscriptionSettingsTab: View {
    let environment: AppEnvironment

    var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "ASR-Version"),
                    selection: Binding(
                        get: { environment.settings.settings.asrVersion },
                        set: {
                            environment.settings.settings.asrVersion = $0
                            environment.models.asrVersion = $0
                        }
                    )
                ) {
                    ForEach(ASRVersion.allCases) { version in
                        Text(verbatim: version.displayName).tag(version)
                    }
                }
                Text(String(localized: "v3 ist mehrsprachig, Deutsch inbegriffen. v2 ist älter und schneller."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker(
                    String(localized: "Sprache"),
                    selection: Binding(
                        get: { environment.settings.settings.transcriptionLanguage },
                        set: { environment.settings.settings.transcriptionLanguage = $0 }
                    )
                ) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text(String(localized: "Die erwartete Sprache des Meetings. Sie hilft der Erkennung, Wörter im richtigen Schriftsystem zu wählen. „Automatisch“ überlässt die Entscheidung dem Modell."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(String(localized: "Modelle")) {
                    HStack(spacing: 8) {
                        Image(
                            systemName: environment.models.isInstalled
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(environment.models.isInstalled ? Color.green : Color.secondary)
                        Text(environment.models.statusDescription)
                    }
                }

                if case .preparing(_, let fraction) = environment.models.state {
                    ProgressView(value: fraction ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        // Indeterminate until the download knows its total size, which
                        // is after the file listing comes back.
                        .opacity(fraction == nil ? 0.4 : 1)
                }

                HStack {
                    Button(String(localized: "Modelle laden")) {
                        Task { try? await environment.models.download() }
                    }
                    .disabled(!environment.models.canDownload)
                    .help(environment.models.downloadUnavailableReason)

                    Button(String(localized: "Modellordner zeigen")) {
                        environment.models.revealModelsDirectory()
                    }
                }

                LabeledContent(String(localized: "Ordner")) {
                    Text(environment.models.modelsDirectory.stenoPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text(String(localized: "Spracherkennung und Sprechertrennung laufen offline auf diesem Mac. Der einmalige Download ist die einzige Netzverbindung, die Steno je aufbaut. Beim ersten Mal kompiliert macOS die Modelle für die Neural Engine — das kann einige Minuten dauern."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Erkennung

/// The watchlist, and nothing else.
///
/// It used to be two panes: this one and a table of never/ask/always rules matched
/// against the meeting's title. The rules are gone — every detected meeting now asks,
/// once, and the answer is a click. A rule table that can only say what a single click
/// says is a settings screen to maintain and a behaviour to explain, in exchange for
/// nothing.
private struct DetectionSettingsTab: View {
    let environment: AppEnvironment

    @State private var newBundleId = ""
    @State private var newName = ""
    @State private var bundleIdError: String?
    @State private var watchlistSelection: Set<String> = []

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Nutzt eine dieser Apps das Mikrofon, schlägt Steno eine Aufnahme vor. Erkannt wird ausschließlich über Core Audio — kein Kalender, keine Fensterinspektion."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(settings.settings.watchlist, selection: $watchlistSelection) {
                TableColumn(String(localized: "Name")) { app in
                    Text(app.name)
                }
                TableColumn(String(localized: "Bundle-ID")) { app in
                    Text(app.bundleId).font(.caption.monospaced())
                }
            }
            .frame(minHeight: 220)

            HStack(spacing: 6) {
                TextField(String(localized: "Bundle-ID"), text: $newBundleId)
                    .frame(minWidth: 180)
                TextField(String(localized: "Name"), text: $newName)
                    .frame(minWidth: 100)
                Button(String(localized: "Hinzufügen"), action: addWatchedApp)
                    .disabled(newBundleId.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(String(localized: "Entfernen"), action: removeWatchedApps)
                    .disabled(watchlistSelection.isEmpty)
            }

            if let bundleIdError {
                Text(bundleIdError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(String(localized: "Auf Vorgaben zurücksetzen")) {
                settings.settings.watchlist = WatchedApp.defaults
            }
            .controlSize(.small)

            Text(String(localized: "Jedes erkannte Meeting wird einmal vorgeschlagen. Ohne Antwort verschwindet der Vorschlag nach 20 Sekunden und gilt als abgelehnt."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func addWatchedApp() {
        guard let updated = WatchedApp.inserting(
            bundleId: newBundleId,
            name: newName,
            into: settings.settings.watchlist
        ) else {
            bundleIdError = String(localized: "Das ist keine Bundle-ID. Erwartet wird etwas wie com.microsoft.teams2.")
            return
        }
        settings.settings.watchlist = updated
        newBundleId = ""
        newName = ""
        bundleIdError = nil
    }

    private func removeWatchedApps() {
        settings.settings.watchlist.removeAll { watchlistSelection.contains($0.bundleId) }
        watchlistSelection.removeAll()
    }
}

// MARK: - Updates

private struct UpdateSettingsTab: View {
    let environment: AppEnvironment

    /// Read when the tab appears and after a check, rather than observed: Sparkle
    /// publishes the date through KVO, and one `onAppear` is a great deal less
    /// machinery than a KVO bridge for a line of text nobody watches change.
    @State private var lastCheck: Date?

    private var updater: UpdaterController { environment.updater }

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Automatisch nach Updates suchen"),
                    isOn: Binding(
                        get: { environment.settings.settings.checkForUpdatesAutomatically },
                        set: { environment.settings.settings.checkForUpdatesAutomatically = $0 }
                    )
                )
                .disabled(!updater.isConfigured)

                Button(String(localized: "Jetzt suchen")) {
                    updater.checkForUpdates()
                    // Sparkle sets the date when the request goes out, so reading it
                    // back on the next run loop turn is enough to show it.
                    Task { @MainActor in lastCheck = updater.lastUpdateCheckDate }
                }
                .disabled(!updater.canCheckForUpdates)
                .help(
                    updater.unavailableReason
                        ?? String(localized: "Fragt die GitHub-Releases nach einer neueren Version.")
                )

                LabeledContent(String(localized: "Zuletzt gesucht")) {
                    Text(lastCheckDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(String(localized: "Installierte Version")) {
                    Text(verbatim: "\(AppVersion.marketing) (\(AppVersion.build))")
                        .textSelection(.enabled)
                }
                if let feed = updater.feedURLString {
                    LabeledContent(String(localized: "Update-Quelle")) {
                        Text(verbatim: feed)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { lastCheck = updater.lastUpdateCheckDate }
    }

    private var lastCheckDescription: String {
        guard let lastCheck else { return String(localized: "noch nie") }
        return lastCheck.formatted(date: .abbreviated, time: .shortened)
    }

    private var footnote: String {
        updater.isConfigured
            ? String(localized: "Updates kommen über GitHub-Releases, werden mit einem eigenen Schlüssel signiert und einmal täglich gesucht. Heruntergeladen und installiert wird nur, was du bestätigst.")
            : String(localized: "Dieser Build hat noch keinen Update-Schlüssel. Updates sind deshalb abgeschaltet; eine neuere Version muss von Hand installiert werden.")
    }
}
