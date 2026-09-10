#if DEBUG
import AppKit
import Foundation
import StenoCore

/// Launch arguments that drive the app from the outside, so the M0 flow can be checked
/// without a meeting, a microphone, or a click.
///
/// Debug builds only. They exist because the interesting part of M0 — folder created,
/// `meta.json` written at every state change, the icon and the clock, the hotkey path
/// — is otherwise only reachable by hand, and a release build has no business
/// accepting instructions from its command line.
///
/// ```sh
/// open build/Build/Products/Debug/Steno.app --args --simulate-recording 15 onsite
/// open build/Build/Products/Debug/Steno.app --args --simulate-recording 12 online
/// open build/Build/Products/Debug/Steno.app --args --simulate-recording 12 online --tap-target com.apple.Music
/// open build/Build/Products/Debug/Steno.app --args --simulate-null-recording 3 online
///
/// // M4: screenshots without audio, with one log line per gate decision.
/// open build/Build/Products/Debug/Steno.app --args \
///   --simulate-recording 30 onsite --null-recorder --screenshot-log
/// open build/Build/Products/Debug/Steno.app --args --print-microphone-mode
/// open build/Build/Products/Debug/Steno.app --args --open-settings
/// open build/Build/Products/Debug/Steno.app --args --open-onboarding
///
/// // M3: detection, popup, rules, auto-stop — without a meeting.
/// open build/Build/Products/Debug/Steno.app --args \
///   --simulate-detection com.microsoft.teams2 "Weekly Sync" \
///   --auto-answer record --auto-stop 5 --simulate-detection-end 8
/// open build/Build/Products/Debug/Steno.app --args \
///   --simulate-detection com.microsoft.teams2 "Weekly Sync" --auto-answer ignore
/// open build/Build/Products/Debug/Steno.app --args \
///   --simulate-detection com.microsoft.teams2 "Weekly Sync" --rule never Weekly
///
/// // M5: the models, and transcription of a folder that already has audio.
/// open build/Build/Products/Debug/Steno.app --args --download-models
/// open build/Build/Products/Debug/Steno.app --args --transcribe ~/Meetings/2026-09-09_1430_Vorort
///
/// // M6: the crash test. Two runs, both against a scratch root and a scratch defaults
/// // suite, so that neither touches the copy of Steno somebody may be recording with.
/// build/Build/Products/Debug/Steno.app/Contents/MacOS/Steno \
///   --root /tmp/m6/Meetings --defaults-suite de.21m.steno.m6 \
///   --simulate-recording 30 onsite --synthetic-recorder --crash-after 12
/// build/Build/Products/Debug/Steno.app/Contents/MacOS/Steno \
///   --root /tmp/m6/Meetings --defaults-suite de.21m.steno.m6 --recover-and-quit
/// ```
struct DebugLaunchArguments {
    var openSettings = false
    var openOnboarding = false
    /// Seconds to record, and in which mode, before quitting.
    var simulate: (seconds: Double, mode: MeetingMode)?
    /// Whether the simulation goes through the real recorders or through
    /// `NullRecorder`. Real is the default: since M1 there is something to record.
    var useNullRecorder = false
    /// Print `AVCaptureDevice.activeMicrophoneMode` and quit. Specification §3b.1 is
    /// gated on a system-wide setting that lives in Control Center, so being able to
    /// read what the app sees, without a recording, is the only way to check it from
    /// the outside.
    var printMicrophoneMode = false
    /// Bundle identifier the `online` tap must point at, instead of whatever is
    /// actually in a meeting. The one way to aim the tap at a named app without
    /// waiting for a real meeting to start.
    var tapTargetBundleId: String?
    /// `--screenshot-log`: one log line per gate decision — display, active, changed
    /// share, verdict. The only way to see why a frame was or was not kept without
    /// reading the files afterwards and guessing.
    var logsScreenshotDecisions = false

    // MARK: M3

    /// `--simulate-detection <bundle id> [title]`: pretends that app started reading
    /// the microphone, with that window title, and lets the whole of specification §2
    /// run on it — debounce, rules, popup, recording, auto-stop.
    ///
    /// The bundle identifier does not have to belong to a running app. The tap target
    /// then resolves to nothing and `ProcessTapRecorder` falls back to a system-wide
    /// tap, which is a real recording of a real Mac and exactly what is wanted here.
    var simulateDetection: (bundleId: String, title: String?)?
    /// `--simulate-detection-end <seconds>`: how long after the trigger the fake app
    /// stops reading the microphone, which is what starts the auto-stop clock.
    var simulateDetectionEnd: Double?
    /// `--auto-answer record|ignore`: answers the suggestion panel a second after it
    /// appears, so a run needs no click.
    var autoAnswer: SuggestionPanel.Answer?
    /// `--auto-stop <seconds>`: shortens `autoStopDelay`, so auto-stop can be observed
    /// in a ten-second run instead of a fifty-second one.
    var autoStopDelay: TimeInterval?
    /// `--suggestion-timeout <seconds>`: shortens the twenty-second panel timeout.
    var suggestionTimeout: TimeInterval?
    /// `--rule never|ask|always <pattern>`: injects one rule ahead of the user's own,
    /// for this run only.
    var injectedRule: RecordingRule?

    // MARK: M5

    /// `--download-models`: downloads, compiles, and warms the models, then reports
    /// where they are and how big they are, and quits.
    ///
    /// The one command in the whole app that touches the network. It exists because the
    /// download is a once-per-Mac step that takes minutes, and doing it from the
    /// command line — before a meeting rather than during one — is how the first
    /// transcription avoids paying for it.
    var downloadModels = false
    /// `--transcribe <folder>`: hands an existing meeting folder to the queue and quits
    /// when it is finished, printing the resulting state and the head of the transcript.
    ///
    /// Everything downstream of the audio file is the real thing: the real splitter,
    /// the real models, the real merge, the real `meta.json`. Only the recording is
    /// missing, which is the part that needs a meeting.
    var transcribeFolder: URL?

    // MARK: M6

    /// `--root <path>`: the recording root for this process only, never persisted.
    ///
    /// The reason it exists: two Stenos can run on this Mac at once — the one the user
    /// is recording their real meetings with, and one being tested. A test run that
    /// changed the setting would move the user's root out from under them, so the
    /// override lives in the process and dies with it.
    var rootFolderOverride: URL?
    /// `--defaults-suite <name>`: which `UserDefaults` the settings and the
    /// transcription queue live in, for the same reason.
    var defaultsSuiteName: String?
    /// `--synthetic-recorder`: 440/880 Hz through the real `WAVWriter`, no hardware.
    var useSyntheticRecorder = false
    /// `--crash-after <seconds>`: `_exit(0)` after that much audio has been written,
    /// with nothing closed. Only the synthetic recorder honours it — see there for why
    /// killing a real recording is not an option.
    var crashAfter: TimeInterval?
    /// `--recover-and-quit`: run the launch-time recovery scan, wait for the queue to
    /// drain, print what every folder ended up as, and quit. The second half of the
    /// crash test.
    var recoverAndQuit = false

    /// A shared parse of this process's own arguments.
    ///
    /// `AppEnvironment.shared` is built before `applicationDidFinishLaunching` runs, and
    /// `--root` and `--defaults-suite` have to be in place before the settings store
    /// reads anything — so both places read this rather than parsing twice and
    /// disagreeing.
    static let current = DebugLaunchArguments(CommandLine.arguments)

    var isActive: Bool {
        openSettings || openOnboarding || printMicrophoneMode
            || simulate != nil || simulateDetection != nil
            || downloadModels || transcribeFolder != nil || recoverAndQuit
    }

    /// Whether the app's own detection may run. A simulation drives detection itself
    /// with a fake process list, and every other debug run wants it off entirely, so
    /// that a real meeting on this Mac cannot interrupt the thing being measured.
    var wantsAppDetection: Bool { !isActive }

    init(_ arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--open-settings":
                openSettings = true
            case "--open-onboarding":
                openOnboarding = true
            case "--print-microphone-mode":
                printMicrophoneMode = true
            case "--tap-target":
                tapTargetBundleId = arguments[safe: index + 1]
                index += 1
            case "--simulate-detection":
                let bundleId = arguments[safe: index + 1] ?? "com.microsoft.teams2"
                index += 1
                // The title is optional, and must not swallow the next flag.
                var title: String?
                if let next = arguments[safe: index + 1], !next.hasPrefix("--") {
                    title = next
                    index += 1
                }
                simulateDetection = (bundleId, title)
            case "--simulate-detection-end":
                simulateDetectionEnd = Double(arguments[safe: index + 1] ?? "")
                index += 1
            case "--auto-answer":
                autoAnswer = SuggestionPanel.Answer(rawValue: arguments[safe: index + 1] ?? "")
                index += 1
            case "--null-recorder":
                useNullRecorder = true
            case "--screenshot-log":
                logsScreenshotDecisions = true
            case "--auto-stop":
                autoStopDelay = Double(arguments[safe: index + 1] ?? "")
                index += 1
            case "--suggestion-timeout":
                suggestionTimeout = Double(arguments[safe: index + 1] ?? "")
                index += 1
            case "--rule":
                let action = RecordingRuleAction(rawValue: arguments[safe: index + 1] ?? "") ?? .ask
                let pattern = arguments[safe: index + 2] ?? ""
                injectedRule = RecordingRule(pattern: pattern, action: action)
                index += 2
            case "--download-models":
                downloadModels = true
            case "--transcribe":
                if let path = arguments[safe: index + 1] {
                    transcribeFolder = URL(
                        fileURLWithPath: (path as NSString).expandingTildeInPath,
                        isDirectory: true
                    )
                }
                index += 1
            case "--root":
                if let path = arguments[safe: index + 1] {
                    rootFolderOverride = URL(
                        fileURLWithPath: (path as NSString).expandingTildeInPath,
                        isDirectory: true
                    )
                }
                index += 1
            case "--defaults-suite":
                defaultsSuiteName = arguments[safe: index + 1]
                index += 1
            case "--synthetic-recorder":
                useSyntheticRecorder = true
            case "--crash-after":
                crashAfter = Double(arguments[safe: index + 1] ?? "")
                index += 1
            case "--recover-and-quit":
                recoverAndQuit = true
            case "--simulate-recording", "--simulate-null-recording":
                useNullRecorder = arguments[index] == "--simulate-null-recording"
                let seconds = Double(arguments[safe: index + 1] ?? "") ?? 3
                let mode = MeetingMode(rawValue: arguments[safe: index + 2] ?? "") ?? .onsite
                simulate = (seconds, mode)
                index += 2
            default:
                break
            }
            index += 1
        }
    }

    @MainActor
    func run(in environment: AppEnvironment) {
        if printMicrophoneMode {
            reportMicrophoneMode()
            NSApp.terminate(nil)
            return
        }
        if openOnboarding {
            OnboardingWindowController.shared.show(environment: environment)
        }
        if openSettings {
            SettingsWindowController.shared.show(environment: environment)
        }
        if openSettings || openOnboarding {
            // Report what actually appeared, so the verification does not depend on
            // being able to look at the screen.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // Class name, title, and size, because a status item brings windows
                // of its own along and only the size tells them apart at a glance.
                let described = NSApp.windows
                    .filter(\.isVisible)
                    .map { "\(type(of: $0))“\($0.title)”\(Int($0.frame.width))x\(Int($0.frame.height))" }
                let line = "steno-debug: windows: \(described.joined(separator: " | "))\n"
                Log.app.notice("debug: \(line, privacy: .public)")
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        if recoverAndQuit {
            runRecovery(in: environment)
            return
        }
        if downloadModels {
            runModelDownload(in: environment)
            return
        }
        if let transcribeFolder {
            runTranscription(of: transcribeFolder, in: environment)
            return
        }
        if let simulateDetection {
            runDetectionSimulation(simulateDetection, in: environment)
            return
        }
        guard let simulate else { return }
        runSimulation(simulate, in: environment)
    }

    /// Prints the microphone mode the way `MicrophoneModeCheck` sees it, plus what the
    /// gate would do with it.
    @MainActor
    private func reportMicrophoneMode() {
        let active = MicrophoneModeCheck.active()
        let preferred = MicrophoneModeCheck.preferred()
        let decision: String
        switch MicrophoneModeCheck.decision(for: active) {
        case .proceed: decision = "proceed"
        case .proceedWithHint: decision = "proceed-with-hint"
        case .block: decision = "block"
        }
        let line = """
        steno-debug: microphone mode: active=\(active?.rawValue ?? "unknown") \
        preferred=\(preferred?.rawValue ?? "unknown") onsite=\(decision)

        """
        Log.audio.notice("debug: \(line, privacy: .public)")
        FileHandle.standardError.write(Data(line.utf8))
    }

    @MainActor
    private func runSimulation(
        _ simulate: (seconds: Double, mode: MeetingMode),
        in environment: AppEnvironment
    ) {
        if let recorder = simulationRecorder {
            environment.coordinator.useRecorderFactory(FixedRecorderFactory(recorder))
        }
        environment.coordinator.forcedTapTargetBundleId = tapTargetBundleId
        environment.coordinator.logsScreenshotDecisions = logsScreenshotDecisions
        Task { @MainActor in
            // The permission snapshot has to be in before `canStart` is asked, or the
            // simulation would refuse itself.
            await environment.permissions.refresh()
            environment.appState.permissions = environment.permissions.snapshot

            // The simulation exercises the flow, not the permission gate; the gate has
            // its own tests. Pretending the three TCC answers are in place is what
            // makes this runnable on a machine that has never been asked.
            var snapshot = environment.appState.permissions
            snapshot.microphone = .granted
            snapshot.systemAudio = .granted
            snapshot.screenRecording = .granted
            environment.appState.permissions = snapshot

            environment.coordinator.start(mode: simulate.mode, trigger: .manual)
            try? await Task.sleep(for: .seconds(simulate.seconds))
            let folder = environment.appState.phase.isRecording
                ? nil
                : environment.appState.lastMeetingURL
            environment.coordinator.stop()
            // Wait for the stop path rather than guessing at it: with a real recorder
            // it has hardware to release and a file to close, and quitting underneath
            // that would leave exactly the truncated header M6 exists to repair.
            // Longer than the coordinator's own stop deadline, so that a recorder
            // that has to be given up on still gets its folder finished before the
            // app quits.
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while environment.appState.phase != .idle, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }

            let result = environment.appState.lastMeetingURL ?? folder
            let line = """
            steno-debug: simulated \(simulate.mode.rawValue) recording → \
            \(result?.stenoPath ?? "nothing")\(Self.audioSummary(in: result))\
            \(Self.screenshotSummary(in: result))

            """
            Log.app.notice("debug: \(line, privacy: .public)")
            FileHandle.standardError.write(Data(line.utf8))
            NSApp.terminate(nil)
        }
    }

    /// Which recorder a simulated recording writes through.
    ///
    /// `nil` means "leave the coordinator's own factory alone", which is the real
    /// hardware. The synthetic one wins over `--null-recorder`: asking for both is
    /// asking for a file, and only one of the two writes one.
    private var simulationRecorder: (any AudioRecorder)? {
        if useSyntheticRecorder { return SyntheticRecorder(crashAfter: crashAfter) }
        if useNullRecorder { return NullRecorder() }
        return nil
    }

    // MARK: - M6: recovery

    /// Runs the launch-time recovery scan, waits for the queue to finish, and reports
    /// what every folder in the root ended up as.
    ///
    /// The scan itself has already run — `AppEnvironment.start` does it before detection
    /// — so this waits on the result rather than repeating it. Everything is the real
    /// thing: the real repair, the real queue, the real models, the real `meta.json`.
    @MainActor
    private func runRecovery(in environment: AppEnvironment) {
        Task { @MainActor in
            let root = environment.settings.rootFolderURL
            let report = environment.lastRecoveryReport
            Self.report("recovery in \(root.stenoPath): \(report?.logDescription ?? "no scan ran")")
            Self.report("menu line: \(report?.localizedNotice ?? "none")")

            // Generously bounded: transcription of a few seconds of audio takes seconds,
            // but a cold Core ML model takes minutes and hanging for ever would be worse
            // than reporting nothing.
            await Self.waitFor(seconds: 900) {
                environment.transcription.pendingCount == 0
                    && environment.transcription.current == nil
            }
            // The queue clears its entry before the last `meta.json` write lands.
            try? await Task.sleep(for: .seconds(1))

            for folder in environment.store.meetingFolders(in: root).reversed() {
                let state = environment.store.state(of: folder)?.rawValue ?? "unreadable"
                let lock = FileManager.default.fileExists(
                    atPath: MeetingLock.url(in: folder).stenoPath
                ) ? " · lock left behind" : ""
                Self.report(
                    """
                    \(folder.lastPathComponent) → state \(state)\
                    \(Self.stopReasonSummary(in: folder))\(lock)\
                    \(Self.audioSummary(in: folder))\(Self.transcriptSummary(in: folder))
                    """
                )
            }
            NSApp.terminate(nil)
        }
    }

    /// " · stopReason crash · 12.3 s", or nothing when `meta.json` says neither.
    @MainActor
    private static func stopReasonSummary(in folder: URL) -> String {
        guard
            let data = try? Data(contentsOf: folder.appendingPathComponent(RecordingStore.metaFileName)),
            let meta = try? MeetingMeta.decode(from: data)
        else { return "" }
        var parts: [String] = []
        if let reason = meta.stopReason { parts.append("stopReason \(reason.rawValue)") }
        if let duration = meta.duration { parts.append(String(format: "%.1f s", duration)) }
        parts.append("\(meta.screenshots) screenshot(s)")
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    // MARK: - M5: models and transcription

    /// Downloads the models, warms them, and reports what landed where.
    @MainActor
    private func runModelDownload(in environment: AppEnvironment) {
        let models = environment.models
        Task { @MainActor in
            let started = Date()
            var warmSeconds: TimeInterval = 0
            do {
                // The download and the compile.
                try await models.prepare(warm: false)
                let downloaded = Date()
                // Then one prediction through every model, which is the step that
                // takes minutes on a cold Mac and would otherwise happen inside the
                // first meeting's transcription.
                let warmStart = Date()
                await models.warmUpIfNeeded()
                warmSeconds = Date().timeIntervalSince(warmStart)
                let total = Self.seconds(Date().timeIntervalSince(started))
                let fetch = Self.seconds(downloaded.timeIntervalSince(started))
                Self.report(
                    "models ready in \(total) (download+compile \(fetch), warm-up \(Self.seconds(warmSeconds)))"
                )
            } catch {
                Self.report("model download failed: \(error.localizedDescription)")
            }
            Self.report("model directory \(models.modelsDirectory.stenoPath)")
            let asrSize = Self.megabytes(ModelManager.directorySize(of: models.asrDirectory))
            let diarizerSize = Self.megabytes(ModelManager.directorySize(of: models.diarizerDirectory))
            Self.report(
                "sizes: total \(Self.megabytes(models.installedBytes())), asr \(asrSize), diarizer \(diarizerSize)"
            )
            Self.report("installed=\(models.isInstalled) warm=\(models.isWarm)")
            NSApp.terminate(nil)
        }
    }

    /// Transcribes a folder that already has `audio.wav` and a `meta.json`.
    @MainActor
    private func runTranscription(of folder: URL, in environment: AppEnvironment) {
        Task { @MainActor in
            guard let session = try? RecordingSession(existing: folder) else {
                Self.report("no readable meta.json in \(folder.stenoPath)")
                NSApp.terminate(nil)
                return
            }
            // A folder left in `recording` — a crash, or one assembled by hand for a
            // test — is moved on rather than refused: M6 does the same thing at launch.
            if session.meta.state == .recording {
                try? session.transition(to: .transcribing)
            }
            if session.meta.state == .done || session.meta.state == .failed {
                environment.transcription.reprocess(folder)
            } else {
                environment.transcription.enqueue(folder)
            }

            // Waited on the folder rather than on the menu-bar phase: the queue starts
            // its work in a task of its own, so the phase is still idle for a moment
            // after the hand-over and a run that watched it would quit before anything
            // had begun. Generously bounded — an hour of audio takes minutes, and a
            // cold model takes minutes more — because hanging for ever would be worse
            // than reporting nothing.
            await Self.waitFor(seconds: 3600) {
                let state = environment.store.state(of: folder)
                return state == .done || state == .failed
            }

            let state = environment.store.state(of: folder)
            Self.report("\(folder.lastPathComponent) → state \(state?.rawValue ?? "unreadable")")
            Self.report(Self.transcriptSummary(in: folder))
            for line in Self.head(ofTranscriptIn: folder, lines: 5) {
                Self.report("transcript.md | \(line)")
            }
            NSApp.terminate(nil)
        }
    }

    /// " · transcript.md 12 line(s) · audio.m4a 4.1 MB · _work gone"
    private static func transcriptSummary(in folder: URL) -> String {
        var parts: [String] = []
        for name in ["transcript.json", "transcript.md", "audio.wav", "audio.m4a", "audio.flac"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.stenoPath) else { continue }
            parts.append("\(name) \(megabytes(AudioTranscoder.size(of: url)))")
        }
        let work = ChannelSplitter.workDirectory(in: folder)
        parts.append(
            FileManager.default.fileExists(atPath: work.stenoPath) ? "_work kept" : "_work gone"
        )
        return "files: " + parts.joined(separator: " · ")
    }

    /// The first `lines` lines of `transcript.md` that carry speech, or the header when
    /// there is none.
    private static func head(ofTranscriptIn folder: URL, lines: Int) -> [String] {
        guard
            let text = try? String(
                contentsOf: folder.appendingPathComponent("transcript.md"),
                encoding: .utf8
            )
        else { return ["no transcript.md"] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let speech = all.filter { $0.hasPrefix("[") }
        return Array((speech.isEmpty ? all : speech).prefix(lines))
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", interval)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - M3: detection

    /// Runs specification §2 end to end against a process list this function writes.
    ///
    /// Everything downstream of the fake list is the real thing: the real state
    /// machine with its debounce, the real rules, the real panel, the real recorder,
    /// the real `meta.json`. Only the answer to "is Teams reading the microphone" is
    /// invented — which is the one part that cannot be arranged on a Mac with no
    /// meeting on it.
    @MainActor
    private func runDetectionSimulation(
        _ simulate: (bundleId: String, title: String?),
        in environment: AppEnvironment
    ) {
        let settings = environment.settings
        if let recorder = simulationRecorder {
            environment.coordinator.useRecorderFactory(FixedRecorderFactory(recorder))
        }
        environment.coordinator.logsScreenshotDecisions = logsScreenshotDecisions
        if let autoStopDelay { settings.settings.autoStopDelay = autoStopDelay }
        if let injectedRule {
            // Ahead of the user's own rules, because first match wins and this run is
            // about the injected one.
            settings.settings.rules.insert(injectedRule, at: 0)
        }

        // The watchlist has to know the app, or nothing about it is a meeting.
        let app: WatchedApp
        if let known = settings.settings.watchlist.first(where: { $0.bundleId == simulate.bundleId }) {
            app = known
        } else {
            app = WatchedApp(
                bundleId: simulate.bundleId,
                name: String(simulate.bundleId.split(separator: ".").last ?? "App")
            )
            settings.settings.watchlist.append(app)
        }

        let source = FakeProcessAudioSource()
        environment.detector.useSource(source)
        // A two-second debounce rather than five: the five seconds are tested against
        // a clock in `MeetingDetectorLogicTests`, and this run is about everything
        // downstream of them.
        environment.detector.setTiming(
            MeetingDetectorTiming(trigger: 2, autoStop: settings.settings.autoStopDelay, rearm: 60)
        )
        environment.ruleEngine.useTitleSource(FixedMeetingTitleSource(simulate.title))
        if let suggestionTimeout {
            environment.detectionController.suggestionTimeout = suggestionTimeout
        }

        let end = simulateDetectionEnd
        let answer = autoAnswer
        // The permission gate is not what this run tests, and faking the snapshot is
        // not enough: the permission monitor refreshes in the background and would
        // overwrite it during the seconds this simulation spends waiting.
        environment.coordinator.ignoresPermissionGate = true

        Task { @MainActor in
            environment.detectionController.start()
            source.setInput(true, bundleId: app.bundleId)

            // The panel, if one appears, and the answer that would otherwise be a click.
            if let answer {
                await Self.waitFor(seconds: 30) { SuggestionPanel.shared.isVisible }
                if SuggestionPanel.shared.isVisible {
                    Self.report("suggestion panel at \(SuggestionPanel.shared.frameDescription ?? "?")")
                    try? await Task.sleep(for: .seconds(1))
                    SuggestionPanel.shared.answerForTesting(answer)
                } else {
                    Self.report("no suggestion panel appeared")
                }
            } else {
                await Self.waitFor(seconds: 10) { SuggestionPanel.shared.isVisible }
                Self.report(
                    "suggestion panel: \(SuggestionPanel.shared.frameDescription ?? "none")"
                )
            }

            // Opening a tap and an aggregate device takes a moment, and the recording
            // does not exist until it has: waited for explicitly, so that the report
            // below cannot mistake "still starting" for "never started".
            await Self.waitFor(seconds: 25) { environment.appState.phase.isRecording }
            let didRecord = environment.appState.phase.isRecording
            Self.report(didRecord ? "recording started" : "no recording started")

            // The meeting ends: the fake app stops reading the microphone, which is
            // what starts the auto-stop clock.
            if let end, didRecord {
                let deadline = ContinuousClock.now.advanced(by: .seconds(end))
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                source.setInput(false, bundleId: app.bundleId)
                Self.report("simulated meeting end")
            }

            // Auto-stop, then the folder being finished. Generously bounded: this is a
            // debug run, and hanging for ever would be worse than reporting nothing.
            if didRecord {
                let budget = settings.settings.autoStopDelay + 40
                await Self.waitFor(seconds: budget) { environment.appState.phase == .idle }
            }

            let folder = environment.appState.lastMeetingURL
            Self.report(
                """
                detection simulation for \(app.bundleId) → \(folder?.stenoPath ?? "no recording")\
                \(Self.audioSummary(in: folder))\(Self.screenshotSummary(in: folder))
                """
            )
            NSApp.terminate(nil)
        }
    }

    /// Waits until `condition` holds or the budget runs out. Polls, because the things
    /// being waited for are `@Observable` properties and an AppKit window's visibility.
    @MainActor
    private static func waitFor(seconds: TimeInterval, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One line on standard error and one in the unified log, which is how every debug
    /// run reports what it saw.
    private static func report(_ message: String) {
        let line = "steno-debug: \(message)\n"
        Log.app.notice("debug: \(line, privacy: .public)")
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// " · audio.wav 1440044 bytes", or nothing when no audio was written.
    private static func audioSummary(in folder: URL?) -> String {
        guard let folder else { return "" }
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: audio.stenoPath),
            let size = attributes[.size] as? Int64
        else { return "" }
        return " · \(WAVWriter.fileName) \(size) bytes"
    }

    /// " · 14 screenshots on 2 display(s), 1.2 MB", or nothing when none were written.
    ///
    /// Read back off the index rather than off the capturer, so that what is reported
    /// is what a downstream reader would find.
    static func screenshotSummary(in folder: URL?) -> String {
        guard
            let folder,
            let text = try? String(
                contentsOf: folder.appendingPathComponent(ScreensIndexWriter.fileName),
                encoding: .utf8
            ),
            let entries = try? ScreensIndexEntry.decode(jsonl: text, lenient: true),
            !entries.isEmpty
        else { return "" }

        let displays = Set(entries.map(\.display)).sorted()
        let active = entries.filter(\.active).count
        var bytes = 0
        for entry in entries {
            let url = folder.appendingPathComponent(entry.file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.stenoPath)
            bytes += (attributes?[.size] as? Int) ?? 0
        }
        return """
             · \(entries.count) screenshots on display(s) \
            \(displays.map(String.init).joined(separator: ",")) \
            (\(active) active, \(bytes / 1024) KB)
            """
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
