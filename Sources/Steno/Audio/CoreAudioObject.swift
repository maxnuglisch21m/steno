import AudioToolbox
import CoreAudio
import Foundation

/// Reading and writing Core Audio object properties without repeating the same four
/// lines forty times.
///
/// Every call into the HAL follows the same shape — build an address, ask for the
/// size, ask for the data, check an `OSStatus` — and `ProcessTapRecorder` makes about
/// a dozen of them before the first sample arrives. This file is that shape, once.
///
/// Adapted from [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo
/// (BSD-2-Clause, `ThirdPartyLicenses/AudioCap-LICENSE.txt`): the property helpers,
/// the process-object list, and the PID translation follow its `CoreAudioUtils.swift`.
/// Strings are read through an explicit `CFString?` rather than a defaulted generic,
/// so ownership of the `+1` reference the HAL hands back is visible.
enum CoreAudio {
    /// A HAL call that did not return `noErr`.
    struct Failure: LocalizedError, CustomStringConvertible, Equatable {
        /// What was being attempted, in English, for the log.
        var what: String
        var status: OSStatus

        var description: String {
            "\(what) failed with OSStatus \(status) (\(Self.fourCharacterCode(status)))"
        }

        var errorDescription: String? { description }

        /// `OSStatus` values in Core Audio are usually four-character codes — `!obj`,
        /// `nope`, `who?` — and the number alone is unreadable. Both are printed.
        static func fourCharacterCode(_ status: OSStatus) -> String {
            let value = UInt32(bitPattern: status)
            let bytes = [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
            guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "—" }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

extension AudioObjectID {
    /// `kAudioObjectSystemObject`, the object every hardware-wide property hangs off.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// `kAudioObjectUnknown`.
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != AudioObjectID.unknown }

    // MARK: - Generic access

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// One fixed-size property value.
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        what: String
    ) throws -> T {
        var address = Self.address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudio.Failure(what: what, status: status) }
        return value
    }

    /// One fixed-size property value that needs a qualifier — `TranslatePIDToProcessObject`
    /// is the only one here, and the PID is the qualifier.
    func read<T, Q>(
        _ selector: AudioObjectPropertySelector,
        defaultValue: T,
        qualifier: Q,
        what: String
    ) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size)
        let status = withUnsafeMutablePointer(to: &inQualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &value) { valuePointer in
                AudioObjectGetPropertyData(
                    self, &address, qualifierSize, qualifierPointer, &size, valuePointer
                )
            }
        }
        guard status == noErr else { throw CoreAudio.Failure(what: what, status: status) }
        return value
    }

    /// A variable-length array property, such as the process-object list.
    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type,
        what: String
    ) throws -> [T] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudio.Failure(what: "\(what) (size)", status: status) }
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }

        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        guard status == noErr else { throw CoreAudio.Failure(what: what, status: status) }
        return Array(UnsafeBufferPointer(start: buffer.baseAddress!, count: Int(size) / MemoryLayout<T>.size))
    }

    /// A `CFString` property, read into an explicitly owned reference.
    ///
    /// The HAL writes a retained `CFStringRef` into the buffer, so the value has to be
    /// a real Swift reference that ARC will release — not a generic `T` seeded with a
    /// placeholder that would be overwritten and leaked.
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        what: String
    ) throws -> String {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else {
            throw CoreAudio.Failure(what: what, status: status == noErr ? -1 : status)
        }
        return value as String
    }

    func readBool(_ selector: AudioObjectPropertySelector, what: String) throws -> Bool {
        try read(selector, defaultValue: UInt32(0), what: what) == 1
    }

    func has(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    // MARK: - The properties this app actually reads

    /// `kAudioHardwarePropertyProcessObjectList` — one object per process that has
    /// ever touched audio. Specification §2's starting point.
    static func processObjectList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self,
            what: "reading the process object list"
        )
    }

    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`.
    ///
    /// The bridge between a process the user can see and the object a tap can name.
    /// Used for the tapped meeting app, and for Steno itself when a system-wide tap
    /// has to exclude its own output.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        let objectID: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid,
            what: "translating PID \(pid) to a process object"
        )
        guard objectID.isValid else {
            throw CoreAudio.Failure(what: "translating PID \(pid) to a process object", status: kAudioHardwareBadObjectError)
        }
        return objectID
    }

    /// `kAudioHardwarePropertyDefaultInputDevice`. The microphone the aggregate device
    /// is built around, and the clock everything else follows.
    static func defaultInputDevice() throws -> AudioDeviceID {
        let device: AudioDeviceID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioDeviceID.unknown,
            what: "reading the default input device"
        )
        guard device.isValid else {
            throw CoreAudio.Failure(what: "reading the default input device", status: kAudioHardwareBadDeviceError)
        }
        return device
    }

    func deviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID, what: "reading a device UID")
    }

    func deviceName() -> String? {
        try? readString(kAudioObjectPropertyName, what: "reading a device name")
    }

    /// `kAudioTapPropertyFormat` — what the tap will deliver.
    func tapStreamDescription() throws -> AudioStreamBasicDescription {
        try read(
            kAudioTapPropertyFormat,
            defaultValue: AudioStreamBasicDescription(),
            what: "reading the tap stream format"
        )
    }

    /// The channel count of every input buffer the device hands an IOProc, in order.
    ///
    /// This is how the aggregate device says where the microphone ends and the tap
    /// begins: `kAudioDevicePropertyStreamConfiguration` is an `AudioBufferList` with
    /// no samples in it, one entry per stream.
    func inputStreamChannelCounts() throws -> [Int] {
        var address = Self.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudio.Failure(what: "reading the input stream configuration (size)", status: status)
        }
        guard size > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw)
        guard status == noErr else {
            throw CoreAudio.Failure(what: "reading the input stream configuration", status: status)
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The sample rate the device is running at.
    func nominalSampleRate() throws -> Double {
        try read(
            kAudioDevicePropertyNominalSampleRate,
            defaultValue: Double(0),
            what: "reading the nominal sample rate"
        )
    }

    /// Asks the device to run at `rate`. Returns whether it agreed.
    ///
    /// An aggregate device follows its main sub-device, so this is a request rather
    /// than a setting: when the microphone insists on 44 100 Hz, `WAVWriter`'s
    /// converter does the rest and the file is still 48 kHz.
    @discardableResult
    func setNominalSampleRate(_ rate: Double) -> Bool {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        let status = AudioObjectSetPropertyData(
            self, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value
        )
        return status == noErr
    }

    /// `kAudioDevicePropertyDeviceIsAlive`. False once the aggregate has been pulled
    /// out from under the recording.
    func isAlive() -> Bool {
        (try? readBool(kAudioDevicePropertyDeviceIsAlive, what: "reading device liveness")) ?? false
    }

    // MARK: - Listeners

    /// Adds a property listener and returns the block, so it can be removed again.
    ///
    /// The block is what identifies the listener at removal time — losing it means
    /// leaking a listener into the HAL that fires into a deallocated recorder.
    @discardableResult
    func addListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        on queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> AudioObjectPropertyListenerBlock? {
        var address = Self.address(selector, scope: scope)
        let status = AudioObjectAddPropertyListenerBlock(self, &address, queue, block)
        guard status == noErr else {
            Log.audio.error(
                """
                could not add a listener for \(CoreAudio.Failure.fourCharacterCode(OSStatus(bitPattern: selector)), privacy: .public): \
                OSStatus \(status, privacy: .public)
                """
            )
            return nil
        }
        return block
    }

    func removeListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        on queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = Self.address(selector, scope: scope)
        let status = AudioObjectRemovePropertyListenerBlock(self, &address, queue, block)
        if status != noErr {
            Log.audio.debug("removing a property listener returned OSStatus \(status, privacy: .public)")
        }
    }
}
