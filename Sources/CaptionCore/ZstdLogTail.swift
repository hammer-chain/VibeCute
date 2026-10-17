import Foundation
import ZstdBridge

/// Incrementally decodes concatenated Zstandard frames, including an unfinished live frame.
/// Neither repairs nor writes the source transcript.
public final class ZstdLogTail {
    public let url: URL
    public private(set) var didReset = false
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var decoder: UnsafeMutableRawPointer?
    private var compressed = Data()
    private var pending = Data()
    private var discardUntilNewline = false
    private var draining = false
    private var failed = false

    public init(url: URL) { self.url = url }
    deinit { caption_zstd_free(decoder) }

    private func reset() throws {
        caption_zstd_free(decoder); decoder = nil
        let paths = [Bundle.main.privateFrameworksPath.map { $0 + "/libzstd.dylib" },
                     "/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib"]
        for path in paths.compactMap({ $0 }) {
            decoder = path.withCString { caption_zstd_create($0) }
            if decoder != nil { break }
        }
        guard decoder != nil else { throw NSError(domain: "字幕 Zstandard 解码器不可用", code: 1) }
        offset = 0; compressed.removeAll(); pending.removeAll()
        discardUntilNewline = false; draining = false; failed = false
    }

    public func read() throws -> [Data] {
        didReset = false
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let newInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if decoder == nil || (inode != nil && inode != newInode) || size < offset {
            didReset = decoder != nil
            try reset()
        }
        inode = newInode
        guard !failed else { throw NSError(domain: "会话压缩日志损坏", code: 2) }
        if compressed.isEmpty && !draining {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 262_144) ?? Data()
            offset += UInt64(data.count); compressed.append(data)
        }
        var lines: [Data] = []
        var decodedBytes = 0
        while !compressed.isEmpty || draining {
            var output = Data(count: 65_536)
            var consumed = 0, written = 0
            let capacity = output.count
            let result = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { out in
                    caption_zstd_decode(decoder, input.baseAddress, input.count, &consumed,
                                        out.baseAddress, capacity, &written)
                }
            }
            if result < 0 { failed = true; throw NSError(domain: "会话压缩日志损坏", code: 2) }
            compressed.removeFirst(consumed)
            draining = written == capacity
            pending.append(output.prefix(written)); decodedBytes += written
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if discardUntilNewline { discardUntilNewline = false }
                else if !line.isEmpty { lines.append(line) }
            }
            if pending.count > 4_000_000 { pending.removeAll(); discardUntilNewline = true }
            if decodedBytes >= 2_000_000 || (consumed == 0 && written == 0) { break }
        }
        return lines
    }
}
