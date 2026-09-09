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
/// archive format, rules, calendar titles, title in folder name, notifications,
/// anchor interval, update checks — follow them.
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

            RulesSettingsTab(environment: environment)
                .tabItem { Label(String(localized: "Regeln"), systemImage: "list.bullet.rectangle") }

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
                Text(String(localized: "Spracherkennung und Sprechertrennung laufen offline. Der Download ist die einzige Netzverbindung, die Steno je aufbaut."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Regeln

private struct RulesSettingsTab: View {
    /// Set when the calendar prompt came back with a no.
    @State private var calendarRefused = false
    let environment: AppEnvironment

    @State private var newBundleId = ""
    @State private var newName = ""
    @State private var bundleIdError: String?
    @State private var watchlistSelection: Set<String> = []
    @State private var ruleSelection: Set<UUID> = []

    private var settings: SettingsStore { environment.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                watchlistPane
                    .tabItem { Text(String(localized: "Watchlist")) }
                rulesPane
                    .tabItem { Text(String(localized: "Regeln")) }
            }
            .padding(12)
        }
    }

    // MARK: Watchlist

    private var watchlistPane: some View {
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
            .frame(minHeight: 180)

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
        }
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

    // MARK: Rules

    private var rulesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Regeln werden geprüft, sobald ein Meeting erkannt wird. Die erste passende gewinnt; passt keine, fragt Steno nach."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(settings.settings.rules) { rule in
                        RuleRow(rule: binding(for: rule), watchlist: settings.settings.watchlist) {
                            settings.settings.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    if settings.settings.rules.isEmpty {
                        Text(String(localized: "Keine Regeln. Ohne Regel fragt Steno bei jedem erkannten Meeting."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button(String(localized: "Regel hinzufügen")) {
                    settings.settings.rules.append(RecordingRule(pattern: "", action: .ask))
                }
                Spacer()
            }

            Toggle(
                String(localized: "Titel des laufenden Kalendertermins lesen"),
                isOn: Binding(
                    get: { settings.settings.useCalendarTitles },
                    set: { isOn in
                        settings.settings.useCalendarTitles = isOn
                        // The only place calendar access is ever requested. Reading
                        // happens later, and only while this stays on and macOS agrees.
                        guard isOn else { return }
                        Task {
                            let granted = await CalendarTitleReader.requestAccess()
                            if !granted {
                                settings.settings.useCalendarTitles = false
                                calendarRefused = true
                            }
                        }
                    }
                )
            )
            if calendarRefused {
                Text(String(localized: "Ohne Kalenderzugriff bleibt der Termintitel ungenutzt. In den Systemeinstellungen unter „Datenschutz & Sicherheit → Kalender“ wieder erlauben."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "Nur der Titel, nur während einer Aufnahme, nur um den Ordner zu benennen und Regeln zu prüfen. Zoom und Google Meet tragen im Fenstertitel keinen Meetingnamen — das ist der einzige Weg dorthin. Standardmäßig aus."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A binding into the rule with this identity, so the row edits the stored rule
    /// rather than a copy. `SettingsStore` is `@Observable` and reached through a
    /// computed property, so `@Bindable`'s `$` is not available here.
    private func binding(for rule: RecordingRule) -> Binding<RecordingRule> {
        Binding(
            get: { settings.settings.rules.first { $0.id == rule.id } ?? rule },
            set: { updated in
                guard let index = settings.settings.rules.firstIndex(where: { $0.id == rule.id })
                else { return }
                settings.settings.rules[index] = updated
            }
        )
    }
}

/// One rule: app, pattern, regex, action, on/off.
private struct RuleRow: View {
    @Binding var rule: RecordingRule
    let watchlist: [WatchedApp]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .help(String(localized: "Regel aktiv"))

            Picker("", selection: Binding(
                get: { rule.appBundleId ?? "" },
                set: { rule.appBundleId = $0.isEmpty ? nil : $0 }
            )) {
                Text(String(localized: "Jede App")).tag("")
                ForEach(watchlist) { app in
                    Text(app.name).tag(app.bundleId)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField(String(localized: "Titel enthält …"), text: $rule.pattern)
                .frame(minWidth: 130)

            Toggle(String(localized: "Regex"), isOn: $rule.isRegex)
                .help(String(localized: "Muster als regulären Ausdruck auswerten"))

            Picker("", selection: $rule.action) {
                Text(String(localized: "nie")).tag(RecordingRuleAction.never)
                Text(String(localized: "fragen")).tag(RecordingRuleAction.ask)
                Text(String(localized: "immer")).tag(RecordingRuleAction.always)
            }
            .labelsHidden()
            .frame(width: 92)

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Regel entfernen"))
        }
    }
}

// MARK: - Updates

private struct UpdateSettingsTab: View {
    let environment: AppEnvironment

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
                Button(String(localized: "Jetzt suchen")) {}
                    .disabled(true)
                    .help(String(localized: "verfügbar ab der ersten Veröffentlichung"))
                Text(String(localized: "Updates kommen über GitHub-Releases und sind mit einem eigenen Schlüssel signiert. Die Einstellung wird gespeichert; verdrahtet wird sie mit der ersten Veröffentlichung."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
