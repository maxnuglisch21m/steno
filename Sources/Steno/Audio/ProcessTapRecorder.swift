import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import StenoCore
import Synchronization

/// `online` capture: system audio and the microphone, one file, two channels,
/// sample-exact. Specification §3a.
///
/// The shape of it, and why each part is the way it is:
///
/// 1. **A process tap** on the meeting app (`CATapDescription` →
///    `AudioHardwareCreateProcessTap`). What the tap sees is the app's finished mix —
///    §3a is explicit that per-speaker streams do not exist outside Teams' cloud
///    compliance API, so separating the other participants is diarization's job in §5,
///    on ch0. When no single meeting app can be identified, the tap is system-wide
///    with Steno itself excluded.
/// 2. **One aggregate device** holding both the microphone and that tap
///    (`AudioHardwareCreateAggregateDevice`). This is the whole point of the design:
///    two devices in one aggregate share one clock and one IOProc, so ch0 and ch1 stay
///    aligned for the length of a meeting. Two separate captures would drift — the
///    fallback §3a mentions, and second choice for exactly that reason. The microphone
///    is the main sub-device, i.e. the clock master, and the tap follows it with drift
///    compensation, because the microphone is real hardware with a real crystal and
///    the tap is software that can be resampled.
/// 3. **One IOProc**, which does nothing but arithmetic and a `memcpy` into a
///    preallocated ring buffer. It runs under a real-time deadline: no allocation, no
///    locks, no logging, no actor hops. See `AudioRingBuffer` and `TapCapture`.
/// 4. **A drain timer** on an ordinary queue, which turns those frames into
///    `AVAudioPCMBuffer`s and hands them to `WAVWriter` — the same writer `onsite`
///    uses, so the file format, the crash resilience, and the conversion are shared.
///
/// Adapted from [AudioCap](https://github.com/insidegui/AudioCap) (BSD-2-Clause,
/// `ThirdPartyLicenses/AudioCap-LICENSE.txt`): the tap description, the aggregate
/// device dictionary, and the teardown order are its design. What is new here is the
/// microphone as a second member of the aggregate, the channel mapping, the ring
/// buffer, and everything about interruptions.
actor ProcessTapRecorder: AudioRecorder {
    enum RecorderError: LocalizedError, CustomStringConvertible {
        case alreadyRunning
        case noInputDevice(String)
        case tapFailed(String)
        case aggregateFailed(String)
        case unexpectedChannelLayout(buffers: [Int], mic: Int, tap: Int)
        case ioProcFailed(String)

        var description: String {
            switch self {
            case .alreadyRunning:
                return "the process tap recorder is already running"
            case .noInputDevice(let detail):
                return "no usable input device: \(detail)"
            case .tapFailed(let detail):
                return "the process tap could not be created: \(detail)"
            case .aggregateFailed(let detail):
                return "the aggregate device could not be created: \(detail)"
            case .unexpectedChannelLayout(let buffers, let mic, let tap):
                return "the aggregate device reports channels \(buffers) for a \(mic) channel microphone and a \(tap) channel tap"
            case .ioProcFailed(let detail):
                return "the aggregate device would not start: \(detail)"
            }
        }

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return String(localized: "Es läuft bereits eine Aufnahme.")
            case .noInputDevice(let detail):
                return String(
                    format: String(localized: "Es ist kein Eingabegerät verfügbar: %@"),
                    detail
                )
            case .tapFailed(let detail):
                return String(
                    format: String(localized: "Der System-Audio-Mitschnitt ließ sich nicht einrichten: %@"),
                    detail
                )
            case .aggregateFailed(let detail):
                return String(
                    format: String(localized: "Das gemeinsame Audiogerät ließ sich nicht anlegen: %@"),
                    detail
                )
            case .unexpectedChannelLayout:
                return String(localized: "Die Kanalaufteilung des Audiogeräts ist unerwartet. Die Aufnahme wurde nicht gestartet.")
            case .ioProcFailed(let detail):
                return String(
                    format: String(localized: "Die Audioaufnahme ließ sich nicht starten: %@"),
                    detail
                )
            }
        }
    }

    // MARK: - Tuning

    /// How long the hardware is given to come back before the recording is declared
    /// lost. The same two seconds `MicRecorder` allows, for the same reason: a device
    /// changing its sample rate and a device being unplugged look identical at first.
    static let restartWindow: Duration = .seconds(2)
    private static let restartAttemptDelay: Duration = .milliseconds(250)
    /// How much audio the ring buffer holds. Four seconds is eighty times the drain
    /// interval and still under 1.5 MB — enough to sit out a stalled disk, small
    /// enough that nothing is lost worth mentioning if the process dies.
    private static let ringSeconds: Double = 4
    /// How often the ring is emptied into the WAV file.
    private static let drainInterval: DispatchTimeInterval = .milliseconds(50)
    /// Largest block the IOProc converts in one pass. Callbacks are normally 512 to
    /// 4096 frames; this is preallocated once and chunked through if one is larger.
    private static let scratchFrames = 8192

    // MARK: - State

    /// Where the IOProc runs. `userInteractive` because it is audio, and its own queue
    /// because nothing else may ever be scheduled behind it.
    private let ioQueue = DispatchQueue(label: "de.21m.steno.tap-io", qos: .userInteractive)
    /// Where the ring buffer is emptied and the listeners are delivered.
    private let drainQueue = DispatchQueue(label: "de.21m.steno.tap-drain", qos: .userInitiated)

    private var configuration: AudioRecorderConfiguration?
    private var writer: WAVWriter?
    private var hardware: Hardware?
    private var capture: TapCapture?
    private var drain: TapDrain?
    private var drainTimer: DispatchSourceTimer?
    private var listeners: [InstalledListener] = []

    /// What the tap points at. Decided by the coordinator, not here.
    private var target: TapTarget = .systemWide
    /// The UID that was asked for, or `nil` for the system default.
    private var requestedUID: String?
    /// The microphone actually in use, for `meta.input.device` and the loss message.
    private var deviceName = ""
    /// What the file held when an interruption closed it.
    private var lastResult: WAVWriter.Result?
    private var hasEnded = false

    init() {}

    // MARK: - Start

    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
        guard writer == nil else { throw RecorderError.alreadyRunning }

        self.configuration = configuration
        self.target = configuration.tapTarget
        self.requestedUID = configuration.inputDeviceUID
        self.hasEnded = false
        self.lastResult = nil

        // The file is opened before the hardware, as in `MicRecorder`: a folder that
        // cannot be written to is worth failing on before a tap exists.
        let onInterruption = configuration.onInterruption
        let writer = try WAVWriter(
            folder: configuration.folder,
            channelCount: 2,
            onError: { error in
                onInterruption?(.writeFailed(error.localizedDescription))
            }
        )
        self.writer = writer

        do {
            try openHardware(writer: writer)
        } catch {
            closeHardware()
            writer.close()
            try? FileManager.default.removeItem(at: writer.url)
            self.writer = nil
            self.configuration = nil
            throw error
        }

        installListeners()
        return AudioRecorderStart(deviceName: deviceName, microphoneMode: nil)
    }

    // MARK: - Stop

    func stop() async throws -> AudioRecorderOutcome {
        removeListeners()
        hasEnded = true
        closeHardware()

        let closed: WAVWriter.Result?
        if let writer {
            self.writer = nil
            closed = writer.close()
        } else {
            closed = lastResult
        }
        lastResult = nil
        configuration = nil

        guard let result = closed else {
            return AudioRecorderOutcome(
                audioFileName: nil,
                channels: MeetingMode.online.channels,
                frameCount: nil,
                duration: nil
            )
        }
        Log.audio.notice(
            """
            ProcessTapRecorder stopped: \(result.frameCount, privacy: .public) frames, \
            \(String(format: "%.1f", result.duration), privacy: .public) s
            """
        )
        return AudioRecorderOutcome(
            audioFileName: result.fileName,
            channels: MeetingMode.online.channels,
            frameCount: result.frameCount,
            duration: result.duration
        )
    }

    // MARK: - The hardware

    /// Everything Core Audio handed out, so it can be handed back in the right order.
    private struct Hardware {
        var tapID: AudioObjectID
        var tapUUID: UUID
        var aggregateID: AudioDeviceID
        var procID: AudioDeviceIOProcID?
        var micDeviceID: AudioDeviceID
        var micUID: String
        var sampleRate: Double
        var map: AggregateChannelMap
        /// The tapped process, when one was named. Watched so that an app quitting
        /// mid-meeting shows up in the log rather than as silence.
        var tappedProcessObject: AudioObjectID?
    }

    /// Builds the tap, the aggregate device, the ring, and the IOProc, and starts it.
    ///
    /// Every failure path leaves nothing behind: `closeHardware` is called by the
    /// caller, and it tolerates a half-built `Hardware`.
    private func openHardware(writer: WAVWriter) throws {
        // 1 — the microphone. It is the aggregate's main sub-device, so it has to
        //     exist before anything else is created.
        let micDeviceID = try resolveInputDevice()
        let micUID: String
        do {
            micUID = try micDeviceID.deviceUID()
        } catch {
            throw RecorderError.noInputDevice(String(describing: error))
        }
        deviceName = AudioInputDevices.displayName(forUID: requestedUID)

        // 2 — the tap.
        let (description, tappedProcess) = try makeTapDescription()
        var tapID = AudioObjectID.unknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID.isValid else {
            throw RecorderError.tapFailed(
                CoreAudio.Failure(what: "creating the process tap", status: tapStatus).description
            )
        }

        var hardware = Hardware(
            tapID: tapID,
            tapUUID: description.uuid,
            aggregateID: .unknown,
            procID: nil,
            micDeviceID: micDeviceID,
            micUID: micUID,
            sampleRate: WAVWriter.sampleRate,
            map: AggregateChannelMap(bufferChannelCounts: [], tap: [], mic: .init(buffer: 0, offset: 0, stride: 1)),
            tappedProcessObject: tappedProcess
        )
        self.hardware = hardware

        let tapFormat: AudioStreamBasicDescription
        do {
            tapFormat = try tapID.tapStreamDescription()
        } catch {
            throw RecorderError.tapFailed(String(describing: error))
        }
        let tapChannelCount = Int(tapFormat.mChannelsPerFrame)
        Log.audio.notice(
            """
            process tap #\(tapID, privacy: .public) created: \
            \(tapChannelCount, privacy: .public) ch, \
            \(Int(tapFormat.mSampleRate), privacy: .public) Hz, \
            \(Int(tapFormat.mBitsPerChannel), privacy: .public) bit, \
            flags \(tapFormat.mFormatFlags, privacy: .public), target \(self.target.logDescription, privacy: .public)
            """
        )
        guard tapChannelCount > 0 else {
            throw RecorderError.tapFailed("the tap reports no channels")
        }

        // 3 — the aggregate device: microphone plus tap, one clock, one callback.
        let aggregateUID = UUID().uuidString
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Steno Aufnahme",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // The microphone is the clock master. Real hardware leads; the tap, which
            // is software, follows it through the drift compensation below.
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            // Private: it never appears in Sound settings or in any other app's device
            // list, and disappears with this process.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // False, and this is the one place where Steno departs from AudioCap.
            //
            // With auto-start on, the aggregate device's IOProc only runs while the
            // tap is running — which for a process tap means only while the tapped app
            // is actually playing something. Measured on this machine: a tap on a
            // silent app, auto-start on, produced **zero** callbacks in ten seconds;
            // the same tap with auto-start off produced 240 128 frames in five, exactly
            // 48 kHz. That difference is the recording: with auto-start on, every
            // silence in the meeting would stop the microphone channel as well and the
            // remaining audio would close up behind it, so ch1 would lose whatever was
            // said while the far end was quiet and nothing in the file would line up
            // with the clock, the screenshots, or ch0 any more.
            //
            // Off, the aggregate runs on the microphone's clock from the moment
            // `AudioDeviceStart` returns, and the tap contributes digital silence while
            // the app is quiet — verified: a tap created during silence picks the audio
            // up at full level when playback starts afterwards.
            //
            // AudioCap does not hit this because its aggregate is built around the
            // default *output* device, which is always live. Steno's is built around
            // the microphone, because §3a needs both channels in one file on one clock.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var aggregateID = AudioDeviceID.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID.isValid else {
            // This is where §3a's fallback would go: two writers, `system.wav` from the
            // tap and `mic.wav` from an `AVAudioEngine`, with the `mHostTime` of each
            // one's first sample written to `meta.sync` so a reader could line them up.
            // It stays unwritten deliberately. Two captures on two clocks drift over an
            // hour — which is what the specification says, and the reason the aggregate
            // route is the design rather than the alternative — so it is not worth
            // carrying a second, worse recording path that nothing has needed: the
            // aggregate device has not failed once on this machine, and a failure here
            // is reported rather than papered over.
            throw RecorderError.aggregateFailed(
                CoreAudio.Failure(what: "creating the aggregate device", status: aggregateStatus).description
            )
        }
        hardware.aggregateID = aggregateID
        self.hardware = hardware

        // 4 — 48 kHz if the device will have it. If it will not, `WAVWriter` converts
        //     and the file is still 48 kHz; the recording is not worth refusing over.
        if !aggregateID.setNominalSampleRate(WAVWriter.sampleRate) {
            Log.audio.notice("the aggregate device refused 48 kHz; recording at its own rate and converting")
        }
        let sampleRate = (try? aggregateID.nominalSampleRate()) ?? WAVWriter.sampleRate
        hardware.sampleRate = sampleRate > 0 ? sampleRate : WAVWriter.sampleRate

        // 5 — who is where in the callback's buffer list.
        let map = try resolveChannelMap(
            aggregateID: aggregateID,
            micDeviceID: micDeviceID,
            tapChannelCount: tapChannelCount
        )
        hardware.map = map
        self.hardware = hardware
        Log.audio.notice(
            """
            aggregate device #\(aggregateID, privacy: .public) at \
            \(Int(hardware.sampleRate), privacy: .public) Hz, buffers \
            \(map.bufferChannelCounts.map(String.init).joined(separator: "+"), privacy: .public) — \
            \(map.logDescription, privacy: .public)
            """
        )

        // 6 — the ring, the mixer, and the drain. All allocated here, before the
        //     IOProc exists, because the IOProc may not allocate.
        let ring = AudioRingBuffer(
            channelCount: 2,
            capacityFrames: Int(hardware.sampleRate * Self.ringSeconds)
        )
        let capture = TapCapture(ring: ring, map: map, scratchFrames: Self.scratchFrames)
        guard let drain = TapDrain(ring: ring, writer: writer, sampleRate: hardware.sampleRate) else {
            throw RecorderError.ioProcFailed("a 2-channel Float32 buffer could not be built")
        }
        self.capture = capture
        self.drain = drain

        // 7 — the IOProc. The block below is the real-time path and is built in a
        //     `nonisolated` context so it cannot reach this actor even by accident.
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            ioQueue,
            Self.makeIOBlock(capture: capture)
        )
        guard procStatus == noErr, let procID else {
            throw RecorderError.ioProcFailed(
                CoreAudio.Failure(what: "creating the device I/O proc", status: procStatus).description
            )
        }
        hardware.procID = procID
        self.hardware = hardware

        startDrainTimer(drain)

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw RecorderError.ioProcFailed(
                CoreAudio.Failure(what: "starting the aggregate device", status: startStatus).description
            )
        }

        Log.audio.notice(
            """
            ProcessTapRecorder started on \(self.deviceName, privacy: .public) + tap, \
            ring \(ring.capacityFrames, privacy: .public) frames
            """
        )
    }

    /// The microphone the aggregate is built around: the configured one when it is
    /// attached, the system default otherwise.
    private func resolveInputDevice() throws -> AudioDeviceID {
        if let uid = requestedUID {
            if let deviceID = AudioInputDevices.coreAudioDeviceID(forUID: uid) {
                return deviceID
            }
            // Same rule as `MicRecorder`: record on whatever macOS considers the input
            // rather than refusing, and let `meta.input.device` say which that was.
            Log.audio.notice("configured input device is not attached; using the system default")
            requestedUID = nil
        }
        do {
            return try AudioObjectID.defaultInputDevice()
        } catch {
            throw RecorderError.noInputDevice(String(describing: error))
        }
    }

    /// Specification §3a.1: a mixdown of the tapped app, or everything the Mac plays
    /// with Steno itself left out.
    ///
    /// Returns the tapped process object alongside the description, so that the
    /// listener watching for that app quitting has something to attach to.
    private func makeTapDescription() throws -> (CATapDescription, AudioObjectID?) {
        let description: CATapDescription
        var tappedProcess: AudioObjectID?
        switch target {
        case .process(let pid, let bundleId, _):
            let objectID: AudioObjectID
            do {
                objectID = try AudioObjectID.processObject(forPID: pid)
            } catch {
                throw RecorderError.tapFailed("\(bundleId) (pid \(pid)): \(String(describing: error))")
            }
            tappedProcess = objectID
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
        case .systemWide:
            // Excluding Steno's own process is what keeps a future notification sound
            // out of the recording — and, more importantly, what would stop a tap from
            // ever feeding itself.
            var excluded: [AudioObjectID] = []
            if let own = try? AudioObjectID.processObject(forPID: getpid()) {
                excluded.append(own)
            } else {
                Log.audio.notice("Steno's own process object could not be resolved; the global tap excludes nothing")
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        description.uuid = UUID()
        description.name = "Steno"
        // Private: the tap belongs to this process and shows up in no other app.
        description.isPrivate = true
        // The user keeps hearing the meeting. Muting what is being tapped would be a
        // recorder that silences the call it is recording.
        description.muteBehavior = .unmuted
        return (description, tappedProcess)
    }

    /// Reads the channel counts off the devices and works out which sample is which.
    private func resolveChannelMap(
        aggregateID: AudioDeviceID,
        micDeviceID: AudioDeviceID,
        tapChannelCount: Int
    ) throws -> AggregateChannelMap {
        let bufferChannelCounts: [Int]
        do {
            bufferChannelCounts = try aggregateID.inputStreamChannelCounts()
        } catch {
            throw RecorderError.aggregateFailed(String(describing: error))
        }
        let micChannelCount = ((try? micDeviceID.inputStreamChannelCounts()) ?? []).reduce(0, +)

        if let map = AggregateChannelMap.resolve(
            bufferChannelCounts: bufferChannelCounts,
            micChannelCount: micChannelCount,
            tapChannelCount: tapChannelCount
        ) {
            return map
        }
        // The counts did not add up — an aggregate exposing fewer of the microphone's
        // channels than the device has is the plausible way that happens. The tap's
        // own channel count is the one number that is certain, so the tap is taken
        // from the end of the list and the microphone from the front.
        if let fallback = AggregateChannelMap.tapAtEnd(
            bufferChannelCounts: bufferChannelCounts,
            tapChannelCount: tapChannelCount
        ) {
            Log.audio.error(
                """
                unexpected aggregate layout: buffers \
                \(bufferChannelCounts.map(String.init).joined(separator: "+"), privacy: .public) for a \
                \(micChannelCount, privacy: .public) ch microphone and a \(tapChannelCount, privacy: .public) ch tap — \
                falling back to tap-at-the-end
                """
            )
            return fallback
        }
        throw RecorderError.unexpectedChannelLayout(
            buffers: bufferChannelCounts,
            mic: micChannelCount,
            tap: tapChannelCount
        )
    }

    /// Hands the frames back in, every 50 ms.
    private func startDrainTimer(_ drain: TapDrain) {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval, leeway: .milliseconds(10))
        timer.setEventHandler { drain.drain() }
        drainTimer = timer
        timer.resume()
    }

    /// Gives everything back, in the order Core Audio wants it back.
    ///
    /// Safe to call on a half-built `Hardware` and safe to call twice — both are
    /// ordinary, because it runs on every failure path in `openHardware` as well as
    /// on `stop`.
    private func closeHardware() {
        drainTimer?.cancel()
        drainTimer = nil

        if let hardware {
            if hardware.aggregateID.isValid {
                if let procID = hardware.procID {
                    let stopStatus = AudioDeviceStop(hardware.aggregateID, procID)
                    if stopStatus != noErr {
                        Log.audio.error("stopping the aggregate device returned \(stopStatus, privacy: .public)")
                    }
                    let destroyStatus = AudioDeviceDestroyIOProcID(hardware.aggregateID, procID)
                    if destroyStatus != noErr {
                        Log.audio.error("destroying the I/O proc returned \(destroyStatus, privacy: .public)")
                    }
                }
                // The producer has stopped, so everything still in the ring belongs in
                // the file. Synchronously, behind whatever tick was already running.
                if let drain {
                    drainQueue.sync { drain.drain() }
                }
                let aggregateStatus = AudioHardwareDestroyAggregateDevice(hardware.aggregateID)
                if aggregateStatus != noErr {
                    Log.audio.error("destroying the aggregate device returned \(aggregateStatus, privacy: .public)")
                }
            }
            if hardware.tapID.isValid {
                let tapStatus = AudioHardwareDestroyProcessTap(hardware.tapID)
                if tapStatus != noErr {
                    Log.audio.error("destroying the process tap returned \(tapStatus, privacy: .public)")
                }
            }
        }
        if let capture {
            let dropped = capture.ring.droppedFrames
            Log.audio.notice(
                """
                tap capture ended: \(capture.callbackCount, privacy: .public) callbacks, \
                \(capture.ring.writtenFrames, privacy: .public) frames, \
                \(dropped, privacy: .public) dropped, \
                \(capture.malformedCallbackCount, privacy: .public) malformed, \
                first host time \(capture.firstHostTimeValue, privacy: .public)
                """
            )
            if dropped > 0 {
                Log.audio.error("\(dropped, privacy: .public) frames were dropped: the writer could not keep up")
            }
        }
        hardware = nil
        capture = nil
        drain = nil
    }

    // MARK: - Interruptions

    /// One property listener, kept so it can be taken off again.
    private struct InstalledListener {
        var objectID: AudioObjectID
        var selector: AudioObjectPropertySelector
        var scope: AudioObjectPropertyScope
        var block: AudioObjectPropertyListenerBlock
    }

    /// Watches the three things that can end an `online` recording from the outside.
    private func installListeners() {
        guard let hardware else { return }

        // The aggregate device disappearing — the microphone unplugged, or the HAL
        // deciding the device is no longer viable.
        install(
            on: hardware.aggregateID,
            selector: kAudioDevicePropertyDeviceIsAlive
        ) { [weak self] in
            Task { await self?.handleAggregateChanged() }
        }

        // macOS moving the default input to something else. Only interesting while
        // recording on the default, which is the usual case.
        install(
            on: .system,
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) { [weak self] in
            Task { await self?.handleDefaultInputChanged() }
        }

        // The tapped app quitting. Not fatal: §3a's file keeps its microphone channel,
        // and deciding that a meeting is over is M3's auto-stop, not this recorder's.
        if let processObject = hardware.tappedProcessObject {
            install(on: processObject, selector: kAudioProcessPropertyIsRunning) { [weak self] in
                Task { await self?.handleTappedProcessChanged() }
            }
        }
    }

    private func install(
        on objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @Sendable () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard objectID.addListener(selector, scope: scope, on: drainQueue, block: block) != nil else { return }
        listeners.append(
            InstalledListener(objectID: objectID, selector: selector, scope: scope, block: block)
        )
    }

    private func removeListeners() {
        for listener in listeners {
            listener.objectID.removeListener(
                listener.selector,
                scope: listener.scope,
                on: drainQueue,
                block: listener.block
            )
        }
        listeners.removeAll()
    }

    private func handleAggregateChanged() async {
        guard !hasEnded, let hardware else { return }
        guard !hardware.aggregateID.isAlive() else { return }
        Log.audio.error("the aggregate device is no longer alive")
        await recover()
    }

    private func handleDefaultInputChanged() async {
        guard !hasEnded, let hardware, requestedUID == nil else { return }
        guard let current = try? AudioObjectID.defaultInputDevice() else {
            Log.audio.error("the default input device disappeared")
            await recover()
            return
        }
        guard current != hardware.micDeviceID else { return }
        Log.audio.notice("the default input device changed during a recording")
        await recover()
    }

    private func handleTappedProcessChanged() async {
        guard !hasEnded, let hardware, let processObject = hardware.tappedProcessObject else { return }
        let running = (try? processObject.readBool(
            kAudioProcessPropertyIsRunning,
            what: "reading whether the tapped process runs"
        )) ?? true
        guard !running else { return }
        // Deliberately only a log line. Auto-stop is specification §2 and M3's job;
        // ending a recording here would take the microphone away from a user who is
        // still talking.
        Log.audio.notice("the tapped app stopped playing audio; the recording continues on the microphone")
    }

    /// Rebuilds the tap and the aggregate on whatever hardware is there now, and gives
    /// up after `restartWindow`.
    ///
    /// The same policy as `MicRecorder`: a device that changed its sample rate or a
    /// default input that moved is survivable and the recording continues into the
    /// same file; a device that is simply gone ends the recording with a sentence that
    /// names it.
    private func recover() async {
        guard !hasEnded, let writer, let configuration else { return }

        if let uid = requestedUID, !AudioInputDevices.isAttached(uid: uid) {
            await end(with: .inputDeviceLost(device: deviceName), configuration: configuration)
            return
        }

        // The listeners hang off objects that are about to be destroyed, so they come
        // off first and are installed again on whatever the rebuild produced.
        removeListeners()
        let deadline = ContinuousClock.now.advanced(by: Self.restartWindow)
        var lastError = "unknown"
        while ContinuousClock.now < deadline {
            closeHardware()
            do {
                try openHardware(writer: writer)
                installListeners()
                Log.audio.notice("recording continues after the audio hardware changed")
                return
            } catch {
                lastError = error.localizedDescription
                Log.audio.error("rebuilding the tap failed: \(lastError, privacy: .public)")
                try? await Task.sleep(for: Self.restartAttemptDelay)
                if hasEnded { return }
            }
        }

        if let uid = requestedUID, !AudioInputDevices.isAttached(uid: uid) {
            await end(with: .inputDeviceLost(device: deviceName), configuration: configuration)
        } else {
            await end(with: .captureStopped(lastError), configuration: configuration)
        }
    }

    /// Ends the recording from the inside: the file is closed first, so what was
    /// captured stays playable, and only then is the coordinator told why.
    private func end(
        with reason: AudioInterruptionReason,
        configuration: AudioRecorderConfiguration
    ) async {
        guard !hasEnded else { return }
        hasEnded = true
        removeListeners()
        closeHardware()

        if let writer {
            let result = writer.close()
            Log.audio.notice("recording interrupted after \(result.frameCount, privacy: .public) frames")
            lastResult = result
            self.writer = nil
        }
        self.configuration = nil
        configuration.onInterruption?(reason)
    }

    // MARK: - The real-time path

    /// Built `nonisolated` and `static` on purpose.
    ///
    /// This block runs on `ioQueue` under a real-time deadline. Building it here means
    /// it can capture exactly one thing — the `TapCapture`, whose every allocation
    /// already happened — and has no way to reach actor state, take a lock, or log.
    /// Everything it does is arithmetic and two `memcpy`s.
    private nonisolated static func makeIOBlock(capture: TapCapture) -> AudioDeviceIOBlock {
        { _, inInputData, inInputTime, _, _ in
            capture.consume(inInputData, at: inInputTime)
        }
    }
}

// MARK: - The IOProc's world

/// The only object the audio thread touches.
///
/// Real-time safety is the whole design: the ring, the scratch block, and the channel
/// offsets are all allocated in `init`, on the thread that starts the recording, and
/// `consume` does nothing but read, average, and copy. No allocation, no locks, no
/// `Logger`, no actor, no ARC traffic — the counters are atomics precisely so that the
/// numbers can be read afterwards without the audio thread ever waiting for anything.
private final class TapCapture: @unchecked Sendable {
    let ring: AudioRingBuffer

    /// Channel offsets, in raw memory rather than a Swift `Array`, so that reading
    /// them cannot touch the runtime.
    private let tapSources: UnsafeMutableBufferPointer<AggregateChannelMap.Source>
    private let micSource: AggregateChannelMap.Source
    private let tapScale: Float
    private let bufferCount: Int
    /// One entry per input buffer, refilled at the top of every callback.
    private let bases: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>?>
    /// Interleaved stereo frames on their way to the ring.
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int

    private let callbacks = Atomic<Int>(0)
    private let malformed = Atomic<Int>(0)
    private let firstHostTime = Atomic<UInt64>(0)

    init(ring: AudioRingBuffer, map: AggregateChannelMap, scratchFrames: Int) {
        self.ring = ring
        self.micSource = map.mic
        self.bufferCount = map.bufferChannelCounts.count
        self.scratchFrames = scratchFrames

        // A map with no tap channels cannot come out of `resolve`, but the audio
        // thread is no place for a division by zero: the degenerate case takes the
        // microphone into ch0 as well rather than producing NaNs.
        let sourceList = map.tap.isEmpty ? [map.mic] : map.tap
        let sources = UnsafeMutableBufferPointer<AggregateChannelMap.Source>.allocate(capacity: sourceList.count)
        _ = sources.initialize(fromContentsOf: sourceList)
        self.tapSources = sources
        self.tapScale = 1 / Float(sourceList.count)

        let bases = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>?>.allocate(capacity: max(1, bufferCount))
        bases.initialize(repeating: nil)
        self.bases = bases

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
        self.scratch = scratch
    }

    deinit {
        tapSources.baseAddress?.deallocate()
        bases.deallocate()
        scratch.deinitialize(count: scratchFrames * 2)
        scratch.deallocate()
    }

    var callbackCount: Int { callbacks.load(ordering: .relaxed) }
    var malformedCallbackCount: Int { malformed.load(ordering: .relaxed) }
    /// The `mHostTime` of the first callback — the anchor a fallback two-file
    /// recording would need, and a useful thing to see in the log either way.
    var firstHostTimeValue: UInt64 { firstHostTime.load(ordering: .relaxed) }

    /// The real-time callback. Specification §3a.3, and nothing else.
    func consume(_ inputData: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard list.count == bufferCount, bufferCount > 0 else {
            malformed.wrappingAdd(1, ordering: .relaxed)
            return
        }

        let firstChannels = Int(list[0].mNumberChannels)
        guard firstChannels > 0 else {
            malformed.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let frames = Int(list[0].mDataByteSize) / (firstChannels * MemoryLayout<Float>.size)
        guard frames > 0 else { return }

        for index in 0..<bufferCount {
            let buffer = list[index]
            let channels = Int(buffer.mNumberChannels)
            guard
                let data = buffer.mData,
                channels > 0,
                Int(buffer.mDataByteSize) >= frames * channels * MemoryLayout<Float>.size
            else {
                malformed.wrappingAdd(1, ordering: .relaxed)
                return
            }
            bases[index] = data.assumingMemoryBound(to: Float.self)
        }

        callbacks.wrappingAdd(1, ordering: .relaxed)
        _ = firstHostTime.compareExchange(
            expected: 0,
            desired: time.pointee.mHostTime,
            ordering: .relaxed
        )

        let micBase = bases[micSource.buffer].unsafelyUnwrapped
        var done = 0
        while done < frames {
            let chunk = min(scratchFrames, frames - done)
            for offset in 0..<chunk {
                let frame = done + offset
                // ch0 — every tap channel, averaged. §3a: the app's mix, mono.
                var sum: Float = 0
                for index in 0..<tapSources.count {
                    let source = tapSources[index]
                    sum += bases[source.buffer].unsafelyUnwrapped[frame * source.stride + source.offset]
                }
                scratch[offset * 2] = sum * tapScale
                // ch1 — the microphone's first channel, untouched.
                scratch[offset * 2 + 1] = micBase[frame * micSource.stride + micSource.offset]
            }
            ring.write(scratch, frames: chunk)
            done += chunk
        }
    }
}

/// Empties the ring into `WAVWriter`, off the audio thread.
///
/// One `AVAudioPCMBuffer` is allocated up front and refilled, because the writer
/// copies what it is given: allocating a buffer twenty times a second would be twenty
/// pointless allocations a second.
private final class TapDrain: @unchecked Sendable {
    private let ring: AudioRingBuffer
    private let writer: WAVWriter
    private let buffer: AVAudioPCMBuffer
    private let capacityFrames: AVAudioFrameCount

    init?(ring: AudioRingBuffer, writer: WAVWriter, sampleRate: Double) {
        // Float32, interleaved, two channels: exactly what the ring holds, so the
        // drain is a `memcpy` and the writer does the conversion to 16-bit.
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: true
            ),
            // Half a second: ten drain intervals of headroom, so a late tick catches
            // up in one pass instead of leaving frames behind.
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 2))
        else { return nil }
        self.ring = ring
        self.writer = writer
        self.buffer = buffer
        self.capacityFrames = buffer.frameCapacity
    }

    /// Writes everything the ring holds. Called on the drain queue, and once more on
    /// the way out with the producer already stopped.
    func drain() {
        guard let destination = buffer.floatChannelData?[0] else { return }
        while true {
            let frames = ring.read(into: destination, frames: Int(capacityFrames))
            guard frames > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            writer.write(buffer)
            if frames < Int(capacityFrames) { return }
        }
    }
}
