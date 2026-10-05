import Compression
import Foundation

/// Reads single entries of a ZIP archive, enough to get the preview PDF out of
/// a single-file iWork document. Supports stored and deflated entries; ZIP64,
/// encrypted entries and multi-disk archives are not supported (such entries
/// are left out). Reads only the directory and the requested entry.
struct ZipArchive {
    struct Entry: Sendable, Hashable {
        var name: String
        var method: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    enum Failure: Error, Sendable, Hashable {
        case unreadable
        case tooLarge
        case unsupported
    }

    static let maxDirectorySize = 16_000_000
    static let maxEntries = 100_000

    let url: URL
    let entries: [Entry]
    /// Whether `entries` are everything the directory lists: no entry was left
    /// out (ZIP64, encrypted) and the entries fill the directory exactly.
    let isComplete: Bool

    /// nil when the file is not a readable ZIP archive.
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let directory = try? Self.readDirectory(handle) else { return nil }
        self.url = url
        self.entries = directory.entries
        self.isComplete = directory.isComplete
    }

    /// The uncompressed sizes of all entries, as the directory declares them.
    var totalUncompressedSize: UInt64 {
        entries.reduce(0) { $0 + $1.uncompressedSize }
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The uncompressed contents of `entry`; throws `tooLarge` beyond `maxSize` bytes.
    func data(of entry: Entry, maxSize: UInt64) throws -> Data {
        guard entry.uncompressedSize <= maxSize, entry.compressedSize <= maxSize else { throw Failure.tooLarge }
        guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupported }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.uint32(at: 0) == 0x0403_4B50 else { throw Failure.unreadable }
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        try handle.seek(toOffset: dataOffset)
        guard let compressed = try handle.read(upToCount: Int(entry.compressedSize)),
              compressed.count == Int(entry.compressedSize) else { throw Failure.unreadable }

        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else { throw Failure.unreadable }
            return compressed
        }
        return try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
    }

    // MARK: Parsing

    private static func readDirectory(_ handle: FileHandle) throws -> (entries: [Entry], isComplete: Bool) {
        let fileSize = try handle.seekToEnd()
        // End of central directory: 22 bytes plus a comment of up to 65,535 bytes.
        let tailSize = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22 else { throw Failure.unreadable }
        var position = tail.count - 22
        while position >= 0, tail.uint32(at: position) != 0x0605_4B50 {
            position -= 1
        }
        guard position >= 0 else { throw Failure.unreadable }
        guard tail.uint16(at: position + 4) == 0, tail.uint16(at: position + 6) == 0 else { throw Failure.unsupported }
        let count = Int(tail.uint16(at: position + 10))
        let directorySize = UInt64(tail.uint32(at: position + 12))
        let directoryOffset = UInt64(tail.uint32(at: position + 16))
        guard count <= maxEntries, directorySize <= maxDirectorySize,
              directoryOffset + directorySize <= fileSize else { throw Failure.unsupported }

        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.read(upToCount: Int(directorySize)),
              directory.count == Int(directorySize) else { throw Failure.unreadable }

        var entries: [Entry] = []
        var offset = 0
        for _ in 0..<count {
            guard offset + 46 <= directory.count, directory.uint32(at: offset) == 0x0201_4B50 else {
                throw Failure.unreadable
            }
            let flags = directory.uint16(at: offset + 8)
            let method = directory.uint16(at: offset + 10)
            let compressedSize = directory.uint32(at: offset + 20)
            let uncompressedSize = directory.uint32(at: offset + 24)
            let nameLength = Int(directory.uint16(at: offset + 28))
            let extraLength = Int(directory.uint16(at: offset + 30))
            let commentLength = Int(directory.uint16(at: offset + 32))
            let localHeaderOffset = directory.uint32(at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength <= directory.count else { throw Failure.unreadable }
            let nameData = directory.subdata(in: nameStart..<nameStart + nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            let isZip64 = [compressedSize, uncompressedSize, localHeaderOffset].contains(0xFFFF_FFFF)
            let isEncrypted = flags & 0x1 != 0
            if !isZip64, !isEncrypted {
                entries.append(Entry(name: name, method: method, compressedSize: UInt64(compressedSize),
                                     uncompressedSize: UInt64(uncompressedSize),
                                     localHeaderOffset: UInt64(localHeaderOffset)))
            }
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return (entries, entries.count == count && offset == directory.count)
    }

    /// Raw DEFLATE (RFC 1951), which is what `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, expectedSize, sourceBase, data.count, nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Failure.unreadable }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8 | UInt32(self[start + 2]) << 16
            | UInt32(self[start + 3]) << 24
    }
}
