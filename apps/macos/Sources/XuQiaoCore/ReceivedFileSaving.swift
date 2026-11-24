import Foundation
import Darwin

enum ReceivedFileSaveState: String, Codable { case pending, saving, saved, failed }

/// 书签只保存在本机设置/任务库，不进入协议或界面快照。
struct ReceiveFolderLocation: Codable, Equatable {
    static let preferenceKey = "files.receiveFolder.v1"
    var path: String
    var bookmark: Data?
    var createsDirectory: Bool

    static func load(defaults: UserDefaults = .standard) throws -> ReceiveFolderLocation {
        if let data = defaults.data(forKey: preferenceKey) {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.valid else { throw FileFailure.io }; return value
        }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw FileFailure.io }
        return Self(path: downloads.appendingPathComponent("续桥", isDirectory: true).path, createsDirectory: true)
    }
    static func selected(_ url: URL) throws -> ReceiveFolderLocation {
        guard url.isFileURL else { throw FileFailure.io }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return Self(path: url.standardizedFileURL.path, bookmark: bookmark, createsDirectory: false)
    }
    var valid: Bool { path.hasPrefix("/") && !path.utf8.contains(0) && (bookmark?.count ?? 0) <= 65_536 }
    func persist(defaults: UserDefaults = .standard) throws { guard valid else { throw FileFailure.io }; defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey) }
}

final class ReceiveFolderAccess {
    let url: URL
    let location: ReceiveFolderLocation
    private let scoped: Bool
    init(_ requested: ReceiveFolderLocation, create: Bool) throws {
        guard requested.valid else { throw FileFailure.io }
        var value = requested
        let resolved: URL
        if let data = requested.bookmark {
            var stale = false
            resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = resolved.startAccessingSecurityScopedResource()
            do {
                if stale { value.bookmark = try resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
            } catch { if started { resolved.stopAccessingSecurityScopedResource() }; throw error }
            scoped = started
        } else { resolved = URL(fileURLWithPath: requested.path, isDirectory: true); scoped = false }
        url = resolved; value.path = resolved.path; location = value
        // 全部属性已初始化，后续抛错也会执行 deinit；授权只在析构时释放一次。
        if create && requested.createsDirectory { try FileStorage.directory(resolved, intermediate: true) }
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FileFailure.io }
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct ReceivedFileSaveReceipt: Codable {
    var attempt: String
    var state: ReceivedFileSaveState = .pending
    var folder: ReceiveFolderLocation?
    var roots: [String] = []
    var error: String?
    var valid: Bool {
        fileID(attempt) != nil && roots.count <= 100 && roots.allSatisfy { fileName($0) != nil } &&
        Set(roots).count == roots.count && (folder?.valid ?? true) &&
        (state != .saved || folder != nil && !roots.isEmpty)
    }
}
