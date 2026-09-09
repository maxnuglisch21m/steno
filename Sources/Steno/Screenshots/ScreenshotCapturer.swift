import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import StenoCore

// ScreenCaptureKit's objects are thread-safe ObjC classes with no Swift concurrency
// annotations, so the compiler has to be told once, here, rather than at every call
// site. Steno keeps every one of them on the main actor and only ever hands them to
// ScreenCaptureKit's own async methods; the sample buffers, which are genuinely
// per-thread, are not covered by any of this and never leave the capture queue.
extension SCShareableContent: @unchecked @retroactive Sendable {}
extension SCDisplay: @unchecked @retroactive Sendable {}
extension SCWindow: @unchecked @retroactive Sendable {}
extension SCRunningApplication: @unchecked @retroactive Sendable {}
extension SCContentFilter: @unchecked @retroactive Sendable {}
extension SCStreamConfiguration: @unchecked @retroactive Sendable {}
extension SCStream: @unchecked @retroactive Sendable {}

/// Captures every display for the length of a recording. Specification §4.
///
/// One `SCStream` per display at 1 fps. ScreenCaptureKit reports a frame status of
/// `.idle` for a display that did not change, which is what replaces comparing images
/// ourselves; the frames that are left go through `StenoCore.ScreenshotGate`, which
/// decides on elapsed time and changed area whether one becomes a file.
///
/// Nothing here is allowed to fail a recording. A missing permission, a display that
/// refuses to start, a full disk — all of them end in a log line and a meeting that
/// still has its audio.
@MainActor
final class ScreenshotCapturer {
    /// How often the anchor timer looks for a display that is overdue.
    ///
    /// Anchors cannot come from the streams alone: a display that never changes gets
    /// nothing but `.idle` frames, and the specification (§4.6) asks for one image per
    /// display at the start and every 120 s after it — precisely for that display. So
    /// an overdue display is captured out of band with `SCScreenshotManager`, and the
    /// gate is what stops the two paths from both saving the same moment.
    static let anchorTick: Duration = .seconds(5)

    /// How long a stopped stream is left alone before it is started again.
    static let restartDelay: Duration = .seconds(2)

    /// How often the content filters are rebuilt, so that a Steno window opened
    /// mid-meeting stops appearing in the screenshots. Cheap: one `SCShareableContent`
    /// fetch and one `updateContentFilter` per display.
    static let filterRefreshInterval: Duration = .seconds(10)

    /// One display being captured.
    private struct DisplayStream {
        var display: SCDisplay
        var stream: SCStream
        var output: ScreenshotStreamOutput
        var configuration: SCStreamConfiguration
        var filter: SCContentFilter
        /// Whether the single restart after an error has already been used.
        var hasBeenRestarted = false
    }

    private let queue = DispatchQueue(
        label: "de.21m.steno.screenshots",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let tracker = ActiveDisplayTracker()

    private var streams: [CGDirectDisplayID: DisplayStream] = [:]
    private var sink: ScreenshotFrameSink?
    /// `meta.displays`, in the order the file names use. Never renumbered: a display
    /// unplugged mid-meeting keeps its index, and a new one is appended.
    private(set) var displays: [DisplayInfo] = []
    private var ownWindows: [SCWindow] = []

    private var anchorTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    /// Set while a filter rebuild is in flight. Opening a window fires several
    /// notifications in a row, and each one would otherwise fetch the whole shareable
    /// content again.
    private var isRefreshingFilters = false
    private var observers: [any NSObjectProtocol] = []
    private var isRunning = false

    init() {}

    // MARK: - Starting

    /// Starts capturing every display. Returns what belongs in `meta.displays`, which
    /// is empty when nothing could be captured.
    ///
    /// - Parameters:
    ///   - folder: the meeting folder. `screens/` and `screens.jsonl` go inside it.
    ///   - started: `meta.started`; `t` in the index is measured from it.
    @discardableResult
    func start(
        folder: URL,
        started: Date,
        configuration: ScreenshotCaptureConfiguration,
        isScreenLocked: Bool = false
    ) async -> [DisplayInfo] {
        guard !isRunning else { return displays }

        // The test bundle is hosted by the app, and `RecordingCoordinator` is driven
        // end to end by its tests. Photographing the screen of whoever runs `make test`
        // is not something a test may do, whatever the permission says.
        guard !RunningEnvironment.isUnitTesting else { return [] }

        // Asking ScreenCaptureKit for its content is what makes macOS show the Screen
        // Recording prompt, so the preflight comes first: a recording must never stop
        // to ask a question the onboarding window is there to ask.
        guard CGPreflightScreenCaptureAccess() else {
            Log.screens.notice("screen recording is not granted; this recording gets no screenshots")
            return []
        }

        isRunning = true
        // A second recording is a second set of displays: keeping the first one's
        // would put a monitor in `meta.displays` that nothing is capturing.
        displays = []
        streams = [:]
        ownWindows = []
        tracker.refresh()

        let sink = ScreenshotFrameSink(
            folder: folder,
            started: started,
            configuration: configuration,
            tracker: tracker
        )
        sink.setPaused(isScreenLocked)
        self.sink = sink

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            Log.screens.error(
                "screenshotsError: shareable content unavailable: \(error.localizedDescription, privacy: .public)"
            )
            isRunning = false
            self.sink = nil
            return []
        }

        // `CGPreflightScreenCaptureAccess` can answer yes on the strength of the
        // responsible process's grant — a build launched from a terminal that has the
        // permission, for instance — while the window server still hands out nothing.
        // An empty display list is what that looks like, and it is a state to report
        // plainly rather than an error to retry.
        guard !content.displays.isEmpty else {
            Log.screens.notice(
                "ScreenCaptureKit offered no display; this recording gets no screenshots"
            )
            isRunning = false
            self.sink = nil
            return []
        }

        ownWindows = Self.ownWindows(in: content)
        for display in content.displays {
            let info = registerDisplay(display)
            await startStream(for: display, info: info, configuration: configuration)
        }

        guard !displays.isEmpty else {
            Log.screens.error("screenshotsError: no display could be captured")
            isRunning = false
            return []
        }

        observeScreenChanges()
        startAnchorTimer()
        startFilterRefresh()

        Log.screens.notice(
            """
            screenshots started for \(self.displays.count, privacy: .public) display(s), \
            longer edge ≤ \(configuration.maxEdge, privacy: .public) px
            """
        )
        return displays
    }

    /// Adds a display to `meta.displays` if it is not there yet, and answers with its
    /// entry either way.
    private func registerDisplay(_ display: SCDisplay) -> DisplayInfo {
        if let existing = displays.first(where: { $0.id == display.displayID }) {
            sink?.register(displayID: display.displayID, index: existing.index)
            return existing
        }
        let size = Self.pixelSize(of: display)
        let info = DisplayInfo(
            index: displays.count,
            id: display.displayID,
            width: size.width,
            height: size.height
        )
        displays.append(info)
        sink?.register(displayID: display.displayID, index: info.index)
        return info
    }

    private func startStream(
        for display: SCDisplay,
        info: DisplayInfo,
        configuration: ScreenshotCaptureConfiguration
    ) async {
        guard let sink else { return }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let streamConfiguration = Self.streamConfiguration(for: info, maxEdge: configuration.maxEdge)
        let output = ScreenshotStreamOutput(
            displayID: display.displayID,
            sink: sink,
            onStopped: { [weak self] displayID, error in
                Task { @MainActor [weak self] in
                    self?.handleStreamStopped(displayID: displayID, error: error)
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
        do {
            // One shared serial queue for every display: all per-frame work is then
            // ordered, off the main actor, and needs no lock of its own.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            Log.screens.error(
                """
                screenshotsError: display \(info.index, privacy: .public) would not start: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return
        }
        streams[display.displayID] = DisplayStream(
            display: display,
            stream: stream,
            output: output,
            configuration: streamConfiguration,
            filter: filter
        )
        Log.screens.info(
            """
            display \(info.index, privacy: .public) capturing at \
            \(streamConfiguration.width, privacy: .public)×\(streamConfiguration.height, privacy: .public) px \
            of \(info.px.first ?? 0, privacy: .public)×\(info.px.last ?? 0, privacy: .public)
            """
        )
    }

    // MARK: - Stopping

    /// Stops every stream and answers with the number of images written, which is
    /// `meta.screenshots`.
    @discardableResult
    func stop() async -> Int {
        guard isRunning, let sink else { return sink?.counters.saved ?? 0 }
        isRunning = false
        sink.markStopped()

        anchorTask?.cancel()
        anchorTask = nil
        filterTask?.cancel()
        filterTask = nil
        removeObservers()

        for (displayID, entry) in streams {
            do {
                try await entry.stream.stopCapture()
            } catch {
                Log.screens.info(
                    """
                    display \(displayID, privacy: .public) was already stopped: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        streams.removeAll()

        // Everything already queued still belongs in the index: the barrier is what
        // makes the count returned here the count that is on disk.
        await withCheckedContinuation { continuation in
            queue.async {
                sink.close()
                continuation.resume()
            }
        }

        let counters = sink.counters
        self.sink = nil
        Log.screens.notice(
            """
            screenshots finished: \(counters.saved, privacy: .public) saved \
            (\(counters.bytes / 1024, privacy: .public) KB), \
            \(counters.skipped, privacy: .public) below threshold, \
            \(counters.discarded, privacy: .public) discarded
            """
        )
        return counters.saved
    }

    /// Releases the streams on the way out of the process, without waiting on them.
    ///
    /// `applicationWillTerminate` is the last moment there is and an `await` would
    /// return to a run loop that never runs again, so the file is closed synchronously
    /// — that is the part that has to be right — and the streams are simply let go.
    func prepareForTermination() {
        guard isRunning, let sink else { return }
        isRunning = false
        sink.markStopped()
        anchorTask?.cancel()
        filterTask?.cancel()
        removeObservers()
        let stopping = streams.values.map(\.stream)
        streams.removeAll()
        queue.sync { sink.close() }
        self.sink = nil
        Task.detached {
            for stream in stopping { try? await stream.stopCapture() }
        }
    }

    // MARK: - The lock screen

    /// While the screen is locked, frames are discarded. The streams keep running:
    /// a lock is usually a coffee break in the middle of a meeting, and tearing three
    /// streams down and back up for it would risk more than it saves.
    func setScreenLocked(_ isLocked: Bool) {
        sink?.setPaused(isLocked)
        guard isRunning else { return }
        Log.screens.info("screenshots \(isLocked ? "paused" : "resumed", privacy: .public) by the lock screen")
    }

    // MARK: - Anchors

    /// One image per display at the start and every `anchorInterval` after it,
    /// whatever changed (§4.6).
    private func startAnchorTimer() {
        anchorTask = Task { [weak self] in
            // Immediately, so every display has a frame at t ≈ 0 even when its content
            // never changes and its stream therefore never reports one.
            await self?.captureOverdueAnchors()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.anchorTick)
                guard !Task.isCancelled else { return }
                await self?.captureOverdueAnchors()
            }
        }
    }

    private func captureOverdueAnchors() async {
        guard isRunning, let sink else { return }
        let now = Date()
        for displayID in sink.displaysNeedingAnchor(now: now) {
            guard let entry = streams[displayID] else { continue }
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: entry.filter,
                    configuration: entry.configuration
                )
                let captured = SendableImage(image: image)
                queue.async { sink.handleAnchor(captured, displayID: displayID, at: Date()) }
            } catch {
                Log.screens.info(
                    """
                    anchor frame for display \(displayID, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    // MARK: - Own windows

    /// Steno's own windows — the suggestion panel, settings, onboarding — are excluded
    /// from every stream. A recorder that photographs its own popup mid-meeting is
    /// both useless and a small privacy leak, and the panel is on screen exactly when
    /// something interesting is happening.
    private static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let bundleId = Bundle.main.bundleIdentifier
        return content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleId }
    }

    /// Rebuilds the filters every ten seconds and whenever one of Steno's own windows
    /// appears or goes away, so a window opened mid-meeting is excluded from the next
    /// frame rather than from the next recording.
    private func startFilterRefresh() {
        filterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.filterRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshContentFilters()
            }
        }
    }

    private func refreshContentFilters() async {
        guard isRunning, !isRefreshingFilters else { return }
        isRefreshingFilters = true
        defer { isRefreshingFilters = false }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        else { return }

        let windows = Self.ownWindows(in: content)
        let changed = windows.map(\.windowID).sorted() != ownWindows.map(\.windowID).sorted()
        ownWindows = windows

        // A newly attached display shows up here too, and a detached one disappears.
        await reconcileDisplays(content.displays)
        guard changed else { return }

        for displayID in Array(streams.keys) {
            guard var entry = streams[displayID] else { continue }
            let filter = SCContentFilter(display: entry.display, excludingWindows: windows)
            entry.filter = filter
            streams[displayID] = entry
            do {
                try await entry.stream.updateContentFilter(filter)
            } catch {
                Log.screens.info(
                    """
                    display \(displayID, privacy: .public) refused a filter update: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        Log.screens.debug("content filters rebuilt around \(windows.count, privacy: .public) own window(s)")
    }

    // MARK: - Hot-plug

    private func observeScreenChanges() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tracker.refresh()
                    Task { await self.handleScreenParametersChanged() }
                }
            }
        )
        // Steno's own windows opening and closing is the other reason a filter goes
        // stale, and it is worth reacting to immediately rather than within ten
        // seconds: the suggestion panel is on screen for twenty.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        Task { await self.refreshContentFilters() }
                    }
                }
            )
        }
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleScreenParametersChanged() async {
        guard isRunning else { return }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        else { return }
        ownWindows = Self.ownWindows(in: content)
        await reconcileDisplays(content.displays)
    }

    /// Starts streams for displays that appeared and stops the ones that went away.
    ///
    /// Indices are never renumbered. `screens.jsonl` and the file names already point
    /// at them, and a reader that saw `d1` mean one monitor for the first half of a
    /// meeting and another for the second half would have no way of telling.
    private func reconcileDisplays(_ current: [SCDisplay]) async {
        guard isRunning, let sink else { return }
        let currentIDs = Set(current.map(\.displayID))

        // A snapshot of the keys: the loop removes from the dictionary it walks.
        for displayID in Array(streams.keys) where !currentIDs.contains(displayID) {
            if let entry = streams.removeValue(forKey: displayID) {
                try? await entry.stream.stopCapture()
            }
            sink.forget(displayID: displayID)
            Log.screens.notice("display \(displayID, privacy: .public) went away mid-recording")
        }

        for display in current where streams[display.displayID] == nil {
            let info = registerDisplay(display)
            await startStream(
                for: display,
                info: info,
                configuration: sink.configuration
            )
            Log.screens.notice(
                "display \(display.displayID, privacy: .public) joined as index \(info.index, privacy: .public)"
            )
        }
    }

    // MARK: - Errors

    /// A stream that stopped on its own gets one restart, two seconds later. If that
    /// does not take, the recording carries on without that display: screenshots are
    /// not what makes a meeting recoverable, the audio is.
    private func handleStreamStopped(displayID: CGDirectDisplayID, error: any Error) {
        guard isRunning, var entry = streams[displayID] else { return }
        Log.screens.error(
            """
            screenshotsError: display \(displayID, privacy: .public) stopped: \
            \(error.localizedDescription, privacy: .public)
            """
        )
        guard !entry.hasBeenRestarted else {
            streams.removeValue(forKey: displayID)
            Log.screens.error(
                "screenshotsError: display \(displayID, privacy: .public) stays down; the recording continues"
            )
            return
        }
        entry.hasBeenRestarted = true
        streams[displayID] = entry

        Task { [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard let self, self.isRunning, let entry = self.streams[displayID] else { return }
            do {
                try await entry.stream.startCapture()
                Log.screens.notice("display \(displayID, privacy: .public) restarted")
            } catch {
                self.streams.removeValue(forKey: displayID)
                Log.screens.error(
                    """
                    screenshotsError: display \(displayID, privacy: .public) would not restart: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    // MARK: - Geometry

    /// A display's size in pixels.
    ///
    /// `SCDisplay.width/height` are **points**, so a Retina display would be recorded
    /// in `meta.displays` at half its real resolution. The current display mode knows
    /// both, and the ratio between them is the backing scale — read from Core Graphics
    /// rather than from `NSScreen`, so this works from anywhere and does not depend on
    /// AppKit having caught up with a display that was just plugged in.
    nonisolated static func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        let points = (width: display.width, height: display.height)
        guard
            let mode = CGDisplayCopyDisplayMode(display.displayID),
            mode.width > 0, mode.height > 0
        else { return (points.width, points.height) }

        let scaleX = Double(mode.pixelWidth) / Double(mode.width)
        let scaleY = Double(mode.pixelHeight) / Double(mode.height)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            return (points.width, points.height)
        }
        return (
            Int((Double(points.width) * scaleX).rounded()),
            Int((Double(points.height) * scaleY).rounded())
        )
    }

    /// The capture size for a display: the longer edge at most `maxEdge`, aspect ratio
    /// kept, and never upscaled — a 1280 × 800 display is captured at 1280 × 800.
    nonisolated static func captureSize(pixelWidth: Int, pixelHeight: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let width = max(1, pixelWidth)
        let height = max(1, pixelHeight)
        let edge = max(width, height)
        let limit = max(320, maxEdge)
        guard edge > limit else { return (width, height) }
        let scale = Double(limit) / Double(edge)
        return (
            max(2, Int((Double(width) * scale).rounded())),
            max(2, Int((Double(height) * scale).rounded()))
        )
    }

    /// Specification §4.3, plus the pixel format and colour space that make the JPEG
    /// come out looking like the screen did.
    nonisolated static func streamConfiguration(for info: DisplayInfo, maxEdge: Int) -> SCStreamConfiguration {
        let size = captureSize(
            pixelWidth: info.width ?? 1920,
            pixelHeight: info.height ?? 1080,
            maxEdge: maxEdge
        )
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        // One frame a second. Anything faster would be thrown away by the gate, and
        // the point of the design is to do as little work per second as possible.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        // The pointer is part of what a screenshot of a meeting is for: it says where
        // the attention was.
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }
}

/// The per-display stream callback: frames onto the capture queue, errors onto the
/// main actor.
///
/// `@unchecked Sendable` because ScreenCaptureKit calls it from its own threads; every
/// stored property is a `let`, and the one mutable thing it touches — the sink — does
/// its own synchronization.
private final class ScreenshotStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private let sink: ScreenshotFrameSink
    private let onStopped: @Sendable (CGDirectDisplayID, any Error) -> Void

    init(
        displayID: CGDirectDisplayID,
        sink: ScreenshotFrameSink,
        onStopped: @escaping @Sendable (CGDirectDisplayID, any Error) -> Void
    ) {
        self.displayID = displayID
        self.sink = sink
        self.onStopped = onStopped
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        sink.handle(sampleBuffer: sampleBuffer, displayID: displayID)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStopped(displayID, error)
    }
}
