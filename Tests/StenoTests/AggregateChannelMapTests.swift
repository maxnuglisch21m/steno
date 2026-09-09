import Foundation
import Testing

@testable import Steno

/// Which sample ends up in which channel of an `online` `audio.wav`.
///
/// This is the one piece of M2 that is silently wrong rather than loudly broken when
/// it is wrong: a file with the microphone in ch0 and half the system audio in ch1
/// plays back perfectly and ruins every transcript made from it. The layouts below are
/// the ones a Mac actually produces — a mono built-in microphone, a stereo interface,
/// an eight-channel desk, and the whole lot in one interleaved buffer.
@Suite("AggregateChannelMap")
struct AggregateChannelMapTests {
    /// One row of the layout table.
    struct Layout: Sendable, CustomStringConvertible {
        var name: String
        var buffers: [Int]
        var micChannels: Int
        var tapChannels: Int
        var expectedMic: AggregateChannelMap.Source
        var expectedTap: [AggregateChannelMap.Source]

        var description: String { name }
    }

    static let layouts: [Layout] = [
        Layout(
            name: "mono microphone, stereo tap, one buffer each",
            buffers: [1, 2],
            micChannels: 1,
            tapChannels: 2,
            expectedMic: .init(buffer: 0, offset: 0, stride: 1),
            expectedTap: [.init(buffer: 1, offset: 0, stride: 2), .init(buffer: 1, offset: 1, stride: 2)]
        ),
        Layout(
            name: "stereo microphone, stereo tap, one buffer each",
            buffers: [2, 2],
            micChannels: 2,
            tapChannels: 2,
            expectedMic: .init(buffer: 0, offset: 0, stride: 2),
            expectedTap: [.init(buffer: 1, offset: 0, stride: 2), .init(buffer: 1, offset: 1, stride: 2)]
        ),
        Layout(
            name: "everything in one interleaved buffer",
            buffers: [3],
            micChannels: 1,
            tapChannels: 2,
            expectedMic: .init(buffer: 0, offset: 0, stride: 3),
            expectedTap: [.init(buffer: 0, offset: 1, stride: 3), .init(buffer: 0, offset: 2, stride: 3)]
        ),
        Layout(
            name: "eight-channel interface, stereo tap",
            buffers: [8, 2],
            micChannels: 8,
            tapChannels: 2,
            expectedMic: .init(buffer: 0, offset: 0, stride: 8),
            expectedTap: [.init(buffer: 1, offset: 0, stride: 2), .init(buffer: 1, offset: 1, stride: 2)]
        ),
        Layout(
            name: "a tap that is not stereo",
            buffers: [1, 4],
            micChannels: 1,
            tapChannels: 4,
            expectedMic: .init(buffer: 0, offset: 0, stride: 1),
            expectedTap: [
                .init(buffer: 1, offset: 0, stride: 4),
                .init(buffer: 1, offset: 1, stride: 4),
                .init(buffer: 1, offset: 2, stride: 4),
                .init(buffer: 1, offset: 3, stride: 4)
            ]
        ),
        Layout(
            name: "one buffer per channel",
            buffers: [1, 1, 1],
            micChannels: 1,
            tapChannels: 2,
            expectedMic: .init(buffer: 0, offset: 0, stride: 1),
            expectedTap: [.init(buffer: 1, offset: 0, stride: 1), .init(buffer: 2, offset: 0, stride: 1)]
        )
    ]

    @Test("every layout resolves to the right offsets", arguments: layouts)
    func resolvesLayouts(layout: Layout) throws {
        let map = try #require(
            AggregateChannelMap.resolve(
                bufferChannelCounts: layout.buffers,
                micChannelCount: layout.micChannels,
                tapChannelCount: layout.tapChannels
            )
        )
        #expect(map.mic == layout.expectedMic)
        #expect(map.tap == layout.expectedTap)
        #expect(map.totalChannels == layout.micChannels + layout.tapChannels)
    }

    @Test("the tap can come first when the device says so")
    func tapFirst() throws {
        let map = try #require(
            AggregateChannelMap.resolve(
                bufferChannelCounts: [2, 1],
                micChannelCount: 1,
                tapChannelCount: 2,
                micFirst: false
            )
        )
        #expect(map.tap == [.init(buffer: 0, offset: 0, stride: 2), .init(buffer: 0, offset: 1, stride: 2)])
        #expect(map.mic == .init(buffer: 1, offset: 0, stride: 1))
    }

    @Test("counts that do not add up are refused rather than guessed at")
    func refusesMismatch() {
        #expect(AggregateChannelMap.resolve(bufferChannelCounts: [2], micChannelCount: 1, tapChannelCount: 2) == nil)
        #expect(AggregateChannelMap.resolve(bufferChannelCounts: [1, 2], micChannelCount: 2, tapChannelCount: 2) == nil)
        #expect(AggregateChannelMap.resolve(bufferChannelCounts: [], micChannelCount: 1, tapChannelCount: 2) == nil)
        #expect(AggregateChannelMap.resolve(bufferChannelCounts: [0, 2], micChannelCount: 0, tapChannelCount: 2) == nil)
        #expect(AggregateChannelMap.resolve(bufferChannelCounts: [1, 2], micChannelCount: 1, tapChannelCount: 0) == nil)
    }

    @Test("the fallback puts the tap at the end and the microphone at the front")
    func tapAtEndFallback() throws {
        // The aggregate reports four channels where the microphone claims eight: the
        // tap's own two are certain, so they are taken from the end.
        let map = try #require(AggregateChannelMap.tapAtEnd(bufferChannelCounts: [2, 2], tapChannelCount: 2))
        #expect(map.mic == .init(buffer: 0, offset: 0, stride: 2))
        #expect(map.tap == [.init(buffer: 1, offset: 0, stride: 2), .init(buffer: 1, offset: 1, stride: 2)])

        // With nothing left over for a microphone there is nothing to fall back to.
        #expect(AggregateChannelMap.tapAtEnd(bufferChannelCounts: [2], tapChannelCount: 2) == nil)
        #expect(AggregateChannelMap.tapAtEnd(bufferChannelCounts: [1, 2], tapChannelCount: 0) == nil)
    }

    // MARK: - The mix

    @Test("ch0 is the mean of the tap channels and ch1 is the microphone")
    func mixesTwoBuffers() throws {
        let map = try #require(
            AggregateChannelMap.resolve(bufferChannelCounts: [1, 2], micChannelCount: 1, tapChannelCount: 2)
        )
        // Three frames. Microphone: 7, 8, 9. Tap: (1, 3), (2, 6), (0, 0).
        let mic: [Float] = [7, 8, 9]
        let tap: [Float] = [1, 3, 2, 6, 0, 0]
        let mixed = map.mix(buffers: [mic, tap], frames: 3)
        #expect(mixed == [2, 7, 4, 8, 0, 9])
    }

    @Test("a single interleaved buffer mixes the same way")
    func mixesOneBuffer() throws {
        let map = try #require(
            AggregateChannelMap.resolve(bufferChannelCounts: [3], micChannelCount: 1, tapChannelCount: 2)
        )
        // Two frames of [mic, tapL, tapR].
        let interleaved: [Float] = [0.5, 1, 0, 0.25, -1, 1]
        let mixed = map.mix(buffers: [interleaved], frames: 2)
        #expect(mixed == [0.5, 0.5, 0, 0.25])
    }

    @Test("a stereo microphone contributes only its first channel")
    func micUsesChannelZeroOnly() throws {
        let map = try #require(
            AggregateChannelMap.resolve(bufferChannelCounts: [2, 2], micChannelCount: 2, tapChannelCount: 2)
        )
        // The microphone's second channel is a different capsule in the same room;
        // §3a's ch1 is one signal, not a mixdown of two.
        let mic: [Float] = [1, 99, 2, 99]
        let tap: [Float] = [4, 6, 8, 10]
        #expect(map.mix(buffers: [mic, tap], frames: 2) == [5, 1, 9, 2])
    }

    @Test("a four-channel tap is averaged, not just its first pair")
    func averagesEveryTapChannel() throws {
        let map = try #require(
            AggregateChannelMap.resolve(bufferChannelCounts: [1, 4], micChannelCount: 1, tapChannelCount: 4)
        )
        let mic: [Float] = [-1]
        let tap: [Float] = [1, 2, 3, 4]
        #expect(map.mix(buffers: [mic, tap], frames: 1) == [2.5, -1])
    }

    @Test("the log line names both channels")
    func logDescription() throws {
        let map = try #require(
            AggregateChannelMap.resolve(bufferChannelCounts: [1, 2], micChannelCount: 1, tapChannelCount: 2)
        )
        #expect(map.logDescription == "mic=b0c0/1 tap=b1c0/2,b1c1/2")
    }
}
