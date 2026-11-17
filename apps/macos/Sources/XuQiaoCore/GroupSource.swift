import Foundation
import CryptoKit
import Darwin

private struct SourceSignature: Equatable {
    let device: Int64, inode: UInt64, mode: UInt16, size: Int64
    let mtime: Int64, mtimeNS: Int64, ctime: Int64, ctimeNS: Int64
    init(_ s: stat) {
        device = Int64(s.st_dev); inode = UInt64(s.st_ino); mode = s.st_mode; size = s.st_size
        mtime = Int64(s.st_mtimespec.tv_sec); mtimeNS = Int64(s.st_mtimespec.tv_nsec)
        ctime = Int64(s.st_ctimespec.tv_sec); ctimeNS = Int64(s.st_ctimespec.tv_nsec)
    }
    var identity: String { "\(device):\(inode)" }
    var directory: Bool { mode & S_IFMT == S_IFDIR }
}
func groupDirectoryNames(_ fd: Int32) throws -> [String] {
    let duplicate = dup(fd); guard duplicate >= 0 else { throw FileFailure.io }
    guard let directory = fdopendir(duplicate) else { close(duplicate); throw FileFailure.io }
    defer { closedir(directory) }; rewinddir(directory)
    var names: [String] = []
    while true {
        errno = 0
        guard let item = readdir(directory) else { if errno != 0 { throw FileFailure.io }; break }
        let length = Int(item.pointee.d_namlen)
        let data = withUnsafeBytes(of: item.pointee.d_name) { Data($0.prefix(length)) }
        guard let name = String(data: data, encoding: .utf8) else { throw groupInvalid("目录含非UTF8名称") }
        if name == "." || name == ".." { continue }
        guard fileName(name) != nil else { throw groupInvalid("目录含不支持的名称") }
        guard names.count < GROUP_MAX_ENTRIES else { throw groupInvalid("目录条目超过1024") }
        names.append(name)
    }
    return names.sorted(by: utf8Less)
}
func groupChild(_ directory: Int32, _ name: String) throws -> Int32 {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { if errno == ELOOP { throw groupInvalid("文件组不支持符号链接") }; throw FileFailure.io }
    var info = stat()
    guard fstat(fd, &info) == 0 else { close(fd); throw FileFailure.io }
    guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
        close(fd); throw groupInvalid("文件组不支持符号链接或特殊文件")
    }
    return fd
}

/// 对选择器授权的根使用FD遍历，不跟随子目录链接；逐文件和全树复核变化后才封装快照。
final class GroupSource {
    private struct Root { let fd: Int32; let name: String; let directory: Bool; let identity: String }
    private var roots: [Root] = []
    private var signatures: [Data: SourceSignature] = [:]
    private var listings: [Data: [String]] = [:]
    private var packed: [GroupPackedEntry] = []
    private var bytes: Int64 = 0
    private let cancellation: WorkCancellation
    init(cancellation: WorkCancellation) { self.cancellation = cancellation }
    deinit { for root in roots { close(root.fd) } }
    func build(_ urls: [URL], snapshot: URL) throws -> (String, [GroupPackedEntry], GroupMetadata) {
        guard (1...GROUP_MAX_ROOTS).contains(urls.count) else { throw groupInvalid("最多选择100个顶层项目") }
        var aliases = Set<String>(), identities = Set<String>()
        for url in urls {
            try cancellation.check()
            guard let name = fileName(url.lastPathComponent), aliases.insert(groupAlias(name)).inserted else { throw groupInvalid("顶层名称重复或无效") }
            var initial = stat()
            guard lstat(url.path, &initial) == 0 else { throw FileFailure.io }
            guard initial.st_mode & S_IFMT == S_IFREG || initial.st_mode & S_IFMT == S_IFDIR else { throw groupInvalid("不支持符号链接或特殊文件") }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { if errno == ELOOP { throw groupInvalid("不支持符号链接") }; throw FileFailure.io }
            var statValue = stat()
            guard fstat(fd, &statValue) == 0 else { close(fd); throw FileFailure.io }
            let signature = SourceSignature(statValue)
            guard signature.directory || signature.mode & S_IFMT == S_IFREG, identities.insert(signature.identity).inserted else {
                close(fd); throw groupInvalid("选择包含重复、重叠或特殊项目")
            }
            roots.append(Root(fd: fd, name: name, directory: signature.directory, identity: signature.identity))
        }
        try FileStorage.directory(snapshot)
        for root in roots { try capture(root.fd, path: root.name, destination: snapshot.appendingPathComponent(root.name), rootIdentity: root.identity, allRoots: identities) }
        for root in roots { try recheck(root.fd, path: root.name) }
        let metadata = try validateGroupEntries(packed.map(\.entry))
        let name = roots.count == 1 && roots[0].directory ? roots[0].name : "文件组"
        return (name, packed.sorted { utf8Less($0.entry.path, $1.entry.path) }, metadata)
    }
    private func capture(_ fd: Int32, path: String, destination: URL, rootIdentity: String, allRoots: Set<String>) throws {
        try cancellation.check()
        var info = stat(); guard fstat(fd, &info) == 0 else { throw FileFailure.io }
        let before = SourceSignature(info)
        if before.identity != rootIdentity && allRoots.contains(before.identity) { throw groupInvalid("不能同时选择目录及其内部项目") }
        let relative = path + (before.directory ? "/" : "")
        _ = try groupPath(relative, directory: before.directory)
        guard packed.count < GROUP_MAX_ENTRIES else { throw groupInvalid("文件组条目超过1024") }
        signatures[Data(relative.utf8)] = before
        if before.directory {
            guard mkdir(destination.path, 0o700) == 0 else {
                if errno == EEXIST { throw groupInvalid("本地文件系统名称别名冲突") }
                throw FileFailure.io
            }
            packed.append(GroupPackedEntry(entry: GroupEntry(path: relative, isDirectory: true, size: 0, sha256: ""), crc: 0, snapshot: nil))
            let names = try groupDirectoryNames(fd); listings[Data(relative.utf8)] = names
            for name in names {
                let child = try groupChild(fd, name); defer { close(child) }
                try capture(child, path: path + "/" + name, destination: destination.appendingPathComponent(name), rootIdentity: rootIdentity, allRoots: allRoots)
            }
            guard groupStringsEqual(names, try groupDirectoryNames(fd)) else { throw FileFailure(code: "FILE_IO", message: "复制时目录内容发生变化") }
        } else {
            guard before.mode & S_IFMT == S_IFREG, before.size >= 0, before.size <= FILE_MAX_SIZE else { throw groupInvalid("文件组源不是有效普通文件") }
            bytes += before.size; guard bytes <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_SIZE", message: "文件组原始内容超过128MiB") }
            let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard out >= 0 else { if errno == EEXIST { throw groupInvalid("本地文件系统名称别名冲突") }; throw FileFailure.io }
            defer { close(out) }
            var hash = SHA256(), crc = CRC32(); var total: Int64 = 0
            while true {
                try cancellation.check()
                let block = try readBlock(fd, limit: 65_536); if block.isEmpty { break }
                total += Int64(block.count); guard total <= before.size else { throw FileFailure(code: "FILE_IO", message: "复制时文件发生变化") }
                try writeBlock(out, block); hash.update(data: block); crc.update(block)
            }
            guard total == before.size, fsync(out) == 0, fchmod(out, 0o400) == 0 else { throw FileFailure.io }
            packed.append(GroupPackedEntry(entry: GroupEntry(path: relative, isDirectory: false, size: total, sha256: hex(Data(hash.finalize()))), crc: crc.checksum, snapshot: destination))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before == SourceSignature(after) else { throw FileFailure(code: "FILE_IO", message: "复制时文件或目录发生变化") }
    }
    private func recheck(_ fd: Int32, path: String) throws {
        try cancellation.check()
        var info = stat(); guard fstat(fd, &info) == 0 else { throw FileFailure.io }
        let signature = SourceSignature(info), relative = path + (info.st_mode & S_IFMT == S_IFDIR ? "/" : "")
        guard signatures[Data(relative.utf8)] == signature else { throw FileFailure(code: "FILE_IO", message: "快照完成前源项目发生变化") }
        if signature.directory {
            let names = try groupDirectoryNames(fd)
            guard let original = listings[Data(relative.utf8)], groupStringsEqual(names, original) else { throw FileFailure(code: "FILE_IO", message: "快照完成前源目录发生变化") }
            for name in names {
                let child = try groupChild(fd, name); defer { close(child) }; try recheck(child, path: path + "/" + name)
            }
        }
    }
}

/// 私有已展开树仍逐个读取实际文件，不凭manifest或ZIP存在就签收。
func verifiedGroupTree(_ tree: URL, expected: GroupMetadata, cancellation: WorkCancellation) throws -> GroupMetadata {
    let root = open(tree.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard root >= 0 else { if errno == ENOENT { throw FileFailure(code: "FILE_HASH", message: "文件组展开目录缺失") }; throw FileFailure.io }
    defer { close(root) }
    var entries: [GroupEntry] = []
    var totalSize: Int64 = 0
    func walk(_ parent: Int32, prefix: String) throws {
        for name in try groupDirectoryNames(parent) {
            try cancellation.check()
            guard entries.count < GROUP_MAX_ENTRIES else { throw groupInvalid("展开目录条目超限") }
            let child = try groupChild(parent, name); defer { close(child) }
            var info = stat(); guard fstat(child, &info) == 0 else { throw FileFailure.io }
            let before = SourceSignature(info), path = prefix + name
            _ = try groupPath(path + (before.directory ? "/" : ""), directory: before.directory)
            if before.directory {
                entries.append(GroupEntry(path: path + "/", isDirectory: true, size: 0, sha256: "")); try walk(child, prefix: path + "/")
            } else {
                guard before.size >= 0, before.size <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_HASH", message: "展开文件大小变化") }
                totalSize += before.size; guard totalSize <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_HASH", message: "展开内容总大小超限") }
                var hash = SHA256(); var total: Int64 = 0
                while true {
                    try cancellation.check(); let block = try readBlock(child, limit: 65_536); if block.isEmpty { break }
                    total += Int64(block.count); guard total <= before.size else { throw FileFailure(code: "FILE_HASH", message: "展开文件发生变化") }; hash.update(data: block)
                }
                guard total == before.size else { throw FileFailure(code: "FILE_HASH", message: "展开文件长度变化") }
                entries.append(GroupEntry(path: path, isDirectory: false, size: total, sha256: hex(Data(hash.finalize()))))
            }
            var after = stat(); guard fstat(child, &after) == 0 else { throw FileFailure.io }
            guard before == SourceSignature(after) else { throw FileFailure(code: "FILE_HASH", message: "校验时展开项目发生变化") }
        }
    }
    try walk(root, prefix: "")
    return try validateGroupEntries(entries, expected: expected)
}
