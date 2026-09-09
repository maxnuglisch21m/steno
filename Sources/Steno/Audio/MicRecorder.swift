import AVFoundation
import CoreAudio
import Foundation
import StenoCore

/// `onsite` capture: one microphone, one channel, no processing. Specification §3b.
///
/// The whole of the mode is `AVAudioEngine.inputNode` → a tap → `WAVWriter`, and that
/// is the point: §3b says the three things that decide whether a room recording is
/// usable are not code. They are the microphone mode (checked before this recorder is
/// ever built, by `MicrophoneModeCheck`), the choice of input device — a boundary
/// microphone on the table beats any amount of model tuning — and leaving the signal
/// alone. So this class selects the device, installs the tap, and touches nothing else:
/// no automatic gain control, no noise gate, no voice processing, no normalization.
/// Every kind of sharpening makes diarization worse rather than better.
actor MicRecorder: AudioRecorder {
    enum RecorderError: LocalizedError, CustomStringConvertible {
        case alreadyRunning
        case engineRefused(String)
        case noInputChannels

        var description: String {
            switch self {
            case .alreadyRunning:
                return "the microphone recorder is already running"
            case .engineRefused(let detail):
                return "the audio engine would not start: \(detail)"
            case .noInputChannels:
                return "the input device reports no channels"
            }
        }

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return String(localized: "Es läuft bereits eine Aufnahme.")
            case .engineRefused(let detail):
                return String(
                    format: String(localized: "Das Mikrofon ließ sich nicht öffnen: %@"),
                    detail
                )
            case .noInputChannels:
                return String(localized: "Das Eingabegerät liefert keine Kanäle.")
            }
        }
    }

    /// How long a device is given to come back after a configuration change before the
    /// recording is declared lost.
    ///
    /// A device changing its sample rate mid-recording, or macOS moving the default
    /// input, both look exactly like a disconnect for a moment. Two seconds is long
    /// enough for the engine to be rebuilt on the same hardware and short enough that
    /// a recording of silence never gets far.
    static let restartWindow: Duration = .seconds(2)
    private static let restartAttemptDelay: Duration = .milliseconds(250)

    private let engine = AVAudioEngine()

    private var configuration: AudioRecorderConfiguration?
    private var writer: WAVWriter?
    /// The device actually in use, for `meta.input.device` and for the loss message.
    private var deviceName = ""
    /// The UID that was asked for, or `nil` when the system default was.
    private var requestedUID: String?
    private var configurationObserver: (any NSObjectProtocol)?
    /// What the file held when an interruption closed it, so a `stop` arriving
    /// afterwards still names the audio that was written rather than reporting none.
    private var lastResult: WAVWriter.Result?
    /// Set once capture has ended for good, so a second notification is ignored and
    /// the interruption is reported exactly once.
    private var hasEnded = false

    init() {}

    // MARK: - Start

    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
        guard writer == nil else { throw RecorderError.alreadyRunning }

        self.configuration = configuration
        self.requestedUID = configuration.inputDeviceUID
        self.hasEnded = false

        // The writer opens the file before the engine opens the hardware: if the
        // folder is not writable, that is worth failing on before the orange
        // microphone dot appears in the menu bar.
        let onInterruption = configuration.onInterruption
        let writer = try WAVWriter(
            folder: configuration.folder,
            channelCount: 1,
            onError: { error in
                onInterruption?(.writeFailed(error.localizedDescription))
            }
        )
        self.writer = writer

        do {
            try selectInputDevice(uid: configuration.inputDeviceUID)
            try disableProcessing()
            try startEngine(writer: writer)
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: writer.url)
            self.writer = nil
            self.configuration = nil
            throw error
        }

        observeConfigurationChanges()

        // `requestedUID`, not the configured one: it is `nil` when the configured
        // device turned out not to be attached, and `meta.input.device` has to name
        // the microphone that actually recorded.
        deviceName = AudioInputDevices.displayName(forUID: requestedUID)
        let mode = MicrophoneModeCheck.active()
        Log.audio.notice(
            """
            MicRecorder started on \(self.deviceName, privacy: .public), \
            microphone mode \(mode?.rawValue ?? "unknown", privacy: .public)
            """
        )
        return AudioRecorderStart(deviceName: deviceName, microphoneMode: mode?.metaValue)
    }

    /// Points the engine's input node at a particular device before it is started.
    ///
    /// This has to happen before `engine.start()`: the audio unit takes the device on
    /// the way up, and setting it on a running unit is either ignored or an error
    /// depending on the driver. `nil` means "leave it alone", which is the system
    /// default and what most recordings use.
    private func selectInputDevice(uid: String?) throws {
        guard let uid else { return }
        guard let deviceID = AudioInputDevices.coreAudioDeviceID(forUID: uid) else {
            // The configured microphone is not attached. Recording on whatever macOS
            // considers the input is better than refusing, and `meta.input.device`
            // records which device it actually was.
            Log.audio.notice("configured input device is not attached; using the system default")
            requestedUID = nil
            return
        }
        guard let unit = engine.inputNode.audioUnit else {
            throw RecorderError.engineRefused("the input node has no audio unit")
        }
        var value = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RecorderError.engineRefused("selecting the input device failed (OSStatus \(status))")
        }
        Log.audio.info("input device set to Core Audio object \(deviceID, privacy: .public)")
    }

    /// Specification §3b.3: no processing. Voice processing is macOS's echo
    /// cancellation, noise suppression, and automatic gain control in one switch, and
    /// every part of it works against a room recording.
    ///
    /// It is off by default, so this normally does nothing at all — but it is an
    /// engine-wide setting that another part of the app could turn on later, and being
    /// explicit here is cheaper than finding out from a bad recording.
    private func disableProcessing() throws {
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(false)
            Log.audio.notice("voice processing turned off for this recording")
        } catch {
            throw RecorderError.engineRefused("voice processing could not be turned off: \(error.localizedDescription)")
        }
    }

    /// Installs the tap and starts the engine.
    private func startEngine(writer: WAVWriter) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RecorderError.noInputChannels
        }

        // The tap format is the device's own — whatever rate and channel count it
        // runs at. The writer converts to 48 kHz 16-bit mono; when a device delivers
        // more than one channel, the converter's default channel map takes channel 0
        // rather than summing, because `onsite` is one room microphone and summing an
        // unrelated second input into it would only add noise.
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format,
            block: Self.tapBlock(writer: writer)
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineRefused(error.localizedDescription)
        }
        Log.audio.notice(
            """
            input tap installed: \(format.channelCount, privacy: .public) ch, \
            \(Int(format.sampleRate), privacy: .public) Hz
            """
        )
    }

    /// Built in a `nonisolated` context on purpose.
    ///
    /// The tap block runs on the engine's own thread, not on this actor, and it must
    /// not reach actor state — which is why it is made here, where it can capture only
    /// the writer. `WAVWriter.write` copies the buffer and returns; nothing in this
    /// closure waits for the disk.
    private nonisolated static func tapBlock(writer: WAVWriter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.write(buffer)
        }
    }

    // MARK: - Stop

    func stop() async throws -> AudioRecorderOutcome {
        removeConfigurationObserver()
        hasEnded = true

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Either the file is still open — the ordinary stop — or an interruption
        // already closed it and left what it held behind.
        let closed: WAVWriter.Result?
        if let writer {
            self.writer = nil
            closed = writer.close()
        } else {
            closed = lastResult
        }
        lastResult = nil
        self.configuration = nil

        guard let result = closed else {
            return AudioRecorderOutcome(
                audioFileName: nil,
                channels: MeetingMode.onsite.channels,
                frameCount: nil,
                duration: nil
            )
        }
        Log.audio.notice(
            """
            MicRecorder stopped: \(result.frameCount, privacy: .public) frames, \
            \(String(format: "%.1f", result.duration), privacy: .public) s
            """
        )
        return AudioRecorderOutcome(
            audioFileName: result.fileName,
            channels: MeetingMode.onsite.channels,
            frameCount: result.frameCount,
            duration: result.duration
        )
    }

    // MARK: - Interruptions

    /// Watches for the engine's configuration changing under the recording.
    ///
    /// `AVAudioEngineConfigurationChangeNotification` is posted for anything that
    /// invalidates the graph: a device unplugged, a device changing its sample rate,
    /// macOS moving the default input to something else. The notification does not say
    /// which, so `handleConfigurationChange` finds out.
    ///
    /// The observer is registered without an object filter. There is exactly one engine
    /// per recorder and one recorder per recording, so anything posted while this
    /// recorder is running is about this engine — and filtering by object would mean
    /// handing a non-`Sendable` engine to `NotificationCenter` from an actor.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    /// Decides whether the recording can carry on, and ends it when it cannot.
    ///
    /// Two cases hide behind one notification, and the plan's device-loss handling
    /// depends on telling them apart:
    ///
    /// - The configured device is gone from Core Audio entirely → the recording is
    ///   over. `onInterruption` fires and the coordinator writes `failed`.
    /// - The device is still there but the graph is stale, usually because its sample
    ///   rate changed → the engine is rebuilt on the same device, the tap reinstalled
    ///   at the new format, and the recording continues into the same file. The writer
    ///   notices the new input format and keeps the file at 48 kHz.
    ///
    /// Only if the rebuild does not succeed within `restartWindow` is that treated as
    /// a loss too.
    private func handleConfigurationChange() async {
        guard !hasEnded, let writer, let configuration else { return }
        Log.audio.notice("audio engine configuration changed during a recording")

        if let uid = requestedUID, !AudioInputDevices.isAttached(uid: uid) {
            Log.audio.error("the configured input device is gone")
            await end(with: .inputDeviceLost(device: deviceName), configuration: configuration)
            return
        }

        let deadline = ContinuousClock.now.advanced(by: Self.restartWindow)
        var lastError: String = "unknown"
        while ContinuousClock.now < deadline {
            do {
                try restart(writer: writer)
                Log.audio.notice("recording continues after the configuration change")
                return
            } catch {
                lastError = error.localizedDescription
                Log.audio.error("restart after a configuration change failed: \(lastError, privacy: .public)")
                try? await Task.sleep(for: Self.restartAttemptDelay)
                if hasEnded { return }
            }
        }

        // Out of time. If the device itself disappeared in the meantime, say that
        // rather than blaming the engine — it is the sentence the user can act on.
        if let uid = requestedUID, !AudioInputDevices.isAttached(uid: uid) {
            await end(with: .inputDeviceLost(device: deviceName), configuration: configuration)
        } else {
            await end(with: .captureStopped(lastError), configuration: configuration)
        }
    }

    /// Rebuilds the tap on the current hardware and starts the engine again.
    private func restart(writer: WAVWriter) throws {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        try selectInputDevice(uid: requestedUID)
        try startEngine(writer: writer)
    }

    /// Ends the recording from the inside: closes the file, then reports why.
    ///
    /// The file is closed before the callback fires, so by the time the coordinator
    /// writes `state: failed` the WAV on disk is complete and playable up to the
    /// interruption. That is the difference between a lost meeting and a short one.
    private func end(
        with reason: AudioInterruptionReason,
        configuration: AudioRecorderConfiguration
    ) async {
        guard !hasEnded else { return }
        hasEnded = true
        removeConfigurationObserver()

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let writer {
            let result = writer.close()
            Log.audio.notice(
                "recording interrupted after \(result.frameCount, privacy: .public) frames"
            )
            lastResult = result
            self.writer = nil
        }
        self.configuration = nil
        configuration.onInterruption?(reason)
    }
}
