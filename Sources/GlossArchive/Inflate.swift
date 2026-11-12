import CZlib
import Foundation

public enum CompressionError: Error, Equatable, Sendable {
    case corrupt
    case tooLarge
}

/// DEFLATE decoding and encoding over zlib, written to always terminate: truncated or corrupt
/// input yields an error (or, when allowed, whatever was decoded) instead of looping.
public enum Inflate {
    /// Refuse to inflate beyond this many bytes (zip-bomb guard).
    public static let defaultLimit = 1 << 30

    /// Raw DEFLATE (ZIP entries).
    public static func raw(_ data: Data, sizeHint: Int? = nil, limit: Int = defaultLimit, allowTruncated: Bool = false) throws -> Data {
        try inflate(data, windowBits: -MAX_WBITS, sizeHint: sizeHint, limit: limit, allowTruncated: allowTruncated)
    }

    /// zlib-wrapped DEFLATE (PDF `FlateDecode`). Falls back to raw DEFLATE when the zlib header
    /// is missing, which real-world PDFs do surprisingly often.
    public static func zlib(_ data: Data, limit: Int = defaultLimit, allowTruncated: Bool = true) throws -> Data {
        do {
            return try inflate(data, windowBits: MAX_WBITS, sizeHint: nil, limit: limit, allowTruncated: allowTruncated)
        } catch CompressionError.corrupt {
            return try inflate(data, windowBits: -MAX_WBITS, sizeHint: nil, limit: limit, allowTruncated: allowTruncated)
        }
    }

    private static func inflate(_ data: Data, windowBits: Int32, sizeHint: Int?, limit: Int, allowTruncated: Bool) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CompressionError.corrupt }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = max(16 * 1024, min(sizeHint ?? data.count * 4, 4 << 20))
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        let inputCount = input.count
        var finished = false
        try input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = UInt32(inputCount)
            while true {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(chunk)
                    let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    if status == Z_STREAM_END { finished = true }
                    if status == Z_DATA_ERROR || status == Z_NEED_DICT || status == Z_MEM_ERROR { return -1 }
                    return chunk - Int(stream.avail_out)
                }
                if produced < 0 {
                    if allowTruncated, !output.isEmpty { return }
                    throw CompressionError.corrupt
                }
                output.append(contentsOf: buffer[0..<produced])
                if output.count > limit { throw CompressionError.tooLarge }
                if finished { return }
                // No input left and no progress: the stream is truncated.
                if produced == 0 && stream.avail_in == 0 {
                    if allowTruncated { return }
                    throw CompressionError.corrupt
                }
                if produced == 0 && stream.avail_out != 0 && stream.avail_in > 0 {
                    // zlib made no progress with input available; give up rather than spin.
                    if allowTruncated { return }
                    throw CompressionError.corrupt
                }
            }
        }
        return output
    }
}

public enum Deflate {
    /// Raw DEFLATE, for writing ZIP entries (tests and future exporters).
    public static func raw(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        try deflate(data, windowBits: -MAX_WBITS, level: level)
    }

    /// zlib-wrapped DEFLATE.
    public static func zlib(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        try deflate(data, windowBits: MAX_WBITS, level: level)
    }

    private static func deflate(_ data: Data, windowBits: Int32, level: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CompressionError.corrupt
        }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        let inputCount = input.count
        let capacity = Int(deflateBound(&stream, UInt(inputCount))) + 64
        var buffer = [UInt8](repeating: 0, count: capacity)
        let status: Int32 = input.withUnsafeMutableBufferPointer { inputBuffer in
            buffer.withUnsafeMutableBufferPointer { out in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = UInt32(inputCount)
                stream.next_out = out.baseAddress
                stream.avail_out = UInt32(capacity)
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw CompressionError.corrupt }
        return Data(buffer[0..<Int(stream.total_out)])
    }
}
