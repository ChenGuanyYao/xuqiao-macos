import Foundation
import CryptoKit
import Darwin

struct BatchTaskOutcome {
    let state: String
    let savedRoots: Int
    let message: String
    var exportedFile: URL? = nil
}
private struct CreatedExport {
    let components: [String]
    let device: Int64
    let inode: UInt64
    let directory: Bool
}
private func directoryChain(_ root: Int32, _ components: [String]) throws -> Int32 {
    var fd = dup(root); guard fd >= 0 else { throw FileFailure.io }
    do {
        for part in components {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw FileFailure.io }; close(fd); fd = next
        }
        return fd
    } catch { close(fd); throw error }
}
private func createdExport(_ fd: Int32, components: [String], directory: Bool) throws -> CreatedExport {
    var info = stat(); guard fstat(fd, &info) == 0 else { throw FileFailure.io }
    return CreatedExport(components: components, device: Int64(info.st_dev), inode: UInt64(info.st_ino), directory: directory)
}
private func cleanCreated(_ values: [CreatedExport], base: Int32) {
    for value in values.reversed() {
        guard let parent = try? directoryChain(base, Array(value.components.dropLast())) else { continue }
        defer { close(parent) }
        guard let name = value.components.last else { continue }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Int64(current.st_dev) == value.device, UInt64(current.st_ino) == value.inode else { continue }
        // 只清理自己创建且未被替换的项；rmdir遇外来内容不删除，绝不递归回滚已保存root。
        _ = unlinkat(parent, name, value.directory ? AT_REMOVEDIR : 0)
    }
}
private func availableExport(_ base: Int32, original: String, directory: Bool) throws -> (String, Int32) {
    for number in 1...10_000 {
        let name: String
        if number == 1 { name = original }
        else if directory { name = original + " (\(number))" }
        else {
            let file = original as NSString, ext = file.pathExtension
            name = ext.isEmpty ? original + " (\(number))" : file.deletingPathExtension + " (\(number))." + ext
        }
        guard name.utf8.count <= 255 else { throw FileFailure(code: "FILE_IO", message: "副本名称超过文件系统长度限制") }
        if directory {
            if mkdirat(base, name, 0o700) == 0 {
                let fd = openat(base, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw FileFailure.io }; return (name, fd)
            }
        } else {
            let fd = openat(base, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 { return (name, fd) }
        }
        guard errno == EEXIST else { throw FileFailure.io }
    }
    throw FileFailure(code: "FILE_IO", message: "同名副本过多，请选择其他目录")
}
private func copyVerifiedExport(_ input: Int32, output: Int32, entry: GroupEntry, cancellation: WorkCancellation) throws {
    var info = stat()
    guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == entry.size else { throw FileFailure(code: "FILE_HASH", message: "要保存的文件已改变") }
    var hash = SHA256(); var total: Int64 = 0
    while true {
        try cancellation.check(); let block = try readBlock(input, limit: 65_536); if block.isEmpty { break }
        total += Int64(block.count); guard total <= entry.size else { throw FileFailure(code: "FILE_HASH", message: "要保存的文件大小变化") }
        try writeBlock(output, block); hash.update(data: block)
    }
    guard total == entry.size, hex(Data(hash.finalize())) == entry.sha256 else { throw FileFailure(code: "FILE_HASH", message: "保存文件校验失败") }
    guard fsync(output) == 0 else { throw FileFailure.io }
}
extension FileStorage {
    func exportApplicationDirectory(parent: URL) throws -> URL {
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
        if parent.lastPathComponent == "续桥" { return parent }
        let directory = parent.appendingPathComponent("续桥", isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 {
            guard errno == EEXIST, lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
        }
        try synchronizeDirectory(parent); return directory
    }
    func exportReceivedTask(_ task: FileTask, applicationDirectory: URL, cancellation: WorkCancellation) -> BatchTaskOutcome {
        var saved = 0
        var exportedFile: URL?
        var created: [CreatedExport] = []
        var base: Int32 = -1
        defer { if base >= 0 { close(base) } }
        do {
            try cancellation.check()
            guard task.direction == .incoming, task.state == .completed else { throw groupInvalid("只能保存已完成的接收记录") }
            base = open(applicationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard base >= 0 else { throw FileFailure.io }
            let entries: [GroupEntry], roots: [String], sourceTree: Int32
            if let group = task.group {
                guard try groupReceiptMatches(task, cancellation: cancellation) else { throw FileFailure(code: "FILE_HASH", message: "文件组本地内容已丢失或改变") }
                entries = group.entries; roots = group.roots
                sourceTree = open(groupTree(task).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard sourceTree >= 0 else { throw FileFailure.io }
            } else {
                entries = [GroupEntry(path: task.name, isDirectory: false, size: task.size, sha256: task.sha256)]
                roots = [task.name]; sourceTree = -1
            }
            defer { if sourceTree >= 0 { close(sourceTree) } }
            for rootName in roots {
                try cancellation.check(); created = []
                guard let rootEntry = entries.first(where: { $0.path.utf8.elementsEqual(rootName.utf8) || $0.path.utf8.elementsEqual((rootName + "/").utf8) }) else { throw groupInvalid("文件组缺少顶层条目") }
                let reserved = try availableExport(base, original: rootName, directory: rootEntry.isDirectory)
                let name = reserved.0, fd = reserved.1
                var rootClosed = false
                defer { if !rootClosed { close(fd) } }
                created.append(try createdExport(fd, components: [name], directory: rootEntry.isDirectory))
                if rootEntry.isDirectory {
                    for entry in entries {
                        let parts = try groupPath(entry.path, directory: entry.isDirectory)
                        guard parts[0].utf8.elementsEqual(rootName.utf8), parts.count > 1 else { continue }
                        try cancellation.check()
                        let relative = Array(parts.dropFirst()), parentFD = try directoryChain(fd, Array(relative.dropLast()))
                        defer { close(parentFD) }
                        let leaf = relative.last!
                        if entry.isDirectory {
                            guard mkdirat(parentFD, leaf, 0o700) == 0 else { throw FileFailure.io }
                            let output = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                            guard output >= 0 else { throw FileFailure.io }; defer { close(output) }
                            created.append(try createdExport(output, components: [name] + relative, directory: true))
                        } else {
                            let output = openat(parentFD, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                            guard output >= 0 else { throw FileFailure.io }; defer { close(output) }
                            created.append(try createdExport(output, components: [name] + relative, directory: false))
                            let sourceParent = try directoryChain(sourceTree, Array(parts.dropLast())); defer { close(sourceParent) }
                            let input = openat(sourceParent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                            guard input >= 0 else { throw FileFailure.io }; defer { close(input) }
                            try copyVerifiedExport(input, output: output, entry: entry, cancellation: cancellation)
                        }
                    }
                    for value in created.filter(\.directory).reversed() {
                        let directory = try directoryChain(base, value.components); defer { close(directory) }
                        guard fsync(directory) == 0 else { throw FileFailure.io }
                    }
                } else {
                    let input: Int32
                    if task.group == nil { input = try openRegular(final(task)) }
                    else { input = openat(sourceTree, rootName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard input >= 0 else { throw FileFailure.io } }
                    defer { close(input) }
                    try copyVerifiedExport(input, output: fd, entry: rootEntry, cancellation: cancellation)
                }
                close(fd); rootClosed = true
                guard fsync(base) == 0 else { throw FileFailure.io }
                // 只有当前root全部校验/同步后才保留；后续失败不回滚这些已保存内容。
                saved += 1; created = []
                if task.group == nil { exportedFile = applicationDirectory.appendingPathComponent(name) }
            }
            return BatchTaskOutcome(state: "completed", savedRoots: saved, message: "已保存全部\(saved)个顶层项目", exportedFile: exportedFile)
        } catch {
            if base >= 0 { cleanCreated(created, base: base); _ = fsync(base) }
            let cancelled = error is WorkCancelled
            let detail = cancelled ? "保存已取消" : ((error as? FileFailure)?.localizedDescription ?? FileFailure.io.localizedDescription)
            return BatchTaskOutcome(state: cancelled ? "cancelled" : "failed", savedRoots: saved,
                                    message: saved > 0 ? "部分已保存（\(saved)个顶层项目）；" + detail : detail)
        }
    }
    #if DEBUG
    func debugExportDirectory(_ path: String?) throws -> URL {
        let base = root.appendingPathComponent("Exports", isDirectory: true); try Self.directory(base)
        guard let path else { return base }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw groupInvalid("测试导出目录无效") }
        var candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var suffix: [String] = []
        var info = stat()
        while lstat(candidate.path, &info) != 0 {
            guard errno == ENOENT, let component = fileName(candidate.lastPathComponent), candidate.path != "/" else { throw FileFailure.io }
            suffix.insert(component, at: 0); candidate.deleteLastPathComponent()
        }
        guard let raw = realpath(candidate.path, nil) else { throw FileFailure.io }; defer { free(raw) }
        var result = URL(fileURLWithPath: String(cString: raw), isDirectory: true)
        guard result.path == base.path || result.path.hasPrefix(base.path + "/") else { throw groupInvalid("测试导出只能写隔离Exports目录") }
        for part in suffix { result.appendPathComponent(part, isDirectory: true); try Self.directory(result) }
        return result
    }
    #endif
}
