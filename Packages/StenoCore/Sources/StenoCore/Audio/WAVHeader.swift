import Foundation

/// A parsed RIFF/WAVE header, and the arithmetic needed to repair one.
///
/// A WAV file declares its own length twice — once in the RIFF chunk and once in the
/// `data` chunk — and both numbers are only written when the file is closed cleanly.
/// Kill the app mid-recording and the header still claims whatever it said when
/// recording started, usually zero, while the file on disk holds an hour of audio
/// that every reader then refuses to see. Both numbers are recomputable from the
/// file length, which is what makes an interrupted recording recoverable at all —
/// and the reason Steno records to WAV rather than into a container that cannot be
/// fixed after a crash.
public struct WAVHeader: Sendable, Hashable {
    /// The `fmt ` chunk.
    public struct Format: Sendable, Hashable {
        /// `1` for integer PCM, `3` for IEEE float, `0xFFFE` for WAVE_FORMAT_EXTENSIBLE.
        public var audioFormat: UInt16
        public var channelCount: UInt16
        public var sampleRate: UInt32
        public var byteRate: UInt32
        /// Bytes per frame, i.e. all channels of one sample.
        public var blockAlign: UInt16
        public var bitsPerSample: UInt16

        public init(
            audioFormat: UInt16,
            channelCount: UInt16,
            sampleRate: UInt32,
            byteRate: UInt32,
            blockAlign: UInt16,
            bitsPerSample: UInt16
        ) {
            self.audioFormat = audioFormat
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.byteRate = byteRate
            self.blockAlign = blockAlign
            self.bitsPerSample = bitsPerSample
        }

        public static let pcmFormat: UInt16 = 1
        public static let floatFormat: UInt16 = 3
        public static let extensibleFormat: UInt16 = 0xFFFE

        /// Bytes per frame, falling back to the value implied by channels and bit depth
        /// when the header's `blockAlign` is zero.
        public var effectiveBlockAlign: Int {
            if blockAlign > 0 { return Int(blockAlign) }
            return Int(channelCount) * (Int(bitsPerSample) / 8)
        }
    }

    public var format: Format
    /// The size the RIFF chunk declares — the file length minus the 8-byte RIFF header.
    public var declaredRIFFSize: UInt32
    /// The size the `data` chunk declares, in bytes of audio.
    public var declaredDataSize: UInt32
    /// Byte offset of the `data` chunk's 4-byte size field.
    public var dataSizeFieldOffset: Int
    /// Byte offset where audio data begins. Also the header's own length in bytes.
    public var dataOffset: Int
    /// The header bytes as read, from offset 0 up to `dataOffset`.
    public var bytes: [UInt8]

    /// Offset of the RIFF chunk's 4-byte size field. Always 4.
    public static let riffSizeFieldOffset = 4

    public var headerByteCount: Int { dataOffset }

    // MARK: - Errors

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case notRIFF([UInt8])
        case notWAVE([UInt8])
        case truncatedChunkHeader(atOffset: Int)
        case chunkExtendsBeyondHeader(id: String, atOffset: Int)
        case missingFormatChunk
        case missingDataChunk
        case formatChunkTooSmall(Int)

        public var description: String {
            switch self {
            case .tooShort(let n):
                return "not a WAV file: only \(n) bytes"
            case .notRIFF(let id):
                return "not a RIFF file: leading bytes are \(Self.ascii(id))"
            case .notWAVE(let id):
                return "not a WAVE file: RIFF form type is \(Self.ascii(id))"
            case .truncatedChunkHeader(let offset):
                return "chunk header at offset \(offset) is truncated"
            case .chunkExtendsBeyondHeader(let id, let offset):
                return "chunk \"\(id)\" at offset \(offset) extends past the data read"
            case .missingFormatChunk:
                return "no \"fmt \" chunk before the \"data\" chunk"
            case .missingDataChunk:
                return "no \"data\" chunk found"
            case .formatChunkTooSmall(let n):
                return "\"fmt \" chunk is \(n) bytes, needs at least 16"
            }
        }

        private static func ascii(_ bytes: [UInt8]) -> String {
            "\"" + String(decoding: bytes) + "\""
        }
    }

    // MARK: - Parsing

    /// The largest header this parser will walk through before giving up. Real headers
    /// are well under a kilobyte; anything larger is a malformed or hostile file.
    public static let maxHeaderByteCount = 64 * 1024

    /// Parses a header from the beginning of a WAV file.
    ///
    /// `data` need only be the file's leading bytes — the header plus nothing — so a
    /// recovery scan can read a few kilobytes rather than a gigabyte. Chunks appearing
    /// before `data` (`LIST`, `JUNK`, `fact`, the `fmt ` extension) are walked over.
    public static func parse(_ data: some Collection<UInt8>) throws -> WAVHeader {
        let bytes = Array(data.prefix(maxHeaderByteCount))
        guard bytes.count >= 12 else { throw ParseError.tooShort(bytes.count) }

        let riffID = Array(bytes[0..<4])
        guard riffID == Array("RIFF".utf8) else { throw ParseError.notRIFF(riffID) }
        let formType = Array(bytes[8..<12])
        guard formType == Array("WAVE".utf8) else { throw ParseError.notWAVE(formType) }

        let declaredRIFFSize = readUInt32(bytes, at: 4)

        var format: Format?
        var offset = 12

        while true {
            guard offset + 8 <= bytes.count else {
                throw ParseError.truncatedChunkHeader(atOffset: offset)
            }
            let id = String(decoding: bytes[offset..<(offset + 4)])
            let size = readUInt32(bytes, at: offset + 4)
            let payloadOffset = offset + 8

            if id == "data" {
                guard let format else { throw ParseError.missingFormatChunk }
                return WAVHeader(
                    format: format,
                    declaredRIFFSize: declaredRIFFSize,
                    declaredDataSize: size,
                    dataSizeFieldOffset: offset + 4,
                    dataOffset: payloadOffset,
                    bytes: Array(bytes[0..<payloadOffset])
                )
            }

            // Every other chunk has to be skipped over, so its payload must be present.
            let payloadSize = Int(size)
            guard payloadOffset + payloadSize <= bytes.count else {
                throw ParseError.chunkExtendsBeyondHeader(id: id, atOffset: offset)
            }

            if id == "fmt " {
                guard payloadSize >= 16 else { throw ParseError.formatChunkTooSmall(payloadSize) }
                format = Format(
                    audioFormat: readUInt16(bytes, at: payloadOffset),
                    channelCount: readUInt16(bytes, at: payloadOffset + 2),
                    sampleRate: readUInt32(bytes, at: payloadOffset + 4),
                    byteRate: readUInt32(bytes, at: payloadOffset + 8),
                    blockAlign: readUInt16(bytes, at: payloadOffset + 12),
                    bitsPerSample: readUInt16(bytes, at: payloadOffset + 14)
                )
            }

            // RIFF chunks are padded to an even length; the pad byte is not counted in size.
            offset += 8 + payloadSize + (payloadSize % 2)
            if offset >= bytes.count { throw ParseError.missingDataChunk }
        }
    }

    // MARK: - Validation

    public enum Problem: Sendable, Hashable, CustomStringConvertible {
        case riffSizeMismatch(declared: UInt32, expected: UInt32)
        case dataSizeMismatch(declared: UInt32, expected: UInt32)
        /// The declared data size does not end on a frame boundary, so the last frame
        /// is partial — what a write interrupted mid-frame leaves behind.
        case dataSizeNotFrameAligned(declared: UInt32, blockAlign: Int)

        public var description: String {
            switch self {
            case .riffSizeMismatch(let declared, let expected):
                return "RIFF size is \(declared), should be \(expected)"
            case .dataSizeMismatch(let declared, let expected):
                return "data size is \(declared), should be \(expected)"
            case .dataSizeNotFrameAligned(let declared, let align):
                return "data size \(declared) is not a multiple of the \(align)-byte frame"
            }
        }
    }

    public struct Validation: Sendable, Hashable {
        /// What the RIFF size field should say for this file length.
        public let expectedRIFFSize: UInt32
        /// What the `data` size field should say for this file length, rounded down to
        /// a whole frame.
        public let expectedDataSize: UInt32
        public let problems: [Problem]

        public var isValid: Bool { problems.isEmpty }
        public var needsRepair: Bool { !problems.isEmpty }
        /// Whole audio frames the file actually holds.
        public let frameCount: Int
        /// The recording's length in seconds, from the file length rather than the header.
        public let duration: TimeInterval
    }

    /// Compares the header's declared sizes against the actual file length.
    ///
    /// - Parameter fileSize: the file's length in bytes, from the file system.
    public func validate(fileSize: Int) -> Validation {
        let align = max(format.effectiveBlockAlign, 1)
        let available = max(fileSize - dataOffset, 0)
        let alignedDataSize = (available / align) * align
        let expectedDataSize = UInt32(clamping: alignedDataSize)
        let expectedRIFFSize = UInt32(clamping: max(dataOffset + alignedDataSize - 8, 0))

        var problems: [Problem] = []
        if declaredRIFFSize != expectedRIFFSize {
            problems.append(.riffSizeMismatch(declared: declaredRIFFSize, expected: expectedRIFFSize))
        }
        if declaredDataSize != expectedDataSize {
            problems.append(.dataSizeMismatch(declared: declaredDataSize, expected: expectedDataSize))
        }
        if format.effectiveBlockAlign > 0, declaredDataSize % UInt32(align) != 0 {
            problems.append(.dataSizeNotFrameAligned(declared: declaredDataSize, blockAlign: align))
        }

        let frameCount = alignedDataSize / align
        let duration = format.sampleRate > 0
            ? TimeInterval(frameCount) / TimeInterval(format.sampleRate)
            : 0

        return Validation(
            expectedRIFFSize: expectedRIFFSize,
            expectedDataSize: expectedDataSize,
            problems: problems,
            frameCount: frameCount,
            duration: duration
        )
    }

    // MARK: - Repair

    /// The header bytes with the RIFF and `data` sizes rewritten to match the file.
    ///
    /// The result has exactly `headerByteCount` bytes and is written back over the
    /// start of the file; the audio itself is never touched. A trailing partial frame
    /// is excluded by the size, not trimmed from the file.
    ///
    /// - Parameter fileSize: the file's length in bytes, from the file system.
    public func repairedHeader(fileSize: Int) -> [UInt8] {
        let validation = validate(fileSize: fileSize)
        var repaired = bytes
        write(UInt32: validation.expectedRIFFSize, into: &repaired, at: Self.riffSizeFieldOffset)
        write(UInt32: validation.expectedDataSize, into: &repaired, at: dataSizeFieldOffset)
        return repaired
    }

    /// The repaired header as `Data`, for writing at offset 0.
    public func repairedHeaderData(fileSize: Int) -> Data {
        Data(repairedHeader(fileSize: fileSize))
    }

    // MARK: - Byte helpers

    private func write(UInt32 value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        guard offset + 4 <= bytes.count else { return }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

extension String {
    /// Renders four ASCII chunk-ID bytes as a string, replacing anything unprintable.
    init(decoding bytes: some Collection<UInt8>) {
        self = String(bytes.map { byte in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        })
    }
}

// MARK: - Writing headers

extension WAVHeader {
    /// Builds a canonical 44-byte PCM WAV header.
    ///
    /// Used by the tests, and available to the app for writing a header by hand when
    /// reconstructing a file whose own header is beyond repair.
    public static func canonicalPCMHeader(
        channelCount: UInt16,
        sampleRate: UInt32,
        bitsPerSample: UInt16,
        dataSize: UInt32,
        riffSize: UInt32? = nil
    ) -> [UInt8] {
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44)

        func append(_ ascii: String) { bytes.append(contentsOf: Array(ascii.utf8)) }
        func append(_ value: UInt32) {
            bytes.append(contentsOf: [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 24)
            ])
        }
        func append(_ value: UInt16) {
            bytes.append(contentsOf: [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8)
            ])
        }

        append("RIFF")
        append(riffSize ?? (36 + dataSize))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(Format.pcmFormat)
        append(channelCount)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        append("data")
        append(dataSize)
        return bytes
    }
}
