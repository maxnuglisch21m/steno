import Foundation
import Testing

@testable import StenoCore

@Suite("WAVHeader")
struct WAVHeaderTests {
    // MARK: - Fixtures

    /// A 48 kHz 16-bit header, as `AVAudioFile` writes for a Steno recording.
    /// `onsite` is mono, `online` is two channels.
    static func header(
        channels: UInt16 = 1,
        sampleRate: UInt32 = 48_000,
        bits: UInt16 = 16,
        dataSize: UInt32,
        riffSize: UInt32? = nil
    ) -> [UInt8] {
        WAVHeader.canonicalPCMHeader(
            channelCount: channels,
            sampleRate: sampleRate,
            bitsPerSample: bits,
            dataSize: dataSize,
            riffSize: riffSize
        )
    }

    /// A whole file: header plus `audioBytes` of (zeroed) audio.
    static func file(
        channels: UInt16 = 1,
        dataSize: UInt32,
        riffSize: UInt32? = nil,
        audioBytes: Int
    ) -> [UInt8] {
        header(channels: channels, dataSize: dataSize, riffSize: riffSize)
            + [UInt8](repeating: 0, count: audioBytes)
    }

    /// Inserts a chunk before `data`, the way a `LIST` or `JUNK` chunk appears in the wild.
    static func headerWithExtraChunk(id: String, payload: [UInt8], dataSize: UInt32) -> [UInt8] {
        var bytes = header(dataSize: dataSize)
        let dataChunkStart = 36  // "data" begins after RIFF (12) + fmt (24)
        var chunk = Array(id.utf8)
        chunk += littleEndian(UInt32(payload.count))
        chunk += payload
        if payload.count % 2 == 1 { chunk.append(0) }  // RIFF pads to an even length
        bytes.insert(contentsOf: chunk, at: dataChunkStart)
        // The RIFF size grows with the inserted chunk.
        let riffSize = UInt32(bytes.count - 8) + dataSize
        bytes.replaceSubrange(4..<8, with: littleEndian(riffSize))
        return bytes
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - Parsing

    @Test("parses a canonical mono header")
    func parsesMono() throws {
        let parsed = try WAVHeader.parse(Self.header(dataSize: 96_000))
        #expect(parsed.format.audioFormat == WAVHeader.Format.pcmFormat)
        #expect(parsed.format.channelCount == 1)
        #expect(parsed.format.sampleRate == 48_000)
        #expect(parsed.format.bitsPerSample == 16)
        #expect(parsed.format.blockAlign == 2)
        #expect(parsed.format.byteRate == 96_000)
        #expect(parsed.declaredDataSize == 96_000)
        #expect(parsed.declaredRIFFSize == 96_036)
        #expect(parsed.dataOffset == 44)
        #expect(parsed.headerByteCount == 44)
        #expect(parsed.dataSizeFieldOffset == 40)
        #expect(WAVHeader.riffSizeFieldOffset == 4)
    }

    @Test("parses a two-channel header")
    func parsesStereo() throws {
        let parsed = try WAVHeader.parse(Self.header(channels: 2, dataSize: 192_000))
        #expect(parsed.format.channelCount == 2)
        #expect(parsed.format.blockAlign == 4)
        #expect(parsed.format.byteRate == 192_000)
        #expect(parsed.format.effectiveBlockAlign == 4)
    }

    @Test("walks over chunks that sit before the data chunk", arguments: ["LIST", "JUNK", "fact"])
    func skipsExtraChunks(id: String) throws {
        let bytes = Self.headerWithExtraChunk(
            id: id,
            payload: [UInt8](repeating: 0x41, count: 20),
            dataSize: 96_000
        )
        let parsed = try WAVHeader.parse(bytes)
        #expect(parsed.format.sampleRate == 48_000)
        #expect(parsed.declaredDataSize == 96_000)
        #expect(parsed.dataOffset == 44 + 8 + 20)
    }

    @Test("handles a chunk with an odd payload length and its pad byte")
    func skipsOddChunk() throws {
        let bytes = Self.headerWithExtraChunk(
            id: "JUNK",
            payload: [UInt8](repeating: 0x41, count: 7),
            dataSize: 100
        )
        let parsed = try WAVHeader.parse(bytes)
        #expect(parsed.declaredDataSize == 100)
        // 8-byte chunk header + 7 bytes + 1 pad byte.
        #expect(parsed.dataOffset == 44 + 16)
    }

    @Test("parses only the leading bytes it is given")
    func parsesFromPrefixOnly() throws {
        // A recovery scan reads a few kilobytes, not the whole gigabyte file.
        let whole = Self.file(dataSize: 0, audioBytes: 1_000_000)
        let parsed = try WAVHeader.parse(whole.prefix(4096))
        #expect(parsed.dataOffset == 44)
        #expect(parsed.bytes.count == 44)
    }

    @Test("accepts a header with a fmt extension")
    func parsesExtendedFormatChunk() throws {
        // A 40-byte fmt chunk, as WAVE_FORMAT_EXTENSIBLE uses.
        var bytes: [UInt8] = Array("RIFF".utf8)
        bytes += Self.littleEndian(0)
        bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8)
        bytes += Self.littleEndian(40)
        bytes += [0xFE, 0xFF]                        // WAVE_FORMAT_EXTENSIBLE
        bytes += [0x02, 0x00]                        // 2 channels
        bytes += Self.littleEndian(48_000)
        bytes += Self.littleEndian(192_000)
        bytes += [0x04, 0x00]                        // blockAlign
        bytes += [0x10, 0x00]                        // 16 bits
        bytes += [UInt8](repeating: 0, count: 24)    // extension payload
        bytes += Array("data".utf8)
        bytes += Self.littleEndian(0)

        let parsed = try WAVHeader.parse(bytes)
        #expect(parsed.format.audioFormat == WAVHeader.Format.extensibleFormat)
        #expect(parsed.format.channelCount == 2)
        #expect(parsed.dataOffset == 12 + 48 + 8)
    }

    @Test("falls back to channels and bit depth when blockAlign is zero")
    func effectiveBlockAlign() {
        let format = WAVHeader.Format(
            audioFormat: 1,
            channelCount: 2,
            sampleRate: 48_000,
            byteRate: 0,
            blockAlign: 0,
            bitsPerSample: 16
        )
        #expect(format.effectiveBlockAlign == 4)
    }

    // MARK: - Parse failures

    @Test("rejects what is not a WAV file")
    func rejectsNonWAV() {
        #expect(throws: WAVHeader.ParseError.tooShort(0)) { try WAVHeader.parse([UInt8]()) }
        #expect(throws: WAVHeader.ParseError.tooShort(4)) {
            try WAVHeader.parse(Array("RIFF".utf8))
        }
        #expect(throws: (any Error).self) {
            try WAVHeader.parse(Array("NOPEnopeNOPE".utf8))
        }
        // RIFF, but not a WAVE form.
        var avi = Self.header(dataSize: 0)
        avi.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        #expect(throws: (any Error).self) { try WAVHeader.parse(avi) }
    }

    @Test("rejects a header with no data chunk")
    func rejectsMissingDataChunk() {
        var bytes = Self.header(dataSize: 0)
        bytes.replaceSubrange(36..<40, with: Array("LIST".utf8))
        #expect(throws: (any Error).self) { try WAVHeader.parse(bytes) }
    }

    @Test("rejects a data chunk that arrives before the format chunk")
    func rejectsDataBeforeFormat() {
        var bytes: [UInt8] = Array("RIFF".utf8)
        bytes += Self.littleEndian(0)
        bytes += Array("WAVE".utf8)
        bytes += Array("data".utf8)
        bytes += Self.littleEndian(0)
        #expect(throws: WAVHeader.ParseError.missingFormatChunk) { try WAVHeader.parse(bytes) }
    }

    @Test("rejects a format chunk that is too small")
    func rejectsShortFormatChunk() {
        var bytes = Self.header(dataSize: 0)
        bytes.replaceSubrange(16..<20, with: Self.littleEndian(12))
        #expect(throws: (any Error).self) { try WAVHeader.parse(bytes) }
    }

    @Test("rejects a truncated chunk header")
    func rejectsTruncatedChunkHeader() {
        let bytes = Array(Self.header(dataSize: 0).prefix(38))
        #expect(throws: (any Error).self) { try WAVHeader.parse(bytes) }
    }

    @Test("every parse error explains itself")
    func errorDescriptions() {
        let errors: [WAVHeader.ParseError] = [
            .tooShort(3),
            .notRIFF(Array("nope".utf8)),
            .notWAVE(Array("AVI ".utf8)),
            .truncatedChunkHeader(atOffset: 36),
            .chunkExtendsBeyondHeader(id: "LIST", atOffset: 36),
            .missingFormatChunk,
            .missingDataChunk,
            .formatChunkTooSmall(12)
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(WAVHeader.ParseError.notRIFF(Array("nope".utf8)).description.contains("nope"))
    }

    // MARK: - Validation

    @Test("a cleanly closed file validates")
    func validFile() throws {
        let bytes = Self.file(dataSize: 96_000, audioBytes: 96_000)
        let parsed = try WAVHeader.parse(bytes)
        let validation = parsed.validate(fileSize: bytes.count)
        #expect(validation.isValid)
        #expect(!validation.needsRepair)
        #expect(validation.problems.isEmpty)
        #expect(validation.expectedDataSize == 96_000)
        #expect(validation.expectedRIFFSize == 96_036)
        #expect(validation.frameCount == 48_000)
        #expect(validation.duration == 1.0)
    }

    @Test("a header claiming zero bytes over a file full of audio is caught")
    func detectsCrashedRecording() throws {
        // Exactly what a kill during recording leaves: sizes never written back.
        let audioBytes = 5_760_000  // 60 s of 48 kHz 16-bit mono
        let bytes = Self.file(dataSize: 0, riffSize: 36, audioBytes: audioBytes)
        let parsed = try WAVHeader.parse(bytes)

        #expect(parsed.declaredDataSize == 0)
        let validation = parsed.validate(fileSize: bytes.count)
        #expect(validation.needsRepair)
        #expect(validation.expectedDataSize == UInt32(audioBytes))
        #expect(validation.expectedRIFFSize == UInt32(audioBytes + 36))
        #expect(validation.frameCount == 2_880_000)
        #expect(validation.duration == 60.0)
        #expect(
            validation.problems.contains(.dataSizeMismatch(declared: 0, expected: UInt32(audioBytes)))
        )
        #expect(validation.problems.contains(.riffSizeMismatch(declared: 36, expected: UInt32(audioBytes + 36))))
    }

    @Test(
        "computes the sizes a file of a given length should declare",
        arguments: [
            // (channels, audioBytes, expectedDataSize, expectedFrames)
            (UInt16(1), 96_000, UInt32(96_000), 48_000),
            (1, 0, 0, 0),
            (1, 2, 2, 1),
            // An odd trailing byte is a partial frame; the size excludes it.
            (1, 3, 2, 1),
            (2, 192_000, 192_000, 48_000),
            (2, 192_002, 192_000, 48_000),
            (2, 192_003, 192_000, 48_000),
            (2, 6, 4, 1)
        ]
    )
    func expectedSizes(
        channels: UInt16,
        audioBytes: Int,
        expectedDataSize: UInt32,
        expectedFrames: Int
    ) throws {
        let bytes = Self.file(channels: channels, dataSize: 0, audioBytes: audioBytes)
        let parsed = try WAVHeader.parse(bytes)
        let validation = parsed.validate(fileSize: bytes.count)
        #expect(validation.expectedDataSize == expectedDataSize)
        #expect(validation.frameCount == expectedFrames)
        #expect(validation.expectedRIFFSize == 36 + expectedDataSize)
    }

    @Test("flags a declared size that does not end on a frame boundary")
    func detectsPartialFrame() throws {
        // Two channels, so a frame is 4 bytes; 4002 cuts one in half.
        let bytes = Self.file(channels: 2, dataSize: 4002, audioBytes: 4002)
        let parsed = try WAVHeader.parse(bytes)
        let validation = parsed.validate(fileSize: bytes.count)
        #expect(validation.problems.contains(.dataSizeNotFrameAligned(declared: 4002, blockAlign: 4)))
        #expect(validation.expectedDataSize == 4000)
    }

    @Test("a header-only file reports no audio rather than a negative size")
    func headerOnlyFile() throws {
        let bytes = Self.header(dataSize: 0)
        let parsed = try WAVHeader.parse(bytes)
        let validation = parsed.validate(fileSize: bytes.count)
        #expect(validation.expectedDataSize == 0)
        #expect(validation.frameCount == 0)
        #expect(validation.duration == 0)
        #expect(validation.isValid)
    }

    @Test("a file shorter than its own header does not underflow")
    func fileShorterThanHeader() throws {
        let parsed = try WAVHeader.parse(Self.header(dataSize: 0))
        let validation = parsed.validate(fileSize: 10)
        #expect(validation.expectedDataSize == 0)
        #expect(validation.expectedRIFFSize == 36)
        #expect(validation.frameCount == 0)
    }

    @Test("every problem explains itself")
    func problemDescriptions() {
        let problems: [WAVHeader.Problem] = [
            .riffSizeMismatch(declared: 36, expected: 96_036),
            .dataSizeMismatch(declared: 0, expected: 96_000),
            .dataSizeNotFrameAligned(declared: 4002, blockAlign: 4)
        ]
        for problem in problems { #expect(!problem.description.isEmpty) }
    }

    // MARK: - Repair

    @Test("repairs the header of a crashed recording")
    func repairsCrashedRecording() throws {
        let audioBytes = 5_760_000
        let broken = Self.file(dataSize: 0, riffSize: 36, audioBytes: audioBytes)
        let parsed = try WAVHeader.parse(broken)

        let repaired = parsed.repairedHeader(fileSize: broken.count)
        #expect(repaired.count == parsed.headerByteCount)
        #expect(Self.uint32(repaired, at: 4) == UInt32(audioBytes + 36))
        #expect(Self.uint32(repaired, at: 40) == UInt32(audioBytes))

        // Writing it back over the start of the file makes the file valid.
        var fixed = broken
        fixed.replaceSubrange(0..<repaired.count, with: repaired)
        let reparsed = try WAVHeader.parse(fixed)
        #expect(reparsed.validate(fileSize: fixed.count).isValid)
        #expect(reparsed.validate(fileSize: fixed.count).duration == 60.0)
        // The audio itself is untouched.
        #expect(Array(fixed[repaired.count...]) == Array(broken[repaired.count...]))
    }

    @Test("a repaired header equals the one a clean close would have written")
    func repairMatchesCleanClose() throws {
        let audioBytes = 480_000
        let broken = Self.file(dataSize: 0, riffSize: 36, audioBytes: audioBytes)
        let repaired = try WAVHeader.parse(broken).repairedHeader(fileSize: broken.count)
        let expected = Self.header(dataSize: UInt32(audioBytes))
        #expect(repaired == expected)
    }

    @Test("repairing an already valid header changes nothing")
    func repairIsIdempotent() throws {
        let bytes = Self.file(dataSize: 96_000, audioBytes: 96_000)
        let parsed = try WAVHeader.parse(bytes)
        #expect(parsed.repairedHeader(fileSize: bytes.count) == parsed.bytes)

        // And repairing twice is the same as repairing once.
        let broken = Self.file(dataSize: 0, riffSize: 36, audioBytes: 96_000)
        var once = broken
        let firstPass = try WAVHeader.parse(once).repairedHeader(fileSize: once.count)
        once.replaceSubrange(0..<firstPass.count, with: firstPass)
        let secondPass = try WAVHeader.parse(once).repairedHeader(fileSize: once.count)
        #expect(firstPass == secondPass)
    }

    @Test("repair keeps a preceding chunk intact and fixes the right offsets")
    func repairWithExtraChunk() throws {
        let extra = Self.headerWithExtraChunk(
            id: "LIST",
            payload: [UInt8](repeating: 0x41, count: 26),
            dataSize: 0
        )
        let audioBytes = 48_000
        let broken = extra + [UInt8](repeating: 0, count: audioBytes)
        let parsed = try WAVHeader.parse(broken)
        #expect(parsed.dataOffset == 44 + 34)

        let repaired = parsed.repairedHeader(fileSize: broken.count)
        #expect(repaired.count == 78)
        #expect(Self.uint32(repaired, at: 4) == UInt32(broken.count - 8))
        #expect(Self.uint32(repaired, at: parsed.dataSizeFieldOffset) == UInt32(audioBytes))
        // The LIST payload survived.
        #expect(Array(repaired[44..<70]) == [UInt8](repeating: 0x41, count: 26))
    }

    @Test("a trailing partial frame is excluded by the size, not trimmed from the file")
    func repairExcludesPartialFrame() throws {
        let broken = Self.file(channels: 2, dataSize: 0, riffSize: 36, audioBytes: 4003)
        let parsed = try WAVHeader.parse(broken)
        let repaired = parsed.repairedHeader(fileSize: broken.count)
        #expect(Self.uint32(repaired, at: 40) == 4000)
        #expect(Self.uint32(repaired, at: 4) == 4036)
    }

    @Test("hands back the repaired header as Data too")
    func repairedHeaderData() throws {
        let broken = Self.file(dataSize: 0, riffSize: 36, audioBytes: 1024)
        let parsed = try WAVHeader.parse(broken)
        #expect(parsed.repairedHeaderData(fileSize: broken.count) == Data(parsed.repairedHeader(fileSize: broken.count)))
    }

    @Test("the canonical header it writes is one it can read back")
    func canonicalHeaderRoundTrip() throws {
        for (channels, bits) in [(UInt16(1), UInt16(16)), (2, 16), (1, 24), (2, 32)] {
            let bytes = WAVHeader.canonicalPCMHeader(
                channelCount: channels,
                sampleRate: 48_000,
                bitsPerSample: bits,
                dataSize: 4800
            )
            #expect(bytes.count == 44)
            let parsed = try WAVHeader.parse(bytes)
            #expect(parsed.format.channelCount == channels)
            #expect(parsed.format.bitsPerSample == bits)
            #expect(parsed.format.blockAlign == channels * (bits / 8))
            #expect(parsed.declaredDataSize == 4800)
        }
    }
}
