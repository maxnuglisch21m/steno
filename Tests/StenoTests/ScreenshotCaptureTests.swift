import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import StenoCore
import Testing
import UniformTypeIdentifiers

@testable import Steno

/// M4's app-side pieces: the JPEG writer, the capture geometry, the settings the gate
/// runs on, and the frame sink's save path driven through its anchor entry point.
///
/// The gate's own thresholds are `StenoCore`'s and are tested there against a clock;
/// what is checked here is the shell around it — that a decision becomes a file with
/// the right name, an index line with the right `t`, and a count that matches.
@Suite("Screenshots")
struct ScreenshotCaptureTests {
    // MARK: - Helpers

    /// A solid-colour image of a given size, which is all the JPEG path needs.
    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A second rectangle, so the JPEG has something to compress and is not a
        // degenerate one-colour file.
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    static func makeFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-screens-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - JPEGWriter

    @Test("writes a JPEG that reads back at the same pixel size")
    func jpegRoundTrip() throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("143012_d0.jpg")
        let bytes = try JPEGWriter.write(Self.makeImage(width: 640, height: 400), to: url, quality: 0.8)
        #expect(bytes > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 400)

        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 640)
        #expect(decoded.height == 400)
    }

    @Test("a lower quality makes a smaller file")
    func jpegQualityMatters() throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = Self.makeImage(width: 800, height: 600)

        let high = try JPEGWriter.write(image, to: folder.appendingPathComponent("h.jpg"), quality: 0.95)
        let low = try JPEGWriter.write(image, to: folder.appendingPathComponent("l.jpg"), quality: 0.2)
        #expect(low < high)
    }

    @Test(
        "the quality is kept inside what ImageIO accepts",
        arguments: [(0.8, 0.8), (0.0, 0.1), (-1.0, 0.1), (2.0, 1.0), (Double.nan, 0.8)]
    )
    func qualityClamping(given: Double, expected: Double) {
        #expect(JPEGWriter.clampedQuality(given) == expected)
    }

    // MARK: - Geometry

    @Test(
        "the longer edge is capped and the aspect ratio kept",
        arguments: [
            // 4K landscape → 1920 wide.
            (3840, 2160, 1920, 1920, 1080),
            // 1440p landscape.
            (2560, 1440, 1920, 1920, 1080),
            // Already smaller than the cap: untouched, never upscaled.
            (1280, 800, 1920, 1280, 800),
            // Portrait: the height is the longer edge.
            (1080, 1920, 1920, 1080, 1920),
            (1600, 2560, 1920, 1200, 1920),
            // A tighter cap from the settings.
            (3840, 2160, 1280, 1280, 720)
        ]
    )
    func captureSize(
        pixelWidth: Int,
        pixelHeight: Int,
        maxEdge: Int,
        expectedWidth: Int,
        expectedHeight: Int
    ) {
        let size = ScreenshotCapturer.captureSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            maxEdge: maxEdge
        )
        #expect(size.width == expectedWidth)
        #expect(size.height == expectedHeight)
    }

    @Test("a nonsensical size still produces a usable one")
    func captureSizeDegenerate() {
        let size = ScreenshotCapturer.captureSize(pixelWidth: 0, pixelHeight: -10, maxEdge: 1920)
        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }

    @Test("the stream configuration is the one the specification asks for")
    func streamConfiguration() {
        let info = DisplayInfo(index: 0, id: 1, width: 3840, height: 2160)
        let configuration = ScreenshotCapturer.streamConfiguration(for: info, maxEdge: 1920)
        #expect(configuration.width == 1920)
        #expect(configuration.height == 1080)
        #expect(configuration.minimumFrameInterval.value == 1)
        #expect(configuration.minimumFrameInterval.timescale == 1)
        #expect(configuration.queueDepth == 3)
        #expect(configuration.showsCursor)
        #expect(!configuration.capturesAudio)
        #expect(configuration.pixelFormat == kCVPixelFormatType_32BGRA)
    }

    // MARK: - Settings → gate

    @Test("the capture configuration comes from the settings, anchor interval included")
    @MainActor
    func configurationFromSettings() {
        var settings = StenoSettings.default
        settings.screenshotNormalMinInterval = 7
        settings.screenshotActiveMinInterval = 3
        settings.screenshotNormalMinChange = 0.05
        settings.screenshotActiveMinChange = 0.01
        settings.anchorInterval = 90
        settings.screenshotMaxEdge = 1280
        settings.jpegQuality = 0.6

        let configuration = ScreenshotCaptureConfiguration(settings: settings)
        #expect(configuration.gate.normalMinInterval == 7)
        #expect(configuration.gate.activeMinInterval == 3)
        #expect(configuration.gate.normalMinChange == 0.05)
        #expect(configuration.gate.activeMinChange == 0.01)
        // The one the specification's §4.6 anchor rule runs on, and the one M4 had to
        // wire through from the settings window.
        #expect(configuration.gate.anchorInterval == 90)
        #expect(configuration.maxEdge == 1280)
        #expect(configuration.jpegQuality == 0.6)
        #expect(!configuration.logsDecisions)
    }

    @Test("the defaults are the specification's thresholds")
    @MainActor
    func defaultThresholds() {
        let configuration = ScreenshotCaptureConfiguration(settings: .default)
        #expect(configuration.gate.normalMinInterval == 5)
        #expect(configuration.gate.activeMinInterval == 2)
        #expect(configuration.gate.normalMinChange == 0.02)
        #expect(configuration.gate.activeMinChange == 0.005)
        #expect(configuration.gate.anchorInterval == 120)
        #expect(configuration.maxEdge == 1920)
        #expect(configuration.jpegQuality == 0.8)
    }

    // MARK: - The index

    @Test("screens.jsonl is appended to line by line")
    func indexWriter() throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = ScreensIndexWriter(folder: folder)
        writer.append(
            ScreensIndexEntry(t: 0, fileName: "143012_d0.jpg", display: 0, active: false, changed: 0)
        )
        writer.append(
            ScreensIndexEntry(t: 5.5, fileName: "143017_d0.jpg", display: 0, active: true, changed: 0.44)
        )
        writer.close()

        #expect(writer.lineCount == 2)
        let text = try String(
            contentsOf: folder.appendingPathComponent(ScreensIndexWriter.fileName),
            encoding: .utf8
        )
        let entries = try ScreensIndexEntry.decode(jsonl: text)
        #expect(entries.count == 2)
        #expect(entries[0].file == "screens/143012_d0.jpg")
        #expect(entries[1].t == 5.5)
        #expect(entries[1].active)
    }

    // MARK: - The sink

    @MainActor
    private static func makeSink(
        folder: URL,
        started: Date,
        gate: ScreenshotGateConfig = .default,
        displays: [CGDirectDisplayID: Int] = [1: 0]
    ) -> ScreenshotFrameSink {
        let tracker = ActiveDisplayTracker()
        // No screens at all, so nothing is ever the active display: the mouse cannot
        // be on a screen the tracker does not know about.
        tracker.override([])
        let sink = ScreenshotFrameSink(
            folder: folder,
            started: started,
            configuration: ScreenshotCaptureConfiguration(gate: gate, maxEdge: 1920, jpegQuality: 0.8),
            tracker: tracker
        )
        for (displayID, index) in displays { sink.register(displayID: displayID, index: index) }
        return sink
    }

    @Test("an anchor frame becomes a file, an index line, and a count")
    @MainActor
    func anchorSave() throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let sink = Self.makeSink(folder: folder, started: started)

        sink.handleAnchor(
            SendableImage(image: Self.makeImage(width: 320, height: 200)),
            displayID: 1,
            at: started
        )
        sink.close()

        #expect(sink.counters.saved == 1)
        #expect(sink.counters.bytes > 0)

        let text = try String(
            contentsOf: folder.appendingPathComponent(ScreensIndexWriter.fileName),
            encoding: .utf8
        )
        let entries = try ScreensIndexEntry.decode(jsonl: text)
        #expect(entries.count == 1)
        #expect(entries[0].display == 0)
        #expect(!entries[0].active)
        #expect(entries[0].changed == 0)
        #expect(entries[0].t < 1)
        // The directory is created lazily, on the first save.
        let image = folder.appendingPathComponent(entries[0].file)
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test("a second anchor inside the anchor interval is turned down")
    @MainActor
    func anchorRespectsTheInterval() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let sink = Self.makeSink(folder: folder, started: started)
        let image = SendableImage(image: Self.makeImage(width: 160, height: 100))

        sink.handleAnchor(image, displayID: 1, at: started)
        sink.handleAnchor(image, displayID: 1, at: started.addingTimeInterval(30))
        sink.handleAnchor(image, displayID: 1, at: started.addingTimeInterval(119))
        // 120 s is the anchor interval, so this one is due.
        sink.handleAnchor(image, displayID: 1, at: started.addingTimeInterval(120))
        sink.close()

        #expect(sink.counters.saved == 2)
        #expect(sink.counters.skipped == 2)
    }

    @Test("a display the sink knows nothing about is ignored")
    @MainActor
    func unknownDisplay() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = Self.makeSink(folder: folder, started: Date())
        sink.handleAnchor(
            SendableImage(image: Self.makeImage(width: 80, height: 60)),
            displayID: 99,
            at: Date()
        )
        sink.close()
        #expect(sink.counters.saved == 0)
    }

    @Test("while the screen is locked nothing is written")
    @MainActor
    func lockedScreen() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let sink = Self.makeSink(folder: folder, started: started)
        let image = SendableImage(image: Self.makeImage(width: 160, height: 100))

        sink.setPaused(true)
        sink.handleAnchor(image, displayID: 1, at: started)
        #expect(sink.counters.saved == 0)
        #expect(sink.counters.discarded == 1)
        // Nothing is written, so not even the directory appears.
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(ScreensIndexEntry.directoryName).path
            )
        )

        sink.setPaused(false)
        sink.handleAnchor(image, displayID: 1, at: started.addingTimeInterval(1))
        sink.close()
        #expect(sink.counters.saved == 1)
    }

    @Test("after the stop nothing else is written")
    @MainActor
    func stoppedSink() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = Self.makeSink(folder: folder, started: Date())
        sink.markStopped()
        sink.handleAnchor(
            SendableImage(image: Self.makeImage(width: 80, height: 60)),
            displayID: 1,
            at: Date()
        )
        sink.close()
        #expect(sink.counters.saved == 0)
    }

    @Test("every display is overdue for an anchor before its first frame")
    @MainActor
    func anchorsDueAtStart() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let sink = Self.makeSink(folder: folder, started: started, displays: [1: 0, 2: 1])

        #expect(Set(sink.displaysNeedingAnchor(now: started)) == [1, 2])

        sink.handleAnchor(
            SendableImage(image: Self.makeImage(width: 80, height: 60)),
            displayID: 1,
            at: started
        )
        #expect(sink.displaysNeedingAnchor(now: started) == [2])
        // 120 s later display 1 is due again.
        #expect(Set(sink.displaysNeedingAnchor(now: started.addingTimeInterval(120))) == [1, 2])
        sink.close()
    }

    @Test("a display that was unplugged is forgotten")
    @MainActor
    func forgetsDisplay() {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        let sink = Self.makeSink(folder: folder, started: started, displays: [1: 0, 2: 1])
        sink.forget(displayID: 2)
        #expect(sink.displaysNeedingAnchor(now: started) == [1])
        sink.close()
    }

    @Test("two frames of one display in the same second get different names")
    @MainActor
    func sameSecondNames() throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        // A one-second anchor interval, so both frames are anchors.
        let sink = Self.makeSink(
            folder: folder,
            started: started,
            gate: ScreenshotGateConfig(anchorInterval: 0.2)
        )
        let image = SendableImage(image: Self.makeImage(width: 80, height: 60))
        sink.handleAnchor(image, displayID: 1, at: started)
        sink.handleAnchor(image, displayID: 1, at: started.addingTimeInterval(0.3))
        sink.close()

        let text = try String(
            contentsOf: folder.appendingPathComponent(ScreensIndexWriter.fileName),
            encoding: .utf8
        )
        let entries = try ScreensIndexEntry.decode(jsonl: text)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.file)).count == 2)
        for entry in entries {
            #expect(
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(entry.file).path
                ),
                "\(entry.file) is named in the index but is not on disk"
            )
        }
    }

    // MARK: - The active display

    @Test("the display holding the pointer is the active one")
    @MainActor
    func activeDisplay() {
        let tracker = ActiveDisplayTracker()
        tracker.override([])
        #expect(tracker.activeDisplayID() == nil)

        // A screen big enough to hold the pointer wherever it happens to be.
        tracker.override([
            ActiveDisplayTracker.Screen(
                displayID: 42,
                frame: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
            )
        ])
        #expect(tracker.activeDisplayID() == 42)
        #expect(tracker.isActive(42))
        #expect(!tracker.isActive(43))
    }

    @Test("a real refresh finds at least one screen")
    @MainActor
    func trackerRefresh() {
        let tracker = ActiveDisplayTracker()
        tracker.refresh()
        // A Mac running tests has a display, even a headless CI one.
        #expect(!tracker.knownScreens.isEmpty)
    }
}
