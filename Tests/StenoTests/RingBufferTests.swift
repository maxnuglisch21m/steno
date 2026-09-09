import Foundation
import Testing

@testable import Steno

/// The ring buffer between the Core Audio callback and the WAV writer.
///
/// Everything here is about the two properties the recording depends on: frames come
/// out exactly as they went in, including across the wrap, and an overrun costs frames
/// but never correctness — no partial frames, no interleaving that slips by one, no
/// silent loss.
@Suite("AudioRingBuffer")
struct RingBufferTests {
    /// `frames` interleaved stereo frames whose samples are `start`, `start + 1`, …
    private static func ramp(frames: Int, start: Int = 0, channels: Int = 2) -> [Float] {
        (0..<(frames * channels)).map { Float(start * channels + $0) }
    }

    @Test("what goes in comes out, frame for frame")
    func roundTrip() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 16)
        let input = Self.ramp(frames: 5)
        #expect(ring.write(input) == 5)
        #expect(ring.availableFrames == 5)
        #expect(ring.read(maxFrames: 5) == input)
        #expect(ring.availableFrames == 0)
        #expect(ring.droppedFrames == 0)
    }

    @Test("reading an empty ring returns nothing rather than zeros")
    func emptyRead() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 8)
        #expect(ring.read(maxFrames: 4).isEmpty)
        #expect(ring.availableFrames == 0)
    }

    @Test("a read asking for more than is there takes what is there")
    func partialRead() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 8)
        ring.write(Self.ramp(frames: 3))
        let read = ring.read(maxFrames: 100)
        #expect(read.count == 6)
        #expect(read == Self.ramp(frames: 3))
    }

    @Test("frames survive the wrap around the end of the storage")
    func wrapAround() {
        // Capacity 4 frames, written in threes: the second write starts at frame 3 and
        // continues at frame 0, which is the case the two `memcpy`s exist for.
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 4)
        #expect(ring.write(Self.ramp(frames: 3, start: 0)) == 3)
        #expect(ring.read(maxFrames: 3) == Self.ramp(frames: 3, start: 0))

        #expect(ring.write(Self.ramp(frames: 3, start: 3)) == 3)
        #expect(ring.read(maxFrames: 3) == Self.ramp(frames: 3, start: 3))

        // And once more, so the cursors have wrapped the storage twice.
        #expect(ring.write(Self.ramp(frames: 4, start: 6)) == 4)
        #expect(ring.read(maxFrames: 4) == Self.ramp(frames: 4, start: 6))
        #expect(ring.droppedFrames == 0)
    }

    @Test("the whole capacity is usable, not capacity minus one")
    func fullCapacity() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 4)
        #expect(ring.write(Self.ramp(frames: 4)) == 4)
        #expect(ring.availableFrames == 4)
        #expect(ring.droppedFrames == 0)
        #expect(ring.read(maxFrames: 4).count == 8)
    }

    @Test("an overrun drops the frames that do not fit, and counts them")
    func overrunCounting() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 2)
        #expect(ring.write(Self.ramp(frames: 5)) == 2)
        #expect(ring.droppedFrames == 3)
        // What was accepted is the *front* of the block, undamaged: a drop shortens
        // the recording, it does not corrupt it.
        #expect(ring.read(maxFrames: 2) == Self.ramp(frames: 2))

        // Writing into a ring that is still full drops everything and adds up.
        ring.write(Self.ramp(frames: 2))
        #expect(ring.write(Self.ramp(frames: 4)) == 0)
        #expect(ring.droppedFrames == 7)
    }

    @Test("interleaving is preserved: channel 0 and channel 1 never swap")
    func interleavedIntegrity() {
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: 3)
        // ch0 negative, ch1 positive, so a slip of one sample is unmissable.
        let input: [Float] = [-1, 1, -2, 2, -3, 3]
        ring.write(input)
        let read = ring.read(maxFrames: 3)
        #expect(read == input)
        for frame in 0..<3 {
            #expect(read[frame * 2] < 0)
            #expect(read[frame * 2 + 1] > 0)
        }
    }

    @Test("a producer and a consumer on different threads lose nothing")
    func concurrentSmokeTest() async {
        // Half a second of stereo at 48 kHz, written in callback-sized blocks on one
        // thread and drained on another. The ring is deliberately large enough to hold
        // all of it, so that the outcome cannot depend on how the two threads happen to
        // be scheduled: what is under test here is the memory ordering, and any drop
        // would be the test's own doing rather than the ring's.
        let totalFrames = 24_000
        let chunk = 512
        let ring = AudioRingBuffer(channelCount: 2, capacityFrames: totalFrames + chunk)

        let producer = Task.detached(priority: .userInitiated) {
            var written = 0
            while written < totalFrames {
                let size = min(chunk, totalFrames - written)
                let block = Self.ramp(frames: size, start: written)
                _ = block.withUnsafeBufferPointer { buffer in
                    ring.write(buffer.baseAddress!, frames: size)
                }
                written += size
            }
        }

        var received: [Float] = []
        received.reserveCapacity(totalFrames * 2)
        while received.count < totalFrames * 2 {
            let block = ring.read(maxFrames: 1024)
            if block.isEmpty {
                await Task.yield()
            } else {
                received.append(contentsOf: block)
            }
        }
        await producer.value

        #expect(received.count == totalFrames * 2)
        #expect(ring.droppedFrames == 0)
        // A single mismatch would mean a frame went missing or arrived twice.
        let expected = Self.ramp(frames: totalFrames)
        #expect(received == expected)
    }
}
