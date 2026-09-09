import AppKit
import FluidAudio
import Foundation
import Observation

/// Where the ASR and diarization models live, and whether they are there.
///
/// The download itself is M5. What exists in M0 is the question the onboarding window
/// and the settings window both ask — "are the models on disk?" — answered against the
/// actual layout FluidAudio uses, so that the answer does not become a lie the moment
/// the download is wired up.
///
/// This is the one documented exception to "Steno writes nothing outside the recording
/// root" (specification §11.11): a model cache belongs in Application Support, not in
/// the user's meeting folder, and it is shared across every recording.
@MainActor
@Observable
final class ModelManager {
    enum State: Sendable, Equatable {
        /// Not installed, nothing running.
        case idle
        /// Downloading. `progress` is `nil` while the total size is still unknown.
        case downloading(progress: Double?)
        /// Everything the transcription needs is on disk.
        case installed
        /// The last attempt failed. The string is shown to the user.
        case failed(String)
    }

    enum Failure: LocalizedError {
        /// The download arrives in M5.
        case notImplemented

        var errorDescription: String? {
            switch self {
            case .notImplemented:
                return String(localized: "Der Modell-Download kommt mit der Transkription (M5).")
            }
        }
    }

    /// `~/Library/Application Support/Steno/Models`.
    let modelsDirectory: URL

    private(set) var state: State = .idle

    /// Which Parakeet checkpoint to look for. Set from the settings.
    var asrVersion: ASRVersion = .v3 {
        didSet {
            guard asrVersion != oldValue else { return }
            refresh()
        }
    }

    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        asrVersion: ASRVersion = .v3,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.asrVersion = asrVersion
        self.modelsDirectory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        refresh()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Is it there?

    /// Whether both model sets are complete on disk.
    var isInstalled: Bool {
        isASRInstalled && isDiarizerInstalled
    }

    /// The Parakeet checkpoint for the configured ASR version.
    ///
    /// FluidAudio lays a repository out as `<cache>/<Repo.folderName>/<file>`, and
    /// names the files it needs in `ModelNames`. Both are public, so this checks for
    /// the real thing rather than for "some non-empty directory".
    var isASRInstalled: Bool {
        let directory = asrDirectory
        // v3 ships a different joint decoder than v2, so the required set differs.
        let required: Set<String> = asrVersion == .v3
            ? ModelNames.ASR.requiredModelsV3()
            : ModelNames.ASR.requiredModels
        return contains(required, in: directory)
    }

    /// The offline diarizer: segmentation, filterbank, embedding, PLDA.
    var isDiarizerInstalled: Bool {
        contains(ModelNames.OfflineDiarizer.requiredModels, in: diarizerDirectory)
    }

    var asrDirectory: URL {
        modelsDirectory.appendingPathComponent(asrRepo.folderName, isDirectory: true)
    }

    var diarizerDirectory: URL {
        modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    private var asrRepo: Repo {
        switch asrVersion {
        case .v3: return .parakeetV3
        case .v2: return .parakeetV2
        }
    }

    /// The model identifiers that end up in `transcript.json` and `meta.json`.
    var modelIdentifiers: (asr: String, diarizer: String) {
        (asrRepo.folderName, Repo.diarizer.folderName)
    }

    private func contains(_ required: Set<String>, in directory: URL) -> Bool {
        guard !required.isEmpty else { return false }
        for name in required {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.stenoPath, isDirectory: &isDirectory)
            else { return false }
            // A compiled CoreML model is a directory; an empty one is a failed
            // download, not an installed model.
            if isDirectory.boolValue {
                let contents = try? fileManager.contentsOfDirectory(atPath: url.stenoPath)
                if contents?.isEmpty ?? true { return false }
            }
        }
        return true
    }

    /// Re-reads the disk. Cheap: a handful of `stat` calls.
    func refresh() {
        let installed = isInstalled
        switch state {
        case .downloading:
            // A download in flight decides its own state.
            return
        default:
            state = installed ? .installed : .idle
        }
    }

    // MARK: - Downloading

    /// Downloads both model sets.
    ///
    /// M5. The signature is the one the onboarding and settings buttons already call,
    /// and the state machine around it — idle, downloading with progress, installed,
    /// failed — is already what the interface renders, so wiring
    /// `AsrModels.downloadAndLoad(version:)` and
    /// `OfflineDiarizerManager.prepareModels(directory:)` in behind it changes nothing
    /// above this line.
    func download() async throws {
        Log.transcription.notice("model download requested — not implemented until M5")
        state = .failed(Failure.notImplemented.localizedDescription)
        throw Failure.notImplemented
    }

    /// Whether the "Modelle laden" button should be clickable. False throughout M0.
    var canDownload: Bool { false }

    /// Why it is not clickable, as help text.
    var downloadUnavailableReason: String {
        String(localized: "verfügbar ab der Transkription (M5)")
    }

    // MARK: - Finder

    /// Creates the model directory if needed and shows it. Creating it here is the
    /// only write this class does before M5.
    func revealModelsDirectory() {
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelsDirectory])
    }

    /// A one-line status for the settings window.
    var statusDescription: String {
        switch state {
        case .installed:
            return String(localized: "Modelle installiert")
        case .downloading(let progress):
            guard let progress else { return String(localized: "Modelle werden geladen …") }
            return String(
                format: String(localized: "Modelle werden geladen … %d %%"),
                Int((progress * 100).rounded())
            )
        case .failed(let reason):
            return reason
        case .idle:
            if isASRInstalled != isDiarizerInstalled {
                return String(localized: "Modelle unvollständig")
            }
            return String(localized: "Modelle fehlen")
        }
    }
}
