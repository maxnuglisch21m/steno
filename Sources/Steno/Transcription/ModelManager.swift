import AppKit
import FluidAudio
import Foundation
import Observation
import StenoCore

/// Where the ASR and diarization models live, whether they are there, and the one
/// network connection Steno ever makes.
///
/// Specification §0: "Netzwerk — nur einmaliger Modell-Download (Hugging Face). Danach
/// 100 % offline." This class is the whole of that sentence. Everything downstream —
/// `FluidASR`, `FluidDiarizer`, `TranscriptionQueue` — reads from disk and never opens
/// a socket.
///
/// This is also the one documented exception to "Steno writes nothing outside the
/// recording root" (specification §11.11): a model cache belongs in Application
/// Support, not in the user's meeting folder, and it is shared across every recording.
/// Both FluidAudio APIs take a directory, so the cache is
/// `~/Library/Application Support/Steno/Models` rather than FluidAudio's own default of
/// `~/Library/Application Support/FluidAudio/Models`.
@MainActor
@Observable
final class ModelManager {
    /// What the download is doing right now.
    ///
    /// `compiling` and `warming` are separate from `downloading` on purpose. The first
    /// prediction of a freshly downloaded Core ML model compiles it for this Mac's
    /// Neural Engine, and on a cold machine that takes minutes with no network traffic
    /// and no progress to show. Reported as "downloading" it looks like a hang; named,
    /// it is a step with an end.
    enum Stage: Sendable, Equatable {
        /// Fetching the Parakeet checkpoint. Roughly 470 MB for v3 with the int8 encoder.
        case downloadingASR
        /// Fetching the diarizer's four Core ML bundles. Roughly 20 MB.
        case downloadingDiarizer
        /// Core ML is compiling a model for this Mac. Minutes, the first time.
        case compiling(String?)
        /// Running one prediction through every model, so the first meeting does not.
        case warming

        var localizedDescription: String {
            switch self {
            case .downloadingASR:
                return String(localized: "Sprachmodell wird geladen …")
            case .downloadingDiarizer:
                return String(localized: "Sprechertrennung wird geladen …")
            case .compiling(let name):
                guard let name else {
                    return String(localized: "Modelle werden kompiliert … (beim ersten Mal Minuten)")
                }
                return String(
                    format: String(localized: "%@ wird kompiliert … (beim ersten Mal Minuten)"),
                    name
                )
            case .warming:
                return String(localized: "Modelle werden aufgewärmt …")
            }
        }
    }

    enum State: Sendable, Equatable {
        /// Not installed, nothing running.
        case idle
        /// Downloading, compiling, or warming. `progress` is `nil` while the step has
        /// no measurable share.
        case preparing(stage: Stage, progress: Double?)
        /// Everything the transcription needs is on disk and warm.
        case installed
        /// The last attempt failed. The string is shown to the user.
        case failed(String)

        var isPreparing: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    enum Failure: LocalizedError {
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return String(localized: "Der Modell-Download läuft bereits.")
            }
        }
    }

    /// `~/Library/Application Support/Steno/Models`.
    let modelsDirectory: URL

    /// The loaded recognizer and diarizer, shared by the download (which warms them)
    /// and the queue (which uses them). Held here so that the models are loaded once
    /// per launch rather than once per meeting.
    let asr = FluidASR()
    let diarizer = FluidDiarizer()

    private(set) var state: State = .idle

    /// Whether the models have been warmed in this process. Until they have, the first
    /// transcription pays for Core ML compilation, which is worth saying out loud.
    private(set) var isWarm = false

    /// Which Parakeet checkpoint to look for. Set from the settings.
    var asrVersion: ASRVersion = .v3 {
        didSet {
            guard asrVersion != oldValue else { return }
            refresh()
        }
    }

    private let fileManager: FileManager
    private var task: Task<Void, any Error>?

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
        let required: Set<String> = asrVersion == .v3
            // v3 ships a different joint decoder than v2, so the required set differs.
            ? ModelNames.ASR.requiredModelsV3()
            : ModelNames.ASR.requiredModels
        // The vocabulary is a plain JSON file next to the models, and loading fails
        // without it — so a cache missing it is not installed, however many
        // `.mlmodelc` bundles are there.
        return contains(required.union([ModelNames.ASR.vocabularyFile]), in: asrDirectory)
    }

    /// The offline diarizer: segmentation, filterbank, embedding, PLDA.
    var isDiarizerInstalled: Bool {
        contains(ModelNames.OfflineDiarizer.requiredModels, in: diarizerDirectory)
    }

    var asrDirectory: URL {
        modelsDirectory.appendingPathComponent(asrVersion.repo.folderName, isDirectory: true)
    }

    var diarizerDirectory: URL {
        modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    /// The model identifiers that end up in `transcript.json` and `meta.json`.
    var modelIdentifiers: ModelIdentifiers {
        ModelIdentifiers(
            asr: asrVersion.modelIdentifier,
            diarizer: FluidDiarizer.modelIdentifier
        )
    }

    /// Bytes on disk, for the settings window and the debug report. Walks the tree, so
    /// it is called on demand rather than on every redraw.
    func installedBytes() -> Int64 {
        Self.directorySize(of: modelsDirectory, fileManager: fileManager)
    }

    nonisolated static func directorySize(of url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
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
        // A download in flight decides its own state.
        guard !state.isPreparing else { return }
        state = isInstalled ? .installed : .idle
    }

    // MARK: - Downloading

    /// Downloads both model sets, compiles them, and warms them.
    ///
    /// The only network access in the whole app. Everything after it — every
    /// transcription, on every launch — reads the files this wrote.
    ///
    /// Safe to call when the models are already there: FluidAudio checks the cache
    /// first and skips straight to loading, which is what makes this double as
    /// "prepare for transcription".
    func download() async throws {
        if let task {
            // A second click while the first download runs joins it rather than
            // starting a competing one.
            return try await task.value
        }
        let running = Task<Void, any Error> { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            try await self.prepare(warm: true)
        }
        task = running
        try await running.value
    }

    /// Loads everything the queue needs, downloading only what is missing.
    ///
    /// - Parameter warm: whether to run one prediction through the models afterwards.
    ///   The download path does; a queue that is about to transcribe anyway does not
    ///   need to pay for it twice.
    func prepare(warm: Bool) async throws {
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

            let version = asrVersion
            state = .preparing(stage: .downloadingASR, progress: nil)
            try await asr.load(
                directory: asrDirectory,
                version: version,
                progress: { [weak self] update in
                    // FluidAudio reports from its own threads; the interface lives on
                    // the main actor, so the hop happens here and nowhere else.
                    Task { @MainActor [weak self] in
                        self?.report(update, downloading: .downloadingASR)
                    }
                }
            )

            state = .preparing(stage: .downloadingDiarizer, progress: nil)
            // The cache root, not the repository folder — see `FluidDiarizer`.
            try await diarizer.load(directory: modelsDirectory)

            if warm {
                state = .preparing(stage: .warming, progress: nil)
                try await asr.warmUp()
                isWarm = true
            }

            state = isInstalled ? .installed : .idle
            Log.transcription.notice(
                "models ready in \(self.modelsDirectory.stenoPath, privacy: .public)"
            )
        } catch {
            let reason = Self.reason(for: error)
            Log.transcription.error("model preparation failed: \(reason, privacy: .public)")
            state = .failed(reason)
            throw error
        }
    }

    /// Warms the models if they are loaded and cold. Cheap when they are already warm.
    func warmUpIfNeeded() async {
        guard !isWarm, await asr.isLoaded else { return }
        state = .preparing(stage: .warming, progress: nil)
        do {
            try await asr.warmUp()
            isWarm = true
        } catch {
            Log.transcription.error(
                "model warm-up failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        refresh()
    }

    /// Maps FluidAudio's phases onto the stage the interface shows.
    private func report(_ update: DownloadProgress, downloading stage: Stage) {
        switch update.phase {
        case .listing:
            state = .preparing(stage: stage, progress: nil)
        case .downloading:
            state = .preparing(stage: stage, progress: update.fractionCompleted)
        case .compiling(let name):
            state = .preparing(stage: .compiling(name), progress: update.fractionCompleted)
        }
    }

    /// A sentence for the user out of whatever FluidAudio threw.
    ///
    /// The one failure worth naming is "no network", because it is the only one the
    /// user can do anything about and the only one that is expected: the download runs
    /// once, and after it Steno never needs the network again.
    static func reason(for error: any Error) -> String {
        let urlError = (error as? URLError) ?? (error as NSError).underlyingURLError
        if let urlError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return String(localized: "Keine Verbindung zu Hugging Face. Der Download ist die einzige Netzverbindung, die Steno braucht.")
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Whether the "Modelle laden" button should be clickable.
    var canDownload: Bool { !state.isPreparing }

    /// Why it is not clickable, as help text.
    var downloadUnavailableReason: String {
        state.isPreparing
            ? String(localized: "Der Download läuft bereits.")
            : String(localized: "Lädt die Modelle einmalig von Hugging Face (rund 500 MB).")
    }

    // MARK: - Finder

    /// Creates the model directory if needed and shows it.
    func revealModelsDirectory() {
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelsDirectory])
    }

    /// A one-line status for the settings window and the onboarding row.
    var statusDescription: String {
        switch state {
        case .installed:
            return isWarm
                ? String(localized: "Modelle installiert und bereit")
                : String(localized: "Modelle installiert")
        case .preparing(let stage, let progress):
            guard let progress, progress > 0 else { return stage.localizedDescription }
            return String(
                format: String(localized: "%@ %d %%"),
                stage.localizedDescription,
                Int((progress * 100).rounded())
            )
        case .failed(let reason):
            return reason
        case .idle:
            if isASRInstalled != isDiarizerInstalled {
                return String(localized: "Modelle unvollständig")
            }
            return String(localized: "Modelle fehlen — rund 500 MB, einmalig")
        }
    }
}

private extension NSError {
    /// The `URLError` hiding under a wrapped download failure, if there is one.
    var underlyingURLError: URLError? {
        if let direct = self as? URLError { return direct }
        if let underlying = userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying as? URLError ?? underlying.underlyingURLError
        }
        return nil
    }
}
