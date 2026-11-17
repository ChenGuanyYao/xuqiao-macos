import Foundation
import Darwin

/// 只清理已验证根目录下的固定应用缓存目录；不接收用户保存位置或源文件路径。
private final class PrivateCacheRemoval {
    private let root: Int32
    private let directories: [[String]]
    init(root url: URL, directories: [[String]]) throws {
        root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw FileFailure.io }
        self.directories = directories
    }
    deinit { close(root) }
    func remove() throws {
        // 先检查所有候选树，链接/特殊文件不得造成半清理后又把记录报成成功。
        for path in directories { try visit(path, deleting: false) }
        for path in directories { try visit(path, deleting: true) }
    }
    /// 仅引擎启动、尚无准备任务时调用；全部任务ID（含恢复日志/隐藏历史）都是保留引用。
    func recoverStages(referencedIDs: Set<String>) throws {
        let area = openat(root, "Staging", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard area >= 0 else { throw FileFailure.io }; defer { close(area) }
        // Staging包含历史发送任务，不能套用单个文件组1024项的枚举上限。
        let duplicate = dup(area); guard duplicate >= 0 else { throw FileFailure.io }
        guard let listing = fdopendir(duplicate) else { close(duplicate); throw FileFailure.io }
        defer { closedir(listing) }
        while true {
            errno = 0
            guard let entry = readdir(listing) else { if errno != 0 { throw FileFailure.io }; break }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard fileID(name) != nil, !referencedIDs.contains(name) else { continue }
            var budget = 16_384
            // 复用两遍校验和FD删除；绝不进入clipboard命名空间或跟随链接。
            try walk(parent: area, name: name, depth: 0, budget: &budget, deleting: false)
            budget = 16_384
            try walk(parent: area, name: name, depth: 0, budget: &budget, deleting: true)
        }
        guard fsync(area) == 0 else { throw FileFailure.io }
    }
    private func visit(_ path: [String], deleting: Bool) throws {
        guard path.count == 2, path.allSatisfy({ fileName($0) != nil }) else { throw FileFailure.io }
        let area = openat(root, path[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if area < 0 { if errno == ENOENT { return }; throw FileFailure.io }
        defer { close(area) }
        var budget = 16_384
        try walk(parent: area, name: path[1], depth: 0, budget: &budget, deleting: deleting)
        if deleting, fsync(area) != 0 { throw FileFailure.io }
    }
    private func walk(parent: Int32, name: String, depth: Int, budget: inout Int, deleting: Bool) throws {
        guard depth <= 32, budget > 0, fileName(name) != nil else { throw FileFailure.io }
        budget -= 1
        var entry = stat()
        if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }; throw FileFailure.io
        }
        guard entry.st_mode & S_IFMT == S_IFREG || entry.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
        if entry.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw FileFailure.io }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino else { throw FileFailure.io }
            for item in try groupDirectoryNames(child) { try walk(parent: child, name: item, depth: depth + 1, budget: &budget, deleting: deleting) }
        }
        if deleting {
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == entry.st_dev, current.st_ino == entry.st_ino,
                  current.st_mode & S_IFMT == entry.st_mode & S_IFMT,
                  unlinkat(parent, name, entry.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw FileFailure.io }
        }
    }
}

extension FileStorage {
    func removeUnpublishedStage(_ id: String) throws {
        guard fileID(id) != nil else { throw FileFailure.io }
        try PrivateCacheRemoval(root: root, directories: [["Staging", id]]).remove()
    }
    func recoverOrphanStages(referencedIDs: Set<String>) throws {
        try PrivateCacheRemoval(root: root, directories: []).recoverStages(referencedIDs: referencedIDs)
    }

    func removeTaskCache(_ task: FileTask) throws {
        guard fileID(task.id) != nil, fileID(task.attemptId) != nil, validatePaths(task) else { throw FileFailure.io }
        try PrivateCacheRemoval(root: root, directories: [["Received", task.id], ["Staging", task.id], ["Groups", task.id]]).remove()
    }
    func removeClipboardCache(_ index: ClipboardSnapshotIndex) throws {
        guard validHex(index.recordId, count: 32), index.relativePath == "ClipboardSnapshots/\(index.recordId)/payload" else { throw FileFailure.io }
        try PrivateCacheRemoval(root: root, directories: [["ClipboardSnapshots", index.recordId], ["Staging", "clipboard-" + index.recordId]]).remove()
    }
}
