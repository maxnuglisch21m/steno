import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import StenoCore
import Synchronization

/// Everything a saved frame is written with, read once when a recording starts.
///
/// A snapshot rather than a live reference to `SettingsStore`: the thresholds must not
/// change halfway through a meeting, or `screens.jsonl` would describe two different
/// recordings in one file.
struct ScreenshotCaptureConfiguration: Sendable {
    var gate: ScreenshotGateConfig
    /// Longer edge of a saved image, in pixels.
    var maxEdge: Int
    /// JPEG quality, 0…1.
    var jpegQuality: Double
    /// Whether every gate decision is logged. `--screenshot-log`, debug builds only.
    var logsDecisions: Bool

    init(gate: ScreenshotGateConfig, maxEdge: Int, jpegQuality: Double, logsDecisions: Bool = false) {
        self.gate = gate
        self.maxEdge = maxEdge
        self.jpegQuality = jpegQuality
        self.logsDecisions = logsDecisions
    }

    init(settings: StenoSettings, logsDecisions: Bool = false) {
        self.init(
            gate: settings.screenshotGateConfig,
            maxEdge: settings.screenshotMaxEdge,
            jpegQuality: settings.jpegQuality,
            logsDecisions: logsDecisions
        )
    }
}

/// A `CGImage` handed from one queue to another.
///
/// `CGImage` is immutable once created and safe to read from any thread; the compiler
/// has no way of knowing that about an imported CoreFoundation type, so it is said
/// here, once, instead of at every call site.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// Decides which captured frames become files, and writes them.
///
/// **Threading.** Every stream delivers its frames to one shared serial queue, so all
/// per-frame work — reading the attachments, deciding, encoding, writing the file,
/// appending to `screens.jsonl` — happens on that queue, in order, and never on the
/// main actor. The two pieces of state the main actor also needs (the gate's
/// per-display timestamps, so the anchor timer can tell what is overdue, and the
/// counters, so `meta.screenshots` can be written at the stop) live behind a mutex;
/// the file handle, the Core Image context, and the directory-created flag are touched
/// only from the queue and need no lock at all.
///
/// The mutex is never held across a file write. Encoding a 1920-px JPEG takes tens of
/// milliseconds and the anchor timer runs on the main actor — holding the lock over
/// that would put a visible hitch in the menu bar once a frame.
final class ScreenshotFrameSink: @unchecked Sendable {
    struct Counters: Sendable, Equatable {
        /// Images written, i.e. lines in `screens.jsonl`. This is `meta.screenshots`.
        var saved = 0
        /// Total bytes of JPEG written, for the debug report.
        var bytes = 0
        /// Candidate frames the gate turned down.
        var skipped = 0
        /// Frames discarded before the gate: not `.complete`, or the screen was locked.
        var discarded = 0
    }

    /// The state both the queue and the main actor read.
    private struct Shared {
        var gate: ScreenshotGate
        var namer: ScreensFileNamer
        /// `meta.displays[].index` for each display being captured.
        var displayIndexes: [CGDirectDisplayID: Int] = [:]
        var counters = Counters()
        /// While the screen is locked, frames are discarded — the streams keep running.
        var isPaused = false
        /// Set once the capture is being torn down, so a frame in flight is dropped.
        var isStopped = false
    }

    let folder: URL
    /// `meta.started`. `t` in the index is measured from here, and so is the clock in
    /// every file name — which is why the sink has to be told when the recording began
    /// rather than reading a wall clock of its own.
    let started: Date
    let configuration: ScreenshotCaptureConfiguration

    private let tracker: ActiveDisplayTracker
    private let shared: Mutex<Shared>

    // Queue-confined. Only `handle(sampleBuffer:displayID:)` and `save(...)` touch
    // these, and both run on the capture queue.
    private let index: ScreensIndexWriter
    private let context: CIContext
    private var screensDirectoryReady = false
    private var hasReportedWriteFailure = false

    init(
        folder: URL,
        started: Date,
        configuration: ScreenshotCaptureConfiguration,
        tracker: ActiveDisplayTracker,
        timeZone: TimeZone = .current
    ) {
        self.folder = folder
        self.started = started
        self.configuration = configuration
        self.tracker = tracker
        self.index = ScreensIndexWriter(folder: folder, timeZone: timeZone)
        self.context = JPEGWriter.makeContext()
        self.shared = Mutex(
            Shared(
                gate: ScreenshotGate(config: configuration.gate),
                namer: ScreensFileNamer()
            )
        )
    }

    // MARK: - Displays

    /// Tells the sink which `meta.displays` index a display writes under.
    func register(displayID: CGDirectDisplayID, index displayIndex: Int) {
        shared.withLock { $0.displayIndexes[displayID] = displayIndex }
    }

    /// Forgets a display that was unplugged, so one plugged back in gets a fresh
    /// anchor frame rather than being measured against a stale timestamp.
    func forget(displayID: CGDirectDisplayID) {
        shared.withLock { state in
            state.gate.forget(displayID: displayID)
            if let displayIndex = state.displayIndexes.removeValue(forKey: displayID) {
                state.namer.forget(display: displayIndex)
            }
        }
    }

    // MARK: - State

    /// While the screen is locked, frames are discarded rather than the streams
    /// stopped: two hundred images of the lock wallpaper are two hundred images of
    /// nothing, and tearing the streams down and back up at every lock would be a much
    /// bigger change than the one being avoided.
    func setPaused(_ isPaused: Bool) {
        shared.withLock { $0.isPaused = isPaused }
    }

    func markStopped() {
        shared.withLock { $0.isStopped = true }
    }

    var counters: Counters { shared.withLock { $0.counters } }

    /// The displays whose anchor is due — never captured, or last captured longer than
    /// the anchor interval ago. Read by the anchor timer on the main actor.
    func displaysNeedingAnchor(now: Date) -> [CGDirectDisplayID] {
        shared.withLock { state in
            guard !state.isPaused, !state.isStopped else { return [] }
            return state.displayIndexes.keys.filter { displayID in
                guard let last = state.gate.lastSavedAt[displayID] else { return true }
                return now.timeIntervalSince(last) >= state.gate.config.anchorInterval
            }
        }
    }

    /// Closes `screens.jsonl`. Must run on the capture queue, after the streams have
    /// stopped.
    func close() {
        index.close()
    }

    // MARK: - Frames

    /// One frame from one display's stream. Runs on the capture queue.
    func handle(sampleBuffer: CMSampleBuffer, displayID: CGDirectDisplayID) {
        guard let attachment = Self.frameInfo(of: sampleBuffer) else { return }

        // §4.4: only a complete frame is a candidate. `.idle` is ScreenCaptureKit
        // saying the display did not change, which is exactly the image comparison
        // this design exists to avoid doing itself.
        //
        // `.started` is accepted alongside it: it is the first frame after a stream
        // starts and carries a full image, and refusing it would mean a display whose
        // content never changes has no frame at all until the anchor timer fires.
        guard let status = Self.status(of: attachment), status == .complete || status == .started else {
            note { $0.discarded += 1 }
            return
        }

        let frameSize = Self.frameSize(of: attachment, sampleBuffer: sampleBuffer)
        let changed = DirtyRectMath.changedFraction(
            rects: Self.dirtyRects(of: attachment),
            frameSize: frameSize
        )

        // Wall clock at the moment the frame is handled, not the sample buffer's
        // presentation time. The two differ by the queue's own latency — single-digit
        // milliseconds at 1 fps with one frame of work per tick — and `t` is measured
        // against `meta.started`, which is a `Date` too. Mapping a mach timebase onto
        // a wall clock to save those milliseconds would cost more than it buys.
        let now = Date()
        let isActive = tracker.isActive(displayID)

        guard let reservation = reserve(
            displayID: displayID,
            isActive: isActive,
            changed: changed,
            now: now
        ) else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            // A complete frame with no surface behind it. Nothing to write; the
            // reservation has already moved the gate on, which only delays the next
            // frame of this display by one interval.
            note { $0.discarded += 1 }
            return
        }

        do {
            let image = try JPEGWriter.image(from: pixelBuffer, context: context)
            save(
                image: image,
                reservation: reservation,
                displayID: displayID,
                isActive: isActive,
                changed: changed,
                now: now
            )
        } catch {
            reportWriteFailure(error)
        }
    }

    /// Writes an image the anchor timer captured out of band. Runs on the capture
    /// queue, dispatched there by `ScreenshotCapturer`.
    func handleAnchor(_ image: SendableImage, displayID: CGDirectDisplayID, at now: Date) {
        let isActive = tracker.isActive(displayID)
        // The anchor is unconditional by definition (§4.6), so the gate is asked with
        // a change of 0: what it decides on is the elapsed time, and a display that
        // has just been saved by its own stream is correctly turned down here.
        guard let reservation = reserve(
            displayID: displayID,
            isActive: isActive,
            changed: 0,
            now: now
        ) else { return }
        save(
            image: image.image,
            reservation: reservation,
            displayID: displayID,
            isActive: isActive,
            changed: 0,
            now: now
        )
    }

    // MARK: - Deciding

    /// What a frame that is being kept has been promised.
    private struct Reservation {
        var fileName: String
        var displayIndex: Int
        var reason: ScreenshotSaveReason
        var t: TimeInterval
    }

    /// Asks the gate and, when the answer is to save, reserves the file name — both
    /// under one lock, so two frames can never be promised the same name.
    private func reserve(
        displayID: CGDirectDisplayID,
        isActive: Bool,
        changed: Double,
        now: Date
    ) -> Reservation? {
        let outcome: (reservation: Reservation?, isPaused: Bool, isStopped: Bool) = shared.withLock { state in
            guard !state.isPaused, !state.isStopped else {
                return (nil, state.isPaused, state.isStopped)
            }
            guard let displayIndex = state.displayIndexes[displayID] else { return (nil, false, false) }

            let decision = state.gate.decide(
                displayID: displayID,
                isActive: isActive,
                changedPct: changed,
                now: now
            )
            guard let reason = decision.reason else { return (nil, false, false) }

            // The name is the offset as a clock, so it is derived from the same `t`
            // the index line carries — one number, formatted two ways.
            let t = now.timeIntervalSince(started)
            let fileName = state.namer.nextFileName(
                elapsed: t,
                display: displayIndex,
                active: isActive
            )
            return (
                Reservation(
                    fileName: fileName,
                    displayIndex: displayIndex,
                    reason: reason,
                    t: t
                ),
                false,
                false
            )
        }

        if outcome.isPaused || outcome.isStopped {
            note { $0.discarded += 1 }
            return nil
        }
        if outcome.reservation == nil {
            note { $0.skipped += 1 }
        }
        logDecision(
            displayID: displayID,
            isActive: isActive,
            changed: changed,
            reason: outcome.reservation?.reason,
            fileName: outcome.reservation?.fileName
        )
        return outcome.reservation
    }

    // MARK: - Writing

    private func save(
        image: CGImage,
        reservation: Reservation,
        displayID: CGDirectDisplayID,
        isActive: Bool,
        changed: Double,
        now: Date
    ) {
        do {
            let directory = try screensDirectory()
            let url = directory.appendingPathComponent(reservation.fileName)
            let bytes = try JPEGWriter.write(image, to: url, quality: configuration.jpegQuality)
            index.append(
                ScreensIndexEntry(
                    t: reservation.t,
                    at: now,
                    fileName: reservation.fileName,
                    display: reservation.displayIndex,
                    active: isActive,
                    changed: changed
                )
            )
            note {
                $0.saved += 1
                $0.bytes += bytes
            }
        } catch {
            reportWriteFailure(error)
        }
    }

    /// `screens/`, created on the first save rather than at the start: a recording
    /// that never manages a single frame should not leave an empty directory behind.
    private func screensDirectory() throws -> URL {
        let directory = folder.appendingPathComponent(ScreensIndexEntry.directoryName, isDirectory: true)
        if !screensDirectoryReady {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            screensDirectoryReady = true
        }
        return directory
    }

    private func reportWriteFailure(_ error: any Error) {
        guard !hasReportedWriteFailure else { return }
        hasReportedWriteFailure = true
        // Screenshots are not fatal to a recording: the audio is the recording, and a
        // meeting with no images is worth more than no meeting at all.
        Log.screens.error(
            "screenshotsError: a frame could not be written: \(error.localizedDescription, privacy: .public)"
        )
    }

    private func note(_ mutate: (inout Counters) -> Void) {
        shared.withLock { mutate(&$0.counters) }
    }

    private func logDecision(
        displayID: CGDirectDisplayID,
        isActive: Bool,
        changed: Double,
        reason: ScreenshotSaveReason?,
        fileName: String?
    ) {
        guard configuration.logsDecisions else { return }
        let decision = reason.map { fileName == nil ? $0.rawValue : "\($0.rawValue) → \(fileName ?? "")" } ?? "skip"
        Log.screens.notice(
            """
            gate: display=\(displayID, privacy: .public) \
            active=\(isActive, privacy: .public) \
            changed=\(String(format: "%.4f", changed), privacy: .public) \
            \(decision, privacy: .public)
            """
        )
    }

    // MARK: - Reading the attachments

    /// The `SCStreamFrameInfo` dictionary ScreenCaptureKit attaches to every frame.
    private static func frameInfo(of sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
        else { return nil }
        return attachments.first
    }

    private static func status(of attachment: [SCStreamFrameInfo: Any]) -> SCFrameStatus? {
        guard let raw = attachment[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// The dirty rectangles, in whatever coordinate space `contentRect` uses.
    ///
    /// Only their ratio to the frame matters, so points and pixels give the same
    /// answer as long as both come from the same attachment — which is why
    /// `frameSize(of:sampleBuffer:)` prefers `contentRect` over the pixel buffer.
    private static func dirtyRects(of attachment: [SCStreamFrameInfo: Any]) -> [PixelRect] {
        guard let raw = attachment[.dirtyRects] as? [Any] else { return [] }
        return raw.compactMap { element in
            guard
                let dictionary = element as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            else { return nil }
            return PixelRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        }
    }

    /// The area the dirty rects are measured against: the captured content, not the
    /// surface. A surface can be larger than the content it holds, and dividing by it
    /// would report less change than there was.
    private static func frameSize(
        of attachment: [SCStreamFrameInfo: Any],
        sampleBuffer: CMSampleBuffer
    ) -> PixelSize {
        if
            let dictionary = attachment[.contentRect] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
            rect.width > 0, rect.height > 0
        {
            return PixelSize(width: rect.width, height: rect.height)
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return PixelSize(width: 0, height: 0)
        }
        return PixelSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }
}
