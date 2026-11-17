import Foundation
import CryptoKit
import Darwin

struct GroupPackedEntry {
    let entry: GroupEntry
    let crc: UInt32
    let snapshot: URL?
}
private struct ZIPEntry {
    let name: Data
    let path: String
    let directory: Bool
    let crc: UInt32
    let size: UInt32
    let offset: UInt32
    let needed: UInt16
    let time: UInt16
    let date: UInt16
}

/// STORE子集严格扫描：先验证central范围，再按offset验证连续local布局，正文逐块CRC/hash。
enum GroupZIP {
    static func write(_ entries: [GroupPackedEntry], to url: URL, cancellation: WorkCancellation) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.io }; defer { close(fd) }
        var position: UInt32 = 0; var records: [Data] = []; var metadata = 22
        func output(_ data: Data) throws {
            guard Int64(position) + Int64(data.count) <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_SIZE", message: "文件组ZIP容器超过128MiB") }
            try writeBlock(fd, data); position += UInt32(data.count)
        }
        for item in entries.sorted(by: { utf8Less($0.entry.path, $1.entry.path) }) {
            try cancellation.check()
            let entry = item.entry, name = Data(entry.path.utf8), offset = position
            let size = UInt32(entry.size)
            var local = Data(); local.le32(0x04034b50); local.le16(20); local.le16(0x800); local.le16(0)
            local.le16(0); local.le16(33); local.le32(item.crc); local.le32(size); local.le32(size)
            local.le16(UInt16(name.count)); local.le16(0); local.append(name)
            try output(local)
            if !entry.isDirectory {
                guard let source = item.snapshot else { throw FileFailure.io }
                let input = try openRegular(source); defer { close(input) }
                var remaining = entry.size; var crc = CRC32(); var hash = SHA256()
                while remaining > 0 {
                    try cancellation.check()
                    let block = try readBlock(input, limit: Int(min(65_536, remaining)))
                    guard !block.isEmpty else { throw FileFailure.io }
                    remaining -= Int64(block.count); crc.update(block); hash.update(data: block); try output(block)
                }
                guard try readBlock(input, limit: 1).isEmpty, crc.checksum == item.crc,
                      hex(Data(hash.finalize())) == entry.sha256 else { throw FileFailure(code: "FILE_HASH", message: "文件组稳定副本发生变化") }
            }
            var central = Data(); central.le32(0x02014b50); central.le16((3 << 8) | 20); central.le16(20)
            central.le16(0x800); central.le16(0); central.le16(0); central.le16(33); central.le32(item.crc)
            central.le32(size); central.le32(size); central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(entry.isDirectory ? (UInt32(0o40700) << 16) | 0x10 : UInt32(0o100600) << 16)
            central.le32(offset); central.append(name); records.append(central)
            metadata += local.count + central.count
            guard metadata <= GROUP_MAX_METADATA else { throw groupInvalid("ZIP元信息超过2MiB") }
        }
        let centralOffset = position
        for record in records { try output(record) }
        let centralSize = position - centralOffset
        var end = Data(); end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(centralSize); end.le32(centralOffset); end.le16(0); try output(end)
        guard fsync(fd) == 0, fchmod(fd, 0o400) == 0 else { throw FileFailure.io }
    }
    static func scan(_ url: URL, expected: GroupMetadata, extractInto tree: URL? = nil, cancellation: WorkCancellation) throws -> GroupMetadata {
        try cancellation.check()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw FileFailure.io }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw FileFailure.io }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 22, info.st_size <= FILE_MAX_SIZE else { throw groupInvalid("ZIP容器大小无效") }
        let fileSize = Int64(info.st_size)
        func bytes(_ at: Int64, _ count: Int) throws -> Data {
            guard at >= 0, count >= 0, count <= GROUP_MAX_METADATA, at <= fileSize, Int64(count) <= fileSize - at else { throw groupInvalid("ZIP偏移或长度越界") }
            var result = Data(count: count)
            try result.withUnsafeMutableBytes { buffer in
                var done = 0
                while done < count {
                    let n = pread(fd, buffer.baseAddress!.advanced(by: done), count - done, off_t(at + Int64(done)))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { if n < 0 { throw FileFailure.io }; throw groupInvalid("ZIP记录截断") }; done += n
                }
            }
            return result
        }
        let end = try bytes(fileSize - 22, 22)
        guard end.u32(0) == 0x06054b50, end.u16(4) == 0, end.u16(6) == 0, end.u16(8) == end.u16(10),
              (1...GROUP_MAX_ENTRIES).contains(Int(end.u16(10))), end.u16(20) == 0 else { throw groupInvalid("ZIP结尾或分卷信息无效") }
        let count = Int(end.u16(10)), centralSize = Int64(end.u32(12)), centralStart = Int64(end.u32(16))
        guard centralSize <= GROUP_MAX_METADATA, centralStart + centralSize == fileSize - 22 else { throw groupInvalid("ZIP中央目录范围或尾随数据无效") }
        var position = centralStart; var records: [ZIPEntry] = []; var metadataBytes = 22
        for _ in 0..<count {
            try cancellation.check()
            let header = try bytes(position, 46)
            let needed = header.u16(6), nameLength = Int(header.u16(28)), mode = header.u32(38) >> 16, low = header.u32(38) & 0xffff
            guard header.u32(0) == 0x02014b50, header.u16(4) >> 8 == 3, [10, 20].contains(needed),
                  header.u16(8) == 0x800, header.u16(10) == 0, validDOS(time: header.u16(12), date: header.u16(14)),
                  header.u32(20) == header.u32(24), header.u32(24) <= UInt32(FILE_MAX_SIZE),
                  (1...1024).contains(nameLength), header.u16(30) == 0, header.u16(32) == 0, header.u16(34) == 0, header.u16(36) == 0,
                  position + 46 + Int64(nameLength) <= centralStart + centralSize else { throw groupInvalid("ZIP中央记录标记、类型或长度无效") }
            let name = try bytes(position + 46, nameLength)
            guard let path = String(data: name, encoding: .utf8), Data(path.utf8) == name else { throw groupInvalid("ZIP名称不是合法UTF8") }
            let directory = path.hasSuffix("/")
            _ = try groupPath(path, directory: directory)
            guard (mode & 0xf000) == (directory ? 0x4000 : 0x8000), directory ? (low == 0 || low == 0x10) : low == 0 else { throw groupInvalid("ZIP条目不是普通文件或目录") }
            if directory { guard header.u32(16) == 0, header.u32(24) == 0 else { throw groupInvalid("目录ZIP条目含内容") } }
            records.append(ZIPEntry(name: name, path: path, directory: directory, crc: header.u32(16), size: header.u32(24), offset: header.u32(42), needed: needed, time: header.u16(12), date: header.u16(14)))
            position += 46 + Int64(nameLength); metadataBytes += 46 + nameLength
        }
        guard position == centralStart + centralSize else { throw groupInvalid("ZIP中央目录长度不一致") }
        _ = try validateGroupLayout(records.map { GroupLayoutItem(path: $0.path, directory: $0.directory, size: Int64($0.size)) }, expected: expected)
        let ordered = records
        var cursor: Int64 = 0; var verified: [GroupEntry] = []; var lastName: Data?
        for record in ordered {
            try cancellation.check()
            guard Int64(record.offset) == cursor, lastName == nil || lastName!.lexicographicallyPrecedes(record.name) else { throw groupInvalid("ZIP本地布局不连续或名称顺序错误") }
            lastName = record.name
            let local = try bytes(cursor, 30)
            guard local.u32(0) == 0x04034b50, local.u16(4) == record.needed, local.u16(6) == 0x800, local.u16(8) == 0,
                  local.u16(10) == record.time, local.u16(12) == record.date, local.u32(14) == record.crc,
                  local.u32(18) == record.size, local.u32(22) == record.size, Int(local.u16(26)) == record.name.count, local.u16(28) == 0,
                  try bytes(cursor + 30, record.name.count) == record.name else { throw groupInvalid("ZIP本地头与中央记录不一致") }
            let dataStart = cursor + 30 + Int64(record.name.count), dataEnd = dataStart + Int64(record.size)
            guard dataEnd <= centralStart else { throw groupInvalid("ZIP数据越界或重叠") }
            metadataBytes += 30 + record.name.count
            guard metadataBytes <= GROUP_MAX_METADATA else { throw groupInvalid("ZIP元信息超过2MiB") }
            var output: Int32 = -1
            if let tree {
                let parts = try groupPath(record.path, directory: record.directory)
                let destination = parts.reduce(tree) { $0.appendingPathComponent($1) }
                if record.directory {
                    guard mkdir(destination.path, 0o700) == 0 else {
                        if errno == EEXIST { throw groupInvalid("文件系统目录名称冲突") }
                        throw FileFailure.io
                    }
                } else {
                    output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard output >= 0 else { if errno == EEXIST { throw groupInvalid("文件系统文件名称冲突") }; throw FileFailure.io }
                }
            }
            defer { if output >= 0 { close(output) } }
            var offset = dataStart; var crc = CRC32(); var hash = SHA256()
            while offset < dataEnd {
                try cancellation.check()
                let block = try bytes(offset, Int(min(65_536, dataEnd - offset)))
                crc.update(block); hash.update(data: block)
                if output >= 0 { try writeBlock(output, block) }
                offset += Int64(block.count)
            }
            guard crc.checksum == record.crc else { throw FileFailure(code: "FILE_HASH", message: "ZIP条目CRC32不匹配") }
            if output >= 0 { guard fsync(output) == 0 else { throw FileFailure.io }; close(output); output = -1 }
            verified.append(GroupEntry(path: record.path, isDirectory: record.directory, size: Int64(record.size), sha256: record.directory ? "" : hex(Data(hash.finalize()))))
            cursor = dataEnd
        }
        guard cursor == centralStart else { throw groupInvalid("ZIP本地记录有空洞或尾随数据") }
        let value = try validateGroupEntries(verified, expected: expected)
        if let tree {
            for entry in value.entries.filter(\.isDirectory).sorted(by: { $0.path.utf8.count > $1.path.utf8.count }) {
                try synchronizeDirectory(try groupPath(entry.path, directory: true).reduce(tree) { $0.appendingPathComponent($1) })
            }
            try synchronizeDirectory(tree)
        }
        return value
    }
    private static func validDOS(time: UInt16, date: UInt16) -> Bool {
        let hour = Int(time >> 11), minute = Int((time >> 5) & 63), second = Int(time & 31)
        let month = Int((date >> 5) & 15), day = Int(date & 31), year = 1980 + Int(date >> 9)
        guard hour < 24, minute < 60, second < 30, (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
    func u16(_ offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | (UInt32(u16(offset + 2)) << 16) }
}
