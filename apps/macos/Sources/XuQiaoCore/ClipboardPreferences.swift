import Foundation
import Darwin

public struct ClipboardPreferences: Codable, Equatable {
    public var version: Int
    public var enabled: Bool
    public var kinds: [String]
    public var autoApplyText: Bool
    public var previewsEnabled: Bool
    public init(version: Int = 3, enabled: Bool = true, kinds: [String] = ["text", "image", "file", "folder", "group"], autoApplyText: Bool = true, previewsEnabled: Bool = true) {
        self.version = version; self.enabled = enabled; self.kinds = kinds; self.autoApplyText = autoApplyText; self.previewsEnabled = previewsEnabled
    }
    private enum CodingKeys: String, CodingKey { case version, enabled, kinds, autoApplyText, previewsEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        enabled = try values.contains(.enabled) ? values.decode(Bool.self, forKey: .enabled) : true
        kinds = try values.contains(.kinds) ? values.decode([String].self, forKey: .kinds) : clipboardKinds
        autoApplyText = try values.contains(.autoApplyText) ? values.decode(Bool.self, forKey: .autoApplyText) : true
        previewsEnabled = try values.contains(.previewsEnabled) ? values.decode(Bool.self, forKey: .previewsEnabled) : true
        guard valid else { throw ClipboardFailure.invalid }
    }
    var valid: Bool { version == 3 && kinds.count <= 5 && Set(kinds).count == kinds.count && kinds.allSatisfy(clipboardKinds.contains) }
    static var disabled: ClipboardPreferences { ClipboardPreferences(enabled: false, kinds: [], autoApplyText: false, previewsEnabled: false) }
}
let clipboardKinds = ["text", "image", "file", "folder", "group"]

public struct ManagementResult {
    public var removed = 0
    public var keptActive = 0
    public var failed = 0
    public init(removed: Int = 0, keptActive: Int = 0, failed: Int = 0) { self.removed = removed; self.keptActive = keptActive; self.failed = failed }
}
struct ClipboardRemoteIntent: Codable {
    var syncEnabled: Bool
    var enabledKinds: [String]
}
private struct ClipboardPreferenceDocument: Codable {
    var preferences: ClipboardPreferences
    var remoteIntents: [String: ClipboardRemoteIntent]
}

/// 新v3空间只初始化一次；旧开发版v2关闭值不迁入，之后任何false/空类型均原样保留。
final class ClipboardPreferenceStore {
    private let root: URL
    private let url: URL
    private(set) var preferences = ClipboardPreferences.disabled
    private(set) var remoteIntents: [String: ClipboardRemoteIntent] = [:]
    private(set) var error: String?
    init(root: URL) {
        self.root = root; url = root.appendingPathComponent("ClipboardPreferences-v3.json")
        do {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if fd < 0 {
                guard errno == ENOENT else { throw ClipboardFailure.io }
                try save(ClipboardPreferences(), intents: [:]); return
            }
            defer { close(fd) }; var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 262_144 else { throw ClipboardFailure.io }
            let document = try JSONDecoder().decode(ClipboardPreferenceDocument.self, from: readBlock(fd, limit: 262_145))
            guard document.preferences.valid, document.remoteIntents.count <= 1000,
                  document.remoteIntents.values.allSatisfy({ $0.enabledKinds.count <= 5 && Set($0.enabledKinds).count == $0.enabledKinds.count && $0.enabledKinds.allSatisfy(clipboardKinds.contains) }) else { throw ClipboardFailure.invalid }
            preferences = document.preferences; remoteIntents = document.remoteIntents
        } catch { self.error = "同步设置读取失败，自动同步已暂停；请在设置中重新保存" }
    }
    /// 读取故障时远端意图仅随当前进程保留；不覆盖损坏原文，也不清除错误。
    /// 恢复持久化必须由用户在设置页显式保存，连接/移除信任不能替用户确认恢复。
    func updateRemoteIntents(_ value: [String: ClipboardRemoteIntent]) throws {
        guard error == nil else { remoteIntents = value; return }
        try save(preferences, intents: value)
    }
    func save(_ preferences: ClipboardPreferences, intents: [String: ClipboardRemoteIntent]? = nil) throws {
        guard preferences.valid else { throw ClipboardFailure.invalid }
        let next = intents ?? remoteIntents
        let bytes = try JSONEncoder().encode(ClipboardPreferenceDocument(preferences: preferences, remoteIntents: next))
        guard bytes.count <= 262_144 else { throw ClipboardFailure.io }
        let temporary = root.appendingPathComponent(".ClipboardPreferences-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ClipboardFailure.io }; defer { close(fd); unlink(temporary.path) }
        try writeBlock(fd, bytes); guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ClipboardFailure.io }
        try synchronizeDirectory(root)
        self.preferences = preferences; remoteIntents = next; error = nil
    }
}
