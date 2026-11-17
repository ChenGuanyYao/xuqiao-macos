import Foundation
import CryptoKit

let GROUP_MAX_ENTRIES = 1024
let GROUP_MAX_ROOTS = 100
let GROUP_MAX_METADATA = 2_097_152

public struct GroupEntry: Codable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    /// 文件SHA256为小写；目录为空字符串，摘要拼F记录时再转大写。
    public let sha256: String
}
public struct GroupMetadata: Codable, Equatable {
    public let groupHash: String
    public let entryCount: Int
    public let totalBytes: Int64
    public let roots: [String]
    public var entries: [GroupEntry]
    var offerFields: [String: Any] { ["kind": "group", "groupHash": groupHash, "entryCount": entryCount, "totalBytes": totalBytes, "roots": roots] }
    func sameSummary(_ other: GroupMetadata) -> Bool {
        groupHash == other.groupHash && entryCount == other.entryCount && totalBytes == other.totalBytes && groupStringsEqual(roots, other.roots)
    }
    static func parse(_ fields: [String: Any]) throws -> GroupMetadata? {
        let kind = fields["kind"] as? String ?? ""
        guard fields["kind"] == nil || fields["kind"] is String else { throw groupInvalid("文件类型无效") }
        if kind.isEmpty || kind == "file" { return nil }
        guard kind == "group" else { throw FileFailure(code: "FILE_UNSUPPORTED", message: "不支持此文件类型") }
        guard let hash = fields["groupHash"] as? String, validUpperHash(hash),
              let count = fileInteger(fields["entryCount"], maximum: Int64(GROUP_MAX_ENTRIES)), count >= 1,
              let total = fileInteger(fields["totalBytes"]), let roots = fields["roots"] as? [String],
              (1...GROUP_MAX_ROOTS).contains(roots.count), roots.allSatisfy({ fileName($0) != nil }),
              groupStringsEqual(roots, roots.sorted(by: utf8Less)), Set(roots.map(groupAlias)).count == roots.count else {
            throw groupInvalid("文件组清单摘要无效")
        }
        return GroupMetadata(groupHash: hash, entryCount: Int(count), totalBytes: total, roots: roots, entries: [])
    }
}
struct GroupManifest: Codable {
    let version: Int
    let metadata: GroupMetadata
}
func validUpperHash(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
}
func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
func groupStringsEqual(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
}
func groupAlias(_ name: String) -> String {
    String(String.UnicodeScalarView(name.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar in
        (65...90).contains(scalar.value) ? UnicodeScalar(scalar.value + 32)! : scalar
    }))
}
func groupPath(_ path: String, directory: Bool) throws -> [String] {
    guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), path.hasSuffix("/") == directory else { throw groupInvalid("文件组路径无效") }
    let plain = directory ? String(path.dropLast()) : path
    let parts = plain.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard (1...16).contains(parts.count), parts.allSatisfy({ fileName($0) != nil }) else { throw groupInvalid("文件组路径组件或深度无效") }
    return parts
}
struct GroupLayoutItem {
    let path: String
    let directory: Bool
    let size: Int64
}
/// 不需要假造文件hash：在读取/展开正文前先验证名字、父目录、别名和summary。
func validateGroupLayout(_ entries: [GroupLayoutItem], expected: GroupMetadata? = nil) throws -> (roots: [String], total: Int64) {
    guard (1...GROUP_MAX_ENTRIES).contains(entries.count) else { throw groupInvalid("文件组条目数超出限制") }
    var raw = Set<Data>(), aliases = Set<String>(), dirs = Set<Data>(), rootNames: [Data: String] = [:]
    var total: Int64 = 0, metadata = 0
    for entry in entries {
        let parts = try groupPath(entry.path, directory: entry.directory), plain = parts.joined(separator: "/")
        guard raw.insert(Data(entry.path.utf8)).inserted, aliases.insert(groupAlias(plain)).inserted else { throw groupInvalid("文件组包含重复或别名路径") }
        if entry.directory { guard entry.size == 0 else { throw groupInvalid("目录大小无效") }; dirs.insert(Data(plain.utf8)) }
        else { guard (0...FILE_MAX_SIZE).contains(entry.size) else { throw groupInvalid("文件大小无效") }; total += entry.size }
        guard total <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_SIZE", message: "文件组原始内容超过128MiB") }
        rootNames[Data(parts[0].utf8)] = parts[0]; metadata += entry.path.utf8.count + 192
        guard metadata <= GROUP_MAX_METADATA else { throw groupInvalid("文件组元信息超过限制") }
    }
    for entry in entries {
        let parts = try groupPath(entry.path, directory: entry.directory)
        if parts.count > 1 {
            for length in 1..<parts.count {
                guard dirs.contains(Data(parts.prefix(length).joined(separator: "/").utf8)) else { throw groupInvalid("文件组缺少显式父目录") }
            }
        }
    }
    let roots = rootNames.values.sorted(by: utf8Less)
    guard roots.count <= GROUP_MAX_ROOTS else { throw groupInvalid("文件组顶层项目过多") }
    if let expected, expected.entryCount != entries.count || expected.totalBytes != total || !groupStringsEqual(expected.roots, roots) {
        throw FileFailure(code: "FILE_HASH", message: "文件组条目数、原始大小或顶层项目不一致")
    }
    return (roots, total)
}
func validateGroupEntries(_ entries: [GroupEntry], expected: GroupMetadata? = nil) throws -> GroupMetadata {
    let layout = try validateGroupLayout(entries.map { GroupLayoutItem(path: $0.path, directory: $0.isDirectory, size: $0.size) }, expected: expected)
    let sorted = entries.sorted { utf8Less($0.path, $1.path) }
    var digest = SHA256()
    for entry in sorted {
        if entry.isDirectory {
            guard entry.sha256.isEmpty else { throw groupInvalid("目录条目摘要无效") }
            digest.update(data: Data(("D|" + entry.path + "\0").utf8))
        } else {
            guard validHex(entry.sha256) else { throw groupInvalid("文件条目摘要无效") }
            digest.update(data: Data(("F|\(entry.path)|\(entry.size)|\(entry.sha256.uppercased())\0").utf8))
        }
    }
    let value = GroupMetadata(groupHash: hex(Data(digest.finalize())).uppercased(), entryCount: sorted.count, totalBytes: layout.total, roots: layout.roots, entries: sorted)
    guard try JSONEncoder().encode(value).count <= GROUP_MAX_METADATA else { throw groupInvalid("文件组索引超过2MiB") }
    if let expected, !value.sameSummary(expected) { throw FileFailure(code: "FILE_HASH", message: "文件组内容摘要或清单汇总不一致") }
    return value
}
func groupInvalid(_ text: String) -> FileFailure { FileFailure(code: "FILE_INVALID", message: text) }
struct WorkCancelled: Error {}
final class WorkCancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if isCancelled { throw WorkCancelled() } }
}
struct CRC32 {
    private var value: UInt32 = 0xffff_ffff
    private static let table: [UInt32] = (0..<256).map { index in
        var n = UInt32(index)
        for _ in 0..<8 { n = n & 1 == 0 ? n >> 1 : (n >> 1) ^ 0xedb8_8320 }
        return n
    }
    mutating func update(_ data: Data) { for byte in data { value = (value >> 8) ^ Self.table[Int((value ^ UInt32(byte)) & 255)] } }
    var checksum: UInt32 { value ^ 0xffff_ffff }
}
