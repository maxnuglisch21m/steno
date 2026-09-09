import Foundation
import StenoCore
import Testing

@testable import Steno

@Suite("RecordingStore")
@MainActor
struct RecordingStoreTests {
    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-store-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeMeeting(
        in root: URL,
        named name: String,
        withMeta: Bool = true
    ) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard withMeta else { return }
        let meta = MeetingMeta(
            mode: .onsite,
            started: Date(),
            trigger: .manual,
            input: AudioInputInfo(device: "Test"),
            app: "0.1.0",
            state: .done
        )
        try meta.jsonData().write(to: folder.appendingPathComponent(RecordingStore.metaFileName))
    }

    @Test("the root is created and reported")
    func createsRoot() {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()

        let result = store.ensureRootExists(root)
        #expect((try? result.get()) == root)
        #expect(FileManager.default.fileExists(atPath: root.stenoPath))
        // Idempotent: called at launch and on every setting change.
        #expect((try? store.ensureRootExists(root).get()) == root)
    }

    @Test("the newest meeting with a meta.json wins")
    func findsNewestMeeting() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()
        _ = store.ensureRootExists(root)

        try Self.makeMeeting(in: root, named: "2026-09-08_0900_Teams")
        try Self.makeMeeting(in: root, named: "2026-09-09_1430_Vorort")
        try Self.makeMeeting(in: root, named: "2026-09-09_0800_Zoom")

        #expect(store.lastMeetingURL(in: root)?.lastPathComponent == "2026-09-09_1430_Vorort")
        #expect(store.meetingFolders(in: root).count == 3)
    }

    @Test("a folder without a meta.json is not a meeting")
    func ignoresFolderWithoutMeta() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()
        _ = store.ensureRootExists(root)

        try Self.makeMeeting(in: root, named: "2026-09-09_1430_Vorort", withMeta: false)
        #expect(store.lastMeetingURL(in: root) == nil)
    }

    @Test("anything else in the recording root is left alone")
    func ignoresForeignFolders() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()
        _ = store.ensureRootExists(root)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notizen", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("liste.txt"))
        try Self.makeMeeting(in: root, named: "2026-09-09_1430_Vorort")

        #expect(store.meetingFolders(in: root).map(\.lastPathComponent) == ["2026-09-09_1430_Vorort"])
    }

    @Test("two meetings in the same minute get distinct folders")
    func avoidsCollisions() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()
        _ = store.ensureRootExists(root)

        let started = Date()
        let first = store.meetingFolderURL(
            in: root, started: started, mode: .onsite, appName: nil, title: nil
        )
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = store.meetingFolderURL(
            in: root, started: started, mode: .onsite, appName: nil, title: nil
        )
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("_2"))
    }

    @Test("a title only reaches the folder name when the caller passes one")
    func usesTitleInName() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore()
        _ = store.ensureRootExists(root)

        let withTitle = store.meetingFolderURL(
            in: root, started: Date(), mode: .online, appName: "Teams", title: "Weekly Sync"
        )
        #expect(withTitle.lastPathComponent.hasSuffix("_Teams_Weekly-Sync"))

        let without = store.meetingFolderURL(
            in: root, started: Date(), mode: .online, appName: "Teams", title: nil
        )
        #expect(without.lastPathComponent.hasSuffix("_Teams"))
    }
}

@Suite("DiskSpace")
struct DiskSpaceTests {
    @Test("the thresholds are the ones the plan names")
    func thresholds() {
        #expect(DiskSpace.refuseBelow == 500 * 1_000_000)
        #expect(DiskSpace.warnBelow == 2 * 1_000_000_000)
        #expect(DiskSpace.refuseBelow < DiskSpace.warnBelow)
    }

    @Test("a folder that does not exist yet still reports its volume's free space")
    func answersForAMissingFolder() {
        // The recording folder is created *after* the check, so the probe has to walk
        // up to a directory that exists.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-\(UUID().uuidString)/deeper/still", isDirectory: true)
        let bytes = DiskSpace.availableBytes(at: missing)
        #expect(bytes != nil)
        #expect((bytes ?? 0) > 0)
    }

    @Test("the level follows from the bytes")
    func levels() {
        // The running machine has room, so the temporary directory is fine.
        #expect(DiskSpace.level(at: FileManager.default.temporaryDirectory) == .fine)
        #expect(!DiskSpace.formatted(1_500_000_000).isEmpty)
    }
}

@Suite("PermissionSnapshot")
struct PermissionSnapshotTests {
    @Test("nothing is granted until it is read")
    func unknownByDefault() {
        let snapshot = PermissionSnapshot.unknown
        for permission in Permission.allCases {
            #expect(snapshot[permission] == .unknown)
        }
        #expect(!snapshot.allRecordingPermissionsGranted)
    }

    @Test("the subscript reads and writes each permission")
    func subscriptRoundTrip() {
        var snapshot = PermissionSnapshot.unknown
        for permission in Permission.allCases {
            snapshot[permission] = .granted
            #expect(snapshot[permission] == .granted)
        }
        #expect(snapshot == .allGranted)
        #expect(snapshot.allRecordingPermissionsGranted)
    }

    @Test("the models are not one of the three recording permissions")
    func modelsAreNotARecordingPermission() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.models = .undetermined
        #expect(snapshot.allRecordingPermissionsGranted)
        #expect(Permission.models.blockedModes.isEmpty)
        #expect(Permission.models.systemSettingsURL == nil)
    }

    @Test("system audio blocks online only")
    func systemAudioBlocksOnline() {
        #expect(Permission.systemAudio.blockedModes == [.online])
        #expect(Permission.microphone.blockedModes == [.online, .onsite])
        #expect(Permission.screenRecording.blockedModes == [.online, .onsite])
    }

    @Test("the first missing permission follows the onboarding order")
    func firstMissingOrder() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.screenRecording = .denied
        #expect(snapshot.firstMissing(for: .onsite) == .screenRecording)

        snapshot.microphone = .denied
        #expect(snapshot.firstMissing(for: .onsite) == .microphone)
        #expect(PermissionSnapshot.allGranted.firstMissing(for: .online) == nil)
    }

    @Test("the three TCC permissions have a System Settings pane, each its own")
    func settingsURLs() {
        let urls = [Permission.microphone, .systemAudio, .screenRecording]
            .compactMap { $0.systemSettingsURL?.absoluteString }
        #expect(urls.count == 3)
        #expect(Set(urls).count == 3)
        #expect(urls.allSatisfy { $0.hasPrefix("x-apple.systempreferences:") })
        #expect(urls.contains { $0.hasSuffix("Privacy_Microphone") })
        #expect(urls.contains { $0.hasSuffix("Privacy_AudioCapture") })
        #expect(urls.contains { $0.hasSuffix("Privacy_ScreenCapture") })
    }

    @Test("every permission has a title and a one-sentence explanation")
    func everyPermissionExplainsItself() {
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.explanation.isEmpty)
        }
    }
}

@Suite("ModelManager")
@MainActor
struct ModelManagerTests {
    @Test("the models live under Application Support, not in the recording root")
    func directory() {
        let manager = ModelManager()
        let path = manager.modelsDirectory.stenoPath
        #expect(path.hasSuffix("/Application Support/Steno/Models"))
    }

    @Test("an empty directory is not an installation")
    func emptyDirectoryIsNotInstalled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manager = ModelManager(directory: directory)
        #expect(!manager.isInstalled)
        #expect(manager.state == .idle)
        #expect(!manager.statusDescription.isEmpty)
    }

    @Test("the ASR version decides which repository folder is looked for")
    func versionPicksFolder() {
        let manager = ModelManager(asrVersion: .v3)
        #expect(manager.asrDirectory.lastPathComponent.contains("v3"))
        manager.asrVersion = .v2
        #expect(manager.asrDirectory.lastPathComponent.contains("v2"))
        #expect(manager.diarizerDirectory.lastPathComponent == "speaker-diarization")
    }

    @Test("the download button is offered while nothing is running")
    func downloadIsAvailable() {
        // Deliberately not started here: the download is the one thing in Steno that
        // touches the network, and a test suite that pulls half a gigabyte off
        // Hugging Face is a test suite nobody runs. What can be checked without it is
        // the gate around it and the sentences it shows.
        let manager = ModelManager(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("steno-models-\(UUID().uuidString)", isDirectory: true)
        )
        #expect(manager.canDownload)
        #expect(!manager.downloadUnavailableReason.isEmpty)
        #expect(!manager.isWarm)
    }

    @Test("every stage of the download says what it is doing")
    func stagesAreNamed() {
        for stage: ModelManager.Stage in [
            .downloadingASR, .downloadingDiarizer, .compiling(nil), .compiling("Encoder.mlmodelc"), .warming
        ] {
            #expect(!stage.localizedDescription.isEmpty)
        }
        // The compile stage is the one that takes minutes on a cold Mac with nothing
        // to show for it, so it says so rather than looking like a hang.
        #expect(ModelManager.Stage.compiling(nil).localizedDescription.contains("Minuten"))
        #expect(ModelManager.Stage.compiling("Encoder").localizedDescription.contains("Encoder"))
    }

    @Test("the model names written into meta.json are the ones the specification uses")
    func modelIdentifiers() {
        let manager = ModelManager(asrVersion: .v3)
        #expect(manager.modelIdentifiers.asr == "parakeet-tdt-0.6b-v3")
        #expect(manager.modelIdentifiers.diarizer == "pyannote-community-1")
        manager.asrVersion = .v2
        #expect(manager.modelIdentifiers.asr == "parakeet-tdt-0.6b-v2")
    }
}

@Suite("AppState")
@MainActor
struct AppStateTests {
    @Test("the status line names the mode and the clock")
    func statusLine() {
        let state = AppState()
        #expect(state.recordingStatusLine == nil)

        state.phase = .recording(mode: .onsite, started: Date().addingTimeInterval(-754))
        let line = state.recordingStatusLine
        #expect(line?.contains(AppState.modeName(.onsite)) == true)
        #expect(line?.contains("12:3") == true)

        state.phase = .idle
        #expect(state.recordingStatusLine == nil)
        #expect(state.elapsed == 0)
    }

    @Test("the phase reports what it is")
    func phaseAccessors() {
        let recording = AppState.Phase.recording(mode: .online, started: Date())
        #expect(recording.isRecording)
        #expect(!recording.isProcessing)
        #expect(recording.recordingMode == .online)
        #expect(recording.startedAt != nil)

        let processing = AppState.Phase.processing(progress: 0.5, label: "x")
        #expect(processing.isProcessing)
        #expect(!processing.isRecording)
        #expect(processing.recordingMode == nil)

        #expect(!AppState.Phase.idle.isRecording)
        #expect(!AppState.Phase.idle.isProcessing)
    }
}

@Suite("HotKeys")
@MainActor
struct HotKeyTests {
    @Test("the three shortcuts are the ones the specification names")
    func shortcuts() {
        #expect(HotKeys.Action.allCases.count == 3)
        #expect(HotKeys.Action.startOnline.shortcutDescription == "⌥⌘R")
        #expect(HotKeys.Action.startOnsite.shortcutDescription == "⌥⌘V")
        #expect(HotKeys.Action.stop.shortcutDescription == "⌥⌘S")
        // Distinct key codes, or two of them would fight over the same combination.
        #expect(Set(HotKeys.Action.allCases.map(\.keyCode)).count == 3)
        #expect(Set(HotKeys.Action.allCases.map(\.modifiers)).count == 1)
    }
}
