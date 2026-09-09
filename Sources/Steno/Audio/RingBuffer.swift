import Foundation
import Synchronization

/// A lock-free single-producer / single-consumer ring of interleaved `Float32` frames.
///
/// This exists for exactly one reason: the Core Audio IOProc that `ProcessTapRecorder`
/// installs runs under a real-time deadline, and everything the obvious implementation
/// would do there — allocate a buffer, take a lock, write a log line, hop onto an
/// actor — can block for longer than the deadline and cost the recording a glitch. So
/// the IOProc does the one thing that cannot block: it copies its frames into memory
/// that was allocated before the recording started, and moves an index.
///
/// The rules that make that safe, and the reason there is no lock anywhere:
///
/// - **Exactly one producer and exactly one consumer.** The producer is the IOProc,
///   the consumer is the drain timer. Neither index is ever written by both.
/// - **Monotonic cursors.** `writeCursor` and `readCursor` count frames since the
///   start and are never wrapped; only the offset into the storage is taken modulo
///   the capacity. That is what makes "full" and "empty" distinguishable without a
///   third variable, and it is why a capacity of exactly `capacityFrames` is usable
///   rather than `capacityFrames - 1`.
/// - **Acquire/release pairs.** The producer publishes its samples by storing the new
///   write cursor with release ordering, and the consumer sees them by loading that
///   cursor with acquire ordering. The reverse pair frees the space again. Nothing
///   else is synchronized, and nothing else needs to be.
///
/// When the consumer falls behind — a stalled disk, a suspended process — the producer
/// drops the frames that do not fit rather than blocking or growing: an overrun is a
/// short gap in the recording, and blocking the audio thread would be a long one. The
/// dropped frames are counted, reported in the log at the end of every recording, and
/// expected to be zero.
final class AudioRingBuffer: @unchecked Sendable {
    /// Interleaved channels per frame. Two, in the only use there is.
    let channelCount: Int
    /// How many frames fit before the producer starts dropping.
    let capacityFrames: Int

    /// The frames. Allocated once, in `init`, and never resized.
    private let storage: UnsafeMutablePointer<Float>
    private let sampleCapacity: Int

    /// Frames ever accepted. Written by the producer only.
    private let writeCursor = Atomic<Int>(0)
    /// Frames ever handed to the consumer. Written by the consumer only.
    private let readCursor = Atomic<Int>(0)
    /// Frames the producer had to throw away. Written by the producer only.
    private let dropped = Atomic<Int>(0)

    /// - Parameters:
    ///   - channelCount: interleaved channels per frame.
    ///   - capacityFrames: how much audio the ring holds. `ProcessTapRecorder` uses
    ///     four seconds, which is two orders of magnitude more than the drain interval
    ///     and still under 1.5 MB.
    init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0 && capacityFrames > 0)
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.sampleCapacity = channelCount * capacityFrames
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        self.storage.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        storage.deinitialize(count: sampleCapacity)
        storage.deallocate()
    }

    // MARK: - Counters

    /// Frames written but not yet read.
    var availableFrames: Int {
        let write = writeCursor.load(ordering: .acquiring)
        let read = readCursor.load(ordering: .acquiring)
        return write - read
    }

    /// Frames the producer had to drop because the ring was full. Zero is the
    /// expected value; anything else goes into the log and the recording's report.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Frames accepted since the start.
    var writtenFrames: Int { writeCursor.load(ordering: .relaxed) }

    // MARK: - Producer

    /// Copies `frames` interleaved frames in. Real-time safe: no allocation, no locks,
    /// no ARC traffic, two `memcpy`s at most.
    ///
    /// Returns how many frames were accepted. Anything short of `frames` has been
    /// counted as dropped.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let write = writeCursor.load(ordering: .relaxed)
        let read = readCursor.load(ordering: .acquiring)
        let free = capacityFrames - (write - read)
        let accepted = min(frames, max(0, free))
        if accepted < frames {
            dropped.wrappingAdd(frames - accepted, ordering: .relaxed)
        }
        guard accepted > 0 else { return 0 }

        let offset = write % capacityFrames
        let firstRun = min(accepted, capacityFrames - offset)
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        memcpy(storage + offset * channelCount, source, firstRun * bytesPerFrame)
        if accepted > firstRun {
            memcpy(storage, source + firstRun * channelCount, (accepted - firstRun) * bytesPerFrame)
        }
        // Release: everything written above is visible to whoever acquires this value.
        writeCursor.store(write + accepted, ordering: .releasing)
        return accepted
    }

    // MARK: - Consumer

    /// Copies out at most `frames` frames and frees the space. Returns how many.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let read = readCursor.load(ordering: .relaxed)
        // Acquire: pairs with the producer's release, so the samples below are visible.
        let write = writeCursor.load(ordering: .acquiring)
        let taken = min(frames, write - read)
        guard taken > 0 else { return 0 }

        let offset = read % capacityFrames
        let firstRun = min(taken, capacityFrames - offset)
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        memcpy(destination, storage + offset * channelCount, firstRun * bytesPerFrame)
        if taken > firstRun {
            memcpy(destination + firstRun * channelCount, storage, (taken - firstRun) * bytesPerFrame)
        }
        readCursor.store(read + taken, ordering: .releasing)
        return taken
    }

    // MARK: - Array conveniences

    /// Array-shaped `write`, for the tests. Not used on the audio thread: an array
    /// argument means a retain and a bounds check the IOProc has no time for.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        precondition(samples.count % channelCount == 0, "a partial frame cannot be written")
        return samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return write(base, frames: buffer.count / channelCount)
        }
    }

    /// Array-shaped `read`, for the tests. Returns the interleaved samples actually
    /// available, up to `maxFrames`.
    func read(maxFrames: Int) -> [Float] {
        guard maxFrames > 0 else { return [] }
        var output = [Float](repeating: 0, count: maxFrames * channelCount)
        let taken = output.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return read(into: base, frames: maxFrames)
        }
        output.removeLast((maxFrames - taken) * channelCount)
        return output
    }
}
