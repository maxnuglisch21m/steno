import Foundation

/// Where the two channels of an `online` `audio.wav` come from inside the aggregate
/// device's input buffer list.
///
/// The aggregate device built in `ProcessTapRecorder` has two members — the microphone
/// as a sub-device and the process tap — and hands both to one IOProc in a single
/// `AudioBufferList`. How that list is laid out is up to the HAL: it may be one buffer
/// with every channel interleaved, or one buffer per stream, and the channel counts
/// depend on the microphone (mono built-in, stereo interface, eight-channel desk) and
/// on the tap (stereo, in every case seen so far, but a mixdown is not promised to
/// stay stereo forever).
///
/// So nothing about the layout is assumed at the call site. The channel counts are
/// read from the device at start time, this type turns them into two lists of exact
/// sample offsets, and the IOProc walks those. Specification §3a.3:
///
/// - **ch0** is the mean of every tap channel — the system audio, downmixed to mono.
/// - **ch1** is the microphone's first channel. Not a mixdown: a second microphone
///   channel is a different capsule in the same room, and summing it in would only
///   add noise to the one signal that is guaranteed to be the user.
///
/// The order of the two blocks is the aggregate's own: sub-devices first, taps after,
/// which is how `kAudioAggregateDeviceSubDeviceListKey` and
/// `kAudioAggregateDeviceTapListKey` are composed. `resolve` is given that order
/// rather than assuming it, so a machine that reports the other way round is a
/// one-line change and a test rather than a rewrite.
struct AggregateChannelMap: Sendable, Equatable {
    /// One channel, addressed the way the IOProc has to address it: sample
    /// `frame * stride + offset` of buffer `buffer`.
    struct Source: Sendable, Equatable {
        /// Index into the `AudioBufferList`.
        var buffer: Int
        /// The channel's position inside an interleaved frame of that buffer.
        var offset: Int
        /// Channels per frame in that buffer, i.e. how far one frame is from the next.
        var stride: Int
    }

    /// Channels per input buffer, in the order the IOProc receives them.
    var bufferChannelCounts: [Int]
    /// The channels summed and averaged into ch0.
    var tap: [Source]
    /// The channel copied to ch1.
    var mic: Source

    /// Total channels across every buffer.
    var totalChannels: Int { bufferChannelCounts.reduce(0, +) }

    /// Builds the map, or returns `nil` when the device does not describe the layout
    /// that was asked for — which is a refusal to record rather than a guess, because
    /// a wrong guess produces a two-channel file in which ch0 is half the microphone.
    ///
    /// - Parameters:
    ///   - bufferChannelCounts: `kAudioDevicePropertyStreamConfiguration` of the
    ///     aggregate device, input scope, as channel counts per buffer.
    ///   - micChannelCount: channels the microphone sub-device contributes.
    ///   - tapChannelCount: channels the tap contributes, from `kAudioTapPropertyFormat`.
    ///   - micFirst: whether the microphone's channels come before the tap's.
    static func resolve(
        bufferChannelCounts: [Int],
        micChannelCount: Int,
        tapChannelCount: Int,
        micFirst: Bool = true
    ) -> AggregateChannelMap? {
        guard micChannelCount > 0, tapChannelCount > 0 else { return nil }
        guard bufferChannelCounts.allSatisfy({ $0 > 0 }) else { return nil }
        let total = bufferChannelCounts.reduce(0, +)
        guard total == micChannelCount + tapChannelCount else { return nil }

        let micStart = micFirst ? 0 : tapChannelCount
        let tapStart = micFirst ? micChannelCount : 0

        guard let mic = source(at: micStart, in: bufferChannelCounts) else { return nil }
        var tap: [Source] = []
        tap.reserveCapacity(tapChannelCount)
        for index in 0..<tapChannelCount {
            guard let channel = source(at: tapStart + index, in: bufferChannelCounts) else { return nil }
            tap.append(channel)
        }
        return AggregateChannelMap(bufferChannelCounts: bufferChannelCounts, tap: tap, mic: mic)
    }

    /// The map to use when the channel counts do not add up.
    ///
    /// The tap's channel count is the one number that is certain — it comes from
    /// `kAudioTapPropertyFormat`, not from an aggregate device's idea of its members —
    /// so the tap is taken from the end of the buffer list and the microphone from the
    /// very front. Used only after `resolve` has refused, and only with a line in the
    /// log saying so.
    static func tapAtEnd(bufferChannelCounts: [Int], tapChannelCount: Int) -> AggregateChannelMap? {
        guard tapChannelCount > 0, bufferChannelCounts.allSatisfy({ $0 > 0 }) else { return nil }
        let total = bufferChannelCounts.reduce(0, +)
        guard total > tapChannelCount else { return nil }
        return resolve(
            bufferChannelCounts: bufferChannelCounts,
            micChannelCount: total - tapChannelCount,
            tapChannelCount: tapChannelCount
        )
    }

    /// Turns a channel index counted across the whole buffer list into a buffer, an
    /// offset inside a frame, and the frame stride.
    private static func source(at globalChannel: Int, in bufferChannelCounts: [Int]) -> Source? {
        var remaining = globalChannel
        for (index, channels) in bufferChannelCounts.enumerated() {
            if remaining < channels {
                return Source(buffer: index, offset: remaining, stride: channels)
            }
            remaining -= channels
        }
        return nil
    }

    /// A one-line description for the log: `mic=b0c0/1 tap=b1c0/2,b1c1/2`.
    ///
    /// Worth logging on every recording. When a two-channel file turns out wrong, this
    /// line is the difference between knowing which channel went where and guessing.
    var logDescription: String {
        func describe(_ source: Source) -> String {
            "b\(source.buffer)c\(source.offset)/\(source.stride)"
        }
        return "mic=\(describe(mic)) tap=\(tap.map(describe).joined(separator: ","))"
    }

    // MARK: - The mix itself

    /// The downmix, as a pure function over plain arrays.
    ///
    /// This is what the IOProc does, written so it can be tested without a Mac, a tap,
    /// or a microphone: given the interleaved contents of each input buffer, produce
    /// the interleaved stereo frames that go into the ring buffer. The real-time
    /// version in `ProcessTapRecorder` walks the same offsets over raw pointers;
    /// keeping the arithmetic here is what makes the table of layouts in the tests
    /// worth anything.
    ///
    /// - Returns: `frames × 2` interleaved samples — ch0 system, ch1 microphone.
    func mix(buffers: [[Float]], frames: Int) -> [Float] {
        guard frames > 0, buffers.count == bufferChannelCounts.count else { return [] }
        var output = [Float](repeating: 0, count: frames * 2)
        let tapScale = Float(1) / Float(tap.count)
        for frame in 0..<frames {
            var sum: Float = 0
            for source in tap {
                sum += buffers[source.buffer][frame * source.stride + source.offset]
            }
            output[frame * 2] = sum * tapScale
            output[frame * 2 + 1] = buffers[mic.buffer][frame * mic.stride + mic.offset]
        }
        return output
    }
}
