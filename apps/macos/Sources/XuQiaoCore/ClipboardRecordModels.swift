import Foundation
import UniformTypeIdentifiers

let CLIPBOARD_MAX_PIXEL_COUNT: Int64 = 32_000_000
let CLIPBOARD_HISTORY_LIMIT = 1000
struct ClipboardContent: Codable, Equatable {
    var recordId: String
    var sourceDeviceId: String
    var capturedAt: Int64
    var kind: String
    var name: String
    var size: Int64
    var sha256: String
    var data = ""
    var totalBytes: Int64 = 0
    var groupHash = ""
    var entryCount = 0
    var roots: [String] = []
    var imageWidth = 0
    var imageHeight = 0
    var mimeType = ""
    var key: String { sourceDeviceId + ":" + recordId }
    var text: String? {
        guard kind == "text", let bytes = Data(base64Encoded: data) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    var group: GroupMetadata? {
        ["folder", "group"].contains(kind) ? GroupMetadata(groupHash: groupHash, entryCount: entryCount, totalBytes: totalBytes, roots: roots, entries: []) : nil
    }
    var object: [String: Any] {
        ["recordId": recordId, "sourceDeviceId": sourceDeviceId, "capturedAt": capturedAt, "kind": kind, "name": name,
         "size": size, "sha256": sha256, "data": data, "totalBytes": totalBytes, "groupHash": groupHash,
         "entryCount": entryCount, "roots": roots, "imageWidth": imageWidth, "imageHeight": imageHeight, "mimeType": mimeType]
    }
    func same(_ other: ClipboardContent) -> Bool {
        // String的规范等价比较不能代替原UTF8内容/文件名一致性。
        (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) == (try? JSONSerialization.data(withJSONObject: other.object, options: .sortedKeys))
    }
    /// 仅供本机连续捕获比较；远端同ID的不可变字段仍由same严格验证。
    func sameCapture(_ other: ClipboardContent) -> Bool {
        guard kind == other.kind, name.utf8.elementsEqual(other.name.utf8), mimeType == other.mimeType,
              imageWidth == other.imageWidth, imageHeight == other.imageHeight else { return false }
        if let group {
            // ZIP携带准备期信息，归档SHA/大小不是文件组内容身份。
            return other.group.map { group.sameSummary($0) } ?? false
        }
        return size == other.size && sha256 == other.sha256 && data.utf8.elementsEqual(other.data.utf8)
    }
    static func parse(_ fields: [String: Any]) throws -> ClipboardContent {
        guard let id = fields["recordId"] as? String, validHex(id, count: 32), let source = validIdentifier(fields["sourceDeviceId"]),
              let captured = clipInteger(fields["capturedAt"]), let kind = fields["kind"] as? String,
              ["text", "image", "file", "folder", "group"].contains(kind), let name = fields["name"] as? String,
              let size = fileInteger(fields["size"]), let sha = fields["sha256"] as? String, validHex(sha),
              let data = fields["data"] as? String, let total = fileInteger(fields["totalBytes"]),
              let groupHash = fields["groupHash"] as? String, let entries = fileInteger(fields["entryCount"], maximum: 1024),
              let roots = fields["roots"] as? [String], let width = fileInteger(fields["imageWidth"], maximum: CLIPBOARD_MAX_PIXEL_COUNT),
              let height = fileInteger(fields["imageHeight"], maximum: CLIPBOARD_MAX_PIXEL_COUNT), let mime = fields["mimeType"] as? String else { throw ClipboardFailure.invalid }
        let result = ClipboardContent(recordId: id, sourceDeviceId: source, capturedAt: captured, kind: kind, name: name, size: size, sha256: sha, data: data,
            totalBytes: total, groupHash: groupHash, entryCount: Int(entries), roots: roots, imageWidth: Int(width), imageHeight: Int(height), mimeType: mime)
        if kind == "text" {
            guard name.isEmpty, mime == "text/plain", data.utf8.count <= 21_848, let bytes = Data(base64Encoded: data),
                  bytes.base64EncodedString() == data, (1...clipboardLimit).contains(bytes.count), !bytes.contains(0), Int64(bytes.count) == size,
                  Data(String(decoding: bytes, as: UTF8.self).utf8) == bytes, digest(bytes) == sha else { throw ClipboardFailure.invalid }
        } else { guard data.isEmpty, fileName(name) != nil else { throw ClipboardFailure.invalid } }
        if ["folder", "group"].contains(kind) {
            var summary = fields; summary["kind"] = "group"
            guard mime == "application/zip", width == 0, height == 0, let group = try GroupMetadata.parse(summary),
                  kind == "folder" ? (group.roots.count == 1 && name.utf8.elementsEqual(group.roots[0].utf8)) : name == "文件组" else { throw ClipboardFailure.invalid }
        } else { guard total == 0, groupHash.isEmpty, entries == 0, roots.isEmpty else { throw ClipboardFailure.invalid } }
        if kind == "image" {
            guard size > 0, width > 0, height > 0, width <= CLIPBOARD_MAX_PIXEL_COUNT / height, mime.hasPrefix("image/"), mime.utf8.count <= 128, UTType(mimeType: mime)?.conforms(to: .image) == true else { throw ClipboardFailure.invalid }
        } else { guard width == 0, height == 0 else { throw ClipboardFailure.invalid } }
        if kind == "file" { guard mime == "application/octet-stream" else { throw ClipboardFailure.invalid } }
        return result
    }
    func matchesFile(name: String, size: Int64, sha: String, group: GroupMetadata?) -> Bool {
        guard self.name.utf8.elementsEqual(name.utf8), self.size == size, sha256 == sha else { return false }
        if let expected = self.group { return group.map { expected.sameSummary($0) } ?? false }
        return group == nil && kind != "text"
    }
}
struct ClipboardRecord {
    var seq: Int64 = 0
    var content: ClipboardContent
    var sourceName: String
    var receivedAt: Int64
    var available = true
    var availabilityVersion: Int64 = 0
    var cacheExpiresAt: Int64 = 0
    var localTaskId = ""
    var downloadState = "none"
    var error = ""
    var key: String { content.key }
    func wire(delivery: String, epoch: String, mode: String) -> [String: Any] {
        content.object.merging(["deliveryId": delivery, "receiverEpoch": epoch, "deliveryMode": mode, "available": available,
                                "availabilityVersion": availabilityVersion, "cacheExpiresAt": cacheExpiresAt]) { _, new in new }
    }
}
struct ClipboardGrant {
    var recordId: String
    var peerId: String
    var trustGeneration: String
    var announcedVersion: Int64 = -1
    var liveEpoch = ""
    var manual = false
}
struct ClipboardSnapshotIndex: Equatable {
    var recordId: String
    var relativePath: String
    var createdAt: Int64
    var expiresAt: Int64
    var byteSize: Int64
    var state = "ready"
}
struct ClipboardBinding: Codable, Equatable {
    var sourceDeviceId: String
    var recordId: String
    var downloadRequestId: String
    var trustGeneration: String
    // 仅本地持久化；缺省沿用旧版手动下载语义，不进入wire。
    var privateOnly: Bool? = nil
    var key: String { sourceDeviceId + ":" + recordId }
    var valid: Bool { validIdentifier(sourceDeviceId) != nil && validHex(recordId, count: 32) && validHex(downloadRequestId, count: 32) && !trustGeneration.isEmpty && trustGeneration.utf8.count <= 128 }
}
/// 仅供本机界面使用的已校验位置，不进入同步协议或记录数据库。
public struct ClipboardLocalResource {
    public var url: URL
    /// true表示同步快照，不可在界面伪称为用户最初复制的原始路径。
    public var isSnapshot: Bool
    // 资源值的所有副本释放后才归还lease；视频异步读取期间不能被缓存GC删除。
    private let lease: ClipboardLocalResourceLease?
    public init(url: URL, isSnapshot: Bool) { self.url = url; self.isSnapshot = isSnapshot; lease = nil }
    init(url: URL, isSnapshot: Bool, lease: ClipboardLocalResourceLease) { self.url = url; self.isSnapshot = isSnapshot; self.lease = lease }
}

final class ClipboardLocalResourceLease {
    private let release: () -> Void
    init(release: @escaping () -> Void) { self.release = release }
    deinit { release() }
}

public struct ClipboardRecordView: Identifiable {
    public var id: String { key }
    public var key: String
    public var recordId: String
    public var sourceDeviceId: String
    public var sourceName: String
    public var capturedAt: Int64
    public var receivedAt: Int64
    public var kind: String
    public var name: String
    public var size: Int64
    public var sha256: String
    public var available: Bool
    public var availabilityVersion: Int64
    public var cacheExpiresAt: Int64
    public var downloadState: String
    public var taskId: String
    public var originLocal: Bool
    public var groupHash: String
    public var entryCount: Int
    public var roots: [String]
    public var totalBytes: Int64
    public var imageWidth: Int
    public var imageHeight: Int
    public var sourceOnline: Bool
    public var preview: String
    public var error: String
    public var context: String
    public var progress: Double
    public var privateOriginal = false
    public var previewURL: URL? = nil
    public var previewState = "none"
    var metadata: [String: Any] {
        ["key": key, "recordId": recordId, "sourceDeviceId": sourceDeviceId, "sourceName": sourceName, "capturedAt": capturedAt, "receivedAt": receivedAt,
         "kind": kind, "name": name, "size": size, "sha256": sha256, "available": available, "availabilityVersion": availabilityVersion,
         "cacheExpiresAt": cacheExpiresAt, "downloadState": downloadState, "taskId": taskId, "originLocal": originLocal, "groupHash": groupHash,
         "entryCount": entryCount, "roots": roots, "totalBytes": totalBytes, "imageWidth": imageWidth, "imageHeight": imageHeight, "sourceOnline": sourceOnline, "previewState": previewState, "hasPreview": previewURL != nil, "privateOriginal": privateOriginal]
    }
}
public struct ClipboardCacheView {
    public var ttlSeconds: Int64 = 604800
    public var maxBytes: Int64 = 536870912
    public var bytes: Int64 = 0
    public var snapshotCount = 0
    public var expiredCount = 0
    public var activeLeases = 0
    public var historyCount = 0
    public var privateImageBytes: Int64 = 0
    public var privateImageCount = 0
    public var previewBytes: Int64 = 0
    public var previewCount = 0
    public init() {}
    var metadata: [String: Any] { ["ttlSeconds": ttlSeconds, "maxBytes": maxBytes, "bytes": bytes, "snapshotCount": snapshotCount, "expiredCount": expiredCount, "activeLeases": activeLeases, "historyCount": historyCount, "privateImageBytes": privateImageBytes, "privateImageCount": privateImageCount, "previewBytes": previewBytes, "previewCount": previewCount] }
}
struct ClipboardFailure: LocalizedError {
    var code: String
    var errorDescription: String? { clipboardErrorText(code) }
    static let invalid = ClipboardFailure(code: "CLIP_INVALID")
    static let io = ClipboardFailure(code: "CLIP_IO")
}
func clipInteger(_ value: Any?) -> Int64? { fileInteger(value, maximum: 9_007_199_254_740_991) }
