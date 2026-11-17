import Foundation
import CryptoKit
import Darwin

final class FileStorage {
    let root: URL
    init(directory: String?) throws {
        let requested: URL
        if let directory { requested = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL }
        else {
            requested = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("com.chenguangyao.xuqiao.mac/Transfers", isDirectory: true)
        }
        // 根目录本身不允许是链接；/tmp等系统父路径规范化后仍对SQLite启用NOFOLLOW。
        try Self.directory(requested, intermediate: true)
        guard let canonical = realpath(requested.path, nil) else { throw FileFailure.io }
        defer { free(canonical) }
        // NSURL会将/private/tmp美化回/tmp；SQLite NOFOLLOW需要POSIX真实路径。
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        try Self.directory(root.appendingPathComponent("Received", isDirectory: true))
        try Self.directory(root.appendingPathComponent("Staging", isDirectory: true))
    }
    static func directory(_ url: URL, intermediate: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
        } else {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediate, attributes: [.posixPermissions: 0o700]) }
            catch { throw FileFailure.io }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func receivedDirectory(_ id: String) -> URL { root.appendingPathComponent("Received", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    func final(_ task: FileTask) -> URL { receivedDirectory(task.id).appendingPathComponent(task.name) }
    func partial(_ task: FileTask) -> URL {
        receivedDirectory(task.id).appendingPathComponent(task.name == ".partial" ? ".partial-" + task.attemptId : ".partial")
    }
    func source(_ id: String) -> URL { root.appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(id, isDirectory: true).appendingPathComponent("source") }
    func ensureReceived(_ task: FileTask) throws {
        try Self.directory(root.appendingPathComponent("Received", isDirectory: true))
        try Self.directory(receivedDirectory(task.id))
    }
    func cleanPartial(_ task: FileTask) {
        _ = unlink(partial(task).path)
        if task.group != nil { cleanGroupPreparation(task) }
    }
    func cleanSource(_ task: FileTask) { _ = unlink(source(task.id).path) }
    func validatePaths(_ task: FileTask) -> Bool {
        if task.direction == .outgoing { return task.sourcePath == source(task.id).path && task.destinationPath.isEmpty }
        return task.sourcePath.isEmpty && task.destinationPath == final(task).path
    }
    func prepare(_ original: URL, id: String, cancellation: WorkCancellation? = nil) throws -> (name: String, size: Int64, hash: String) {
        guard let name = fileName(original.lastPathComponent) else { throw FileFailure(code: "FILE_INVALID", message: "文件名包含不支持的字符") }
        let input = try openRegular(original)
        defer { close(input) }
        var before = stat(); guard fstat(input, &before) == 0 else { throw FileFailure.io }
        guard before.st_size >= 0, before.st_size <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_SIZE", message: "单文件不能超过128 MiB") }
        let directory = source(id).deletingLastPathComponent()
        try Self.directory(root.appendingPathComponent("Staging", isDirectory: true))
        try Self.directory(directory)
        let temporary = directory.appendingPathComponent(".source.partial")
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw FileFailure.io }
        var finished = false
        defer { close(output); if !finished { _ = unlink(temporary.path) } }
        var hasher = SHA256(); var total: Int64 = 0
        while true {
            try cancellation?.check()
            let data = try readBlock(input, limit: 65_536)
            if data.isEmpty { break }
            total += Int64(data.count)
            guard total <= FILE_MAX_SIZE else { throw FileFailure(code: "FILE_SIZE", message: "文件超过大小限制") }
            try writeBlock(output, data); hasher.update(data: data)
        }
        var after = stat()
        guard fstat(input, &after) == 0, total == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileFailure(code: "FILE_IO", message: "复制时源文件发生变化，请重新选择")
        }
        guard fsync(output) == 0, fchmod(output, 0o400) == 0, rename(temporary.path, source(id).path) == 0 else { throw FileFailure.io }
        try synchronizeDirectory(directory)
        finished = true
        return (name, total, hex(Data(hasher.finalize())))
    }
    /// 公共成品只读核验，必须在应用私有根之外，绝不将另一个内部副本当作用户导出。
    func independentExportMatches(_ url: URL, task: FileTask) -> Bool {
        guard let raw = realpath(url.path, nil) else { return false }; defer { free(raw) }
        guard let rootRaw = realpath(root.path, nil) else { return false }; defer { free(rootRaw) }
        let canonical = String(cString: raw), privateRoot = String(cString: rootRaw)
        guard canonical != privateRoot, !canonical.hasPrefix(privateRoot + "/") else { return false }
        return matches(url, task: task)
    }
    func matches(_ url: URL, task: FileTask) -> Bool {
        do { return try hashFile(url, expectedSize: task.size) == task.sha256 } catch { return false }
    }
    /// committing 日志先于移动；重启仅恢复同一个受控目标，不产生第二份文件。
    func recoverCommit(_ task: FileTask) throws {
        try ensureReceived(task)
        if try recoveryMatches(final(task), task: task) {
            // 上次可能刚rename便崩溃；恢复收据前仍必须同步目录项。
            try synchronizeDirectory(receivedDirectory(task.id))
            return
        }
        guard try recoveryMatches(partial(task), task: task) else { throw FileFailure(code: "FILE_HASH", message: "未能恢复已校验的接收文件") }
        try commit(task)
    }
    /// 恢复不能将权限/EIO当内容损坏；只有确实缺失或大小/hash不符才允许失败清理。
    func recoveryMatches(_ url: URL, task: FileTask) throws -> Bool {
        var entry = stat()
        if lstat(url.path, &entry) != 0 {
            if errno == ENOENT { return false }
            throw FileFailure.io
        }
        guard entry.st_mode & S_IFMT == S_IFREG else { throw FileFailure.io }
        if entry.st_size != task.size { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw FileFailure.io
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { throw FileFailure.io }
        if opened.st_size != task.size { return false }
        var hash = SHA256(); var total: Int64 = 0
        while true {
            let data = try readBlock(fd, limit: 65_536)
            if data.isEmpty { break }
            total += Int64(data.count)
            if total > task.size { return false }
            hash.update(data: data)
        }
        return total == task.size && hex(Data(hash.finalize())) == task.sha256
    }
    func commit(_ task: FileTask) throws {
        guard rename(partial(task).path, final(task).path) == 0 else { throw FileFailure.io }
        try synchronizeDirectory(receivedDirectory(task.id))
    }
    func export(_ task: FileTask, to destination: URL, replace: Bool) throws {
        let input = try openRegular(task.direction == .incoming ? final(task) : source(task.id))
        defer { close(input) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".xuqiao-export-" + UUID().uuidString)
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw FileFailure.io }
        defer { close(output); _ = unlink(temporary.path) }
        var hasher = SHA256(); var count: Int64 = 0
        while true {
            let data = try readBlock(input, limit: 65_536)
            if data.isEmpty { break }; count += Int64(data.count)
            guard count <= task.size else { throw FileFailure(code: "FILE_SIZE", message: "本地文件已改变，无法导出") }
            try writeBlock(output, data); hasher.update(data: data)
        }
        guard count == task.size, hex(Data(hasher.finalize())) == task.sha256 else { throw FileFailure(code: "FILE_HASH", message: "本地文件校验失败，无法导出") }
        guard fsync(output) == 0 else { throw FileFailure.io }
        if replace {
            var current = stat()
            if lstat(destination.path, &current) == 0, current.st_mode & S_IFMT != S_IFREG { throw FileFailure.io }
            guard rename(temporary.path, destination.path) == 0 else { throw FileFailure.io }
        } else {
            // 未经保存面板授权替换时，用 link 保证目标竞态出现也不会静默覆盖。
            guard link(temporary.path, destination.path) == 0 else { throw FileFailure(code: "FILE_IO", message: "保存位置已存在同名文件，请重新选择") }
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }
}
func openRegular(_ url: URL) throws -> Int32 {
    var entry = stat()
    if lstat(url.path, &entry) == 0, entry.st_mode & S_IFMT != S_IFREG {
        throw FileFailure(code: "FILE_INVALID", message: "仅支持普通文件，不支持目录或符号链接")
    }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw FileFailure(code: "FILE_NOT_FOUND", message: "无法打开普通文件，请重新选择") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw FileFailure(code: "FILE_INVALID", message: "仅支持普通文件，不支持目录或符号链接") }
    return fd
}
func readBlock(_ fd: Int32, limit: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: limit)
    var count: Int
    repeat { count = read(fd, &bytes, limit) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw FileFailure.io }
    return Data(bytes.prefix(count))
}
func writeBlock(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < data.count {
            let n = write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw FileFailure.io }; offset += n
        }
    }
}
func hashFile(_ url: URL, expectedSize: Int64) throws -> String {
    let fd = try openRegular(url); defer { close(fd) }
    var info = stat(); guard fstat(fd, &info) == 0, info.st_size == expectedSize else { throw FileFailure(code: "FILE_SIZE", message: "本地文件大小不匹配") }
    var hash = SHA256(); var total: Int64 = 0
    while true {
        let data = try readBlock(fd, limit: 65_536); if data.isEmpty { break }
        total += Int64(data.count); guard total <= expectedSize else { throw FileFailure.io }; hash.update(data: data)
    }
    guard total == expectedSize else { throw FileFailure.io }
    return hex(Data(hash.finalize()))
}
func synchronizeDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw FileFailure.io }; defer { close(fd) }
    guard fsync(fd) == 0 else { throw FileFailure.io }
}
final class IncomingFileStream {
    let fd: Int32
    var hash = SHA256()
    init(url: URL) throws {
        fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.io }
    }
    private var closed = false
    func append(_ data: Data) throws { try writeBlock(fd, data); hash.update(data: data) }
    func finish() throws -> String {
        guard !closed, fsync(fd) == 0 else { throw FileFailure.io }
        close(fd); closed = true; return hex(Data(hash.finalize()))
    }
    func abort() { if !closed { close(fd); closed = true } }
    deinit { abort() }
}
final class OutgoingFileStream {
    let fd: Int32
    init(url: URL, size: Int64) throws {
        fd = try openRegular(url)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size else { close(fd); throw FileFailure.io }
    }
    deinit { close(fd) }
}
