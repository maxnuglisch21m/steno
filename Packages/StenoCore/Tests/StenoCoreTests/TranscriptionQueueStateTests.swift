import Foundation
import Testing

@testable import StenoCore

@Suite("TranscriptionQueueState")
struct TranscriptionQueueStateTests {
    @Test("a folder is queued once, however often it is handed over")
    func enqueueIsIdempotent() {
        var queue = TranscriptionQueueState.empty
        #expect(queue.enqueue("/m/a") == true)
        #expect(queue.enqueue("/m/a") == false)
        #expect(queue.paths == ["/m/a"])
    }

    @Test("folders are worked through in the order they arrived")
    func fifo() {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/a")
        queue.enqueue("/m/b")
        queue.enqueue("/m/c")
        #expect(queue.head?.path == "/m/a")
        queue.remove("/m/a")
        #expect(queue.head?.path == "/m/b")
        #expect(queue.paths == ["/m/b", "/m/c"])
    }

    @Test("beginning the head counts an attempt")
    func countsAttempts() {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/a")
        #expect(queue.beginHead()?.attempts == 1)
        #expect(queue.beginHead()?.attempts == 2)
        #expect(queue.head?.attempts == 2)
    }

    @Test("a folder that has used up its attempts is dropped rather than retried forever")
    func givesUpAfterThreeAttempts() {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/a")
        for _ in 1...TranscriptionQueueState.maxAttempts {
            #expect(queue.beginHead() != nil)
        }
        // The fourth start is refused, and the entry is gone: the caller marks the
        // folder failed instead of relaunching into it again.
        #expect(queue.beginHead() == nil)
        #expect(queue.isEmpty)
    }

    @Test("beginning an empty queue answers nothing")
    func emptyQueueBegins() {
        var queue = TranscriptionQueueState.empty
        #expect(queue.beginHead() == nil)
    }

    @Test("a folder the user moved away is dropped")
    func dropsMissingFolders() {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/gone")
        queue.enqueue("/m/here")
        queue.removeMissing { $0 == "/m/here" }
        #expect(queue.paths == ["/m/here"])
    }

    @Test("the queue survives a round trip through JSON with its attempt counts")
    func codableRoundTrip() throws {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/a")
        queue.enqueue("/m/b")
        _ = queue.beginHead()

        let restored = try TranscriptionQueueState.decode(from: queue.jsonData())
        #expect(restored == queue)
        #expect(restored.head?.attempts == 1)
        #expect(restored.paths == ["/m/a", "/m/b"])
    }

    @Test("removing a folder that is not queued changes nothing")
    func removeUnknown() {
        var queue = TranscriptionQueueState.empty
        queue.enqueue("/m/a")
        #expect(queue.remove("/m/z") == false)
        #expect(queue.paths == ["/m/a"])
    }
}
