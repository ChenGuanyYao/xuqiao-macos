import Foundation
import Darwin

struct PreparedPayload {
    let name: String
    let size: Int64
    let sha256: String
    let group: GroupMetadata?
}
extension FileStorage {
    func groupDirectory(_ task: FileTask) -> URL { root.appendingPathComponent("Groups", isDirectory: true).appendingPathComponent(task.id, isDirectory: true) }
    func groupPrepared(_ task: FileTask) -> URL { groupDirectory(task).appendingPathComponent(".extract-" + task.attemptId, isDirectory: true) }
    func groupCommitted(_ task: FileTask) -> URL { groupDirectory(task).appendingPathComponent("Committed", isDirectory: true) }
    func groupTree(_ task: FileTask) -> URL { groupCommitted(task).appendingPathComponent("tree", isDirectory: true) }
    func ensureGroup(_ task: FileTask) throws {
        try Self.directory(root.appendingPathComponent("Groups", isDirectory: true)); try Self.directory(groupDirectory(task))
    }
    func cleanGroupPreparation(_ task: FileTask) {
        // 唯一attempt目录；不碰Committed，也不清理可能属于新attempt的payload。
        try? FileManager.default.removeItem(at: groupPrepared(task))
    }
    func prepareMany(_ originals: [URL], id: String, cancellation: WorkCancellation) throws -> PreparedPayload {
        guard (1...GROUP_MAX_ROOTS).contains(originals.count) else { throw groupInvalid("最多选择100个项目") }
        if originals.count == 1 {
            var info = stat()
            if lstat(originals[0].path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                let single = try prepare(originals[0], id: id, cancellation: cancellation)
                return PreparedPayload(name: single.name, size: single.size, sha256: single.hash, group: nil)
            }
        }
        let directory = source(id).deletingLastPathComponent()
        try Self.directory(root.appendingPathComponent("Staging", isDirectory: true)); try Self.directory(directory)
        let snapshot = directory.appendingPathComponent("Snapshot", isDirectory: true)
        var success = false
        defer {
            try? FileManager.default.removeItem(at: snapshot)
            if !success { _ = unlink(directory.appendingPathComponent(".source.partial").path) }
        }
        let result = try GroupSource(cancellation: cancellation).build(originals, snapshot: snapshot)
        try cancellation.check()
        let temporary = directory.appendingPathComponent(".source.partial")
        try GroupZIP.write(result.1, to: temporary, cancellation: cancellation)
        var info = stat(); guard lstat(temporary.path, &info) == 0 else { throw FileFailure.io }
        let hash = try hashFile(temporary, expectedSize: info.st_size)
        try cancellation.check()
        guard rename(temporary.path, source(id).path) == 0 else { throw FileFailure.io }
        try synchronizeDirectory(directory); success = true
        return PreparedPayload(name: result.0, size: info.st_size, sha256: hash, group: result.2)
    }
    func extractGroup(_ task: FileTask, archive: URL, cancellation: WorkCancellation) throws -> GroupMetadata {
        guard let group = task.group else { throw groupInvalid("文件组元信息缺失") }
        try ensureGroup(task); cleanGroupPreparation(task)
        let prepared = groupPrepared(task), tree = prepared.appendingPathComponent("tree", isDirectory: true)
        try Self.directory(prepared); try Self.directory(tree)
        var success = false
        defer { if !success { cleanGroupPreparation(task) } }
        let metadata = try GroupZIP.scan(archive, expected: group, extractInto: tree, cancellation: cancellation)
        // 对真实展开树再核验，包含空目录和实际文件系统产生的名称，不依赖索引自证。
        _ = try verifiedGroupTree(tree, expected: metadata, cancellation: cancellation)
        try writeManifest(metadata, directory: prepared)
        try synchronizeDirectory(prepared)
        try synchronizeDirectory(groupDirectory(task))
        try synchronizeDirectory(root.appendingPathComponent("Groups", isDirectory: true))
        try synchronizeDirectory(receivedDirectory(task.id))
        try synchronizeDirectory(root.appendingPathComponent("Received", isDirectory: true))
        try synchronizeDirectory(root)
        try cancellation.check(); success = true; return metadata
    }
    private func writeManifest(_ metadata: GroupMetadata, directory: URL) throws {
        let data = try JSONEncoder().encode(GroupManifest(version: 1, metadata: metadata))
        guard data.count <= GROUP_MAX_METADATA else { throw groupInvalid("文件组索引超过限制") }
        let fd = open(directory.appendingPathComponent("manifest.json").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.io }; defer { close(fd) }
        try writeBlock(fd, data); guard fsync(fd) == 0 else { throw FileFailure.io }
    }
    private func manifestMatches(_ task: FileTask, directory: URL, metadata: GroupMetadata) throws -> Bool {
        let url = directory.appendingPathComponent("manifest.json")
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return false }; throw FileFailure.io }
        guard info.st_mode & S_IFMT == S_IFREG else { return false }
        guard info.st_size >= 0, info.st_size <= GROUP_MAX_METADATA else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw FileFailure.io }; defer { close(fd) }
        var data = Data()
        while data.count <= GROUP_MAX_METADATA {
            let block = try readBlock(fd, limit: min(65_536, GROUP_MAX_METADATA + 1 - data.count))
            if block.isEmpty { break }; data.append(block)
        }
        guard data.count <= GROUP_MAX_METADATA, let manifest = try? JSONDecoder().decode(GroupManifest.self, from: data), manifest.version == 1,
              manifest.metadata.sameSummary(metadata) else { return false }
        do {
            let checked = try validateGroupEntries(manifest.metadata.entries, expected: metadata)
            return zip(checked.entries, metadata.entries).allSatisfy { a, b in
                a.path.utf8.elementsEqual(b.path.utf8) && a.isDirectory == b.isDirectory && a.size == b.size && a.sha256 == b.sha256
            } && checked.entries.count == metadata.entries.count
        } catch { return false }
    }
    private func committedMatches(_ task: FileTask, metadata: GroupMetadata, cancellation: WorkCancellation) throws -> Bool {
        var info = stat()
        if lstat(groupCommitted(task).path, &info) != 0 { if errno == ENOENT { return false }; throw FileFailure.io }
        guard info.st_mode & S_IFMT == S_IFDIR else { return false }
        guard try manifestMatches(task, directory: groupCommitted(task), metadata: metadata) else { return false }
        do { _ = try verifiedGroupTree(groupTree(task), expected: metadata, cancellation: cancellation); return true }
        catch let error as FileFailure where ["FILE_HASH", "FILE_INVALID", "FILE_SIZE", "FILE_NOT_FOUND"].contains(error.code) { return false }
    }
    func groupReceiptMatches(_ task: FileTask, cancellation: WorkCancellation) throws -> Bool {
        guard let group = task.group else { return matches(final(task), task: task) }
        guard try recoveryMatches(final(task), task: task) else { return false }
        do {
            let metadata = try GroupZIP.scan(final(task), expected: group, cancellation: cancellation)
            return try committedMatches(task, metadata: metadata, cancellation: cancellation)
        } catch let error as FileFailure where ["FILE_HASH", "FILE_INVALID", "FILE_SIZE", "FILE_NOT_FOUND"].contains(error.code) { return false }
    }
    /// 调用前committing已成功持久化；payload和展开树移动后分别同步父目录。
    func commitGroup(_ task: FileTask) throws {
        try commit(task)
        try publishGroupTree(task)
    }
    private func publishGroupTree(_ task: FileTask) throws {
        let prepared = groupPrepared(task), committed = groupCommitted(task)
        var info = stat()
        if lstat(committed.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
            let replaced = groupDirectory(task).appendingPathComponent(".replaced-" + task.attemptId, isDirectory: true)
            try? FileManager.default.removeItem(at: replaced)
            guard rename(committed.path, replaced.path) == 0 else { throw FileFailure.io }
        } else if errno != ENOENT { throw FileFailure.io }
        guard rename(prepared.path, committed.path) == 0 else { throw FileFailure.io }
        try synchronizeDirectory(groupDirectory(task))
    }
    func recoverGroup(_ task: FileTask, cancellation: WorkCancellation) throws -> GroupMetadata {
        guard let group = task.group else { throw groupInvalid("文件组恢复元信息缺失") }
        try ensureReceived(task); try ensureGroup(task)
        let archive: URL
        if try recoveryMatches(final(task), task: task) { archive = final(task) }
        else if try recoveryMatches(partial(task), task: task) { archive = partial(task) }
        else { throw FileFailure(code: "FILE_HASH", message: "文件组容器缺失或已变化") }
        let metadata: GroupMetadata
        do { metadata = try GroupZIP.scan(archive, expected: group, cancellation: cancellation) }
        catch let error as FileFailure where ["FILE_INVALID", "FILE_SIZE"].contains(error.code) { throw FileFailure(code: "FILE_HASH", message: "文件组容器内容无效") }
        let validTree = try committedMatches(task, metadata: metadata, cancellation: cancellation)
        if !validTree { _ = try extractGroup(task, archive: archive, cancellation: cancellation) }
        if archive.path == partial(task).path { try commit(task) }
        else { try synchronizeDirectory(receivedDirectory(task.id)) }
        if !validTree { try publishGroupTree(task) }
        else { try synchronizeDirectory(groupDirectory(task)) }
        return metadata
    }
    func finishGroupCleanup(_ task: FileTask) {
        cleanGroupPreparation(task)
        try? FileManager.default.removeItem(at: groupDirectory(task).appendingPathComponent(".replaced-" + task.attemptId))
    }
}

extension FileStorage {
    func groupReceiptOrFileMatches(_ task: FileTask) throws -> Bool {
        if task.group != nil { return try groupReceiptMatches(task, cancellation: WorkCancellation()) }
        return try recoveryMatches(final(task), task: task)
    }
}
