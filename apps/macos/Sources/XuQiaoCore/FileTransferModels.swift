import Foundation
import CoreFoundation

public enum FileTaskDirection: String, Codable { case outgoing, incoming }
public enum FileTaskState: String, Codable {
    case queued, waitingConnection, waitingAcceptance, awaitingUser, awaitingData, transferring, verifying, committing
    case completed, failed, cancelled, rejected, interrupted
    public var terminal: Bool { [.completed, .failed, .cancelled, .rejected, .interrupted].contains(self) }
    public var title: String {
        switch self {
        case .queued: "排队中"
        case .waitingConnection: "等待连接"
        case .waitingAcceptance: "等待对方接收"
        case .awaitingUser: "等待接收确认"
        case .awaitingData: "等待传输通道"
        case .transferring: "正在传输"
        case .verifying: "正在校验"
        case .committing: "正在可靠保存"
        case .completed: "已完成"
        case .failed: "传输失败"
        case .cancelled: "已取消"
        case .rejected: "已拒绝"
        case .interrupted: "传输已中断"
        }
    }
}
public struct FileTaskView: Identifiable, Codable {
    public let id: String
    public let peerId: String
    public let direction: FileTaskDirection
    public let name: String
    public let size: Int64
    public let sha256: String
    public let state: FileTaskState
    public let progress: Int64
    public let attemptId: String
    public let error: String?
    public var mediaRequestId: String?
    public var clipboardRecordId: String?
    public var clipboardSourceDeviceId: String?
    public var clipboardPrivateOnly = false
    public var privateCacheBytes: Int64 = 0
    public var privateOriginalCleared = false
    public var clipboardRequestId: String?
    public var imagePreview: FileOfferImagePreview?
    public var kind = "file"
    public var historyHidden = false
    // 剪贴板资源复用传输引擎，但其进行中和历史均只由剪贴板页面呈现。
    public var isFileTransferRecord: Bool { !historyHidden && clipboardRecordId == nil }
    public var managementBusy = false
    public var groupHash: String?
    public var entryCount: Int?
    public var totalBytes: Int64?
    public var roots: [String] = []
    public var entries: [GroupEntry] = []
    public var receivedSaveState: String?
    public var receivedSaveError: String?
    public var isOrdinaryReceivedFile: Bool { direction == .incoming && clipboardRecordId == nil && mediaRequestId == nil }
}
public struct FileTransferSnapshot {
    public var noticeRevision: UInt64 = 0
    public var tasks: [FileTaskView] = []
    /// 仅普通文件的当前确认请求，界面无需为接收事件扫描完整历史。
    public var pendingReceives: [FileTaskView] = []
    public var preparingPeerIds: [String] = []
    public var error: String?
    public var preparations: [FilePreparationView] = []
    public var batchExport: BatchExportView?
    public var receiveFolderPath: String?
    public init() {}
    /// 正在传输和剪贴板缓存不占用选择入口；仅当前前台准备防重，并为普通未结束任务设总上限。
    public func canPrepareSend(peerID: String, excludingTaskID: String? = nil) -> Bool {
        !preparingPeerIds.contains(peerID) && tasks.filter {
            $0.peerId == peerID && $0.id != excludingTaskID && $0.clipboardRecordId == nil && !$0.state.terminal
        }.count < FILE_PENDING_LIMIT
    }
}
struct FileTask: Codable {
    var id: String
    var peerId: String
    var direction: FileTaskDirection
    var name: String
    var size: Int64
    var sha256: String
    var sourcePath: String
    var destinationPath: String
    var state: FileTaskState
    var progress: Int64
    var attemptId: String
    var updatedAt: Date
    var error: String?
    var group: GroupMetadata? = nil
    var clipboard: ClipboardBinding? = nil
    var media: MediaBinding? = nil
    var imagePreview: FileOfferImagePreview? = nil
    var receivedSave: ReceivedFileSaveReceipt? = nil
    var ordinaryIncoming: Bool { direction == .incoming && clipboard == nil && media == nil }
    var view: FileTaskView {
        var value = FileTaskView(id: id, peerId: peerId, direction: direction, name: name, size: size, sha256: sha256,
                                 state: state, progress: progress, attemptId: attemptId, error: error)
        value.mediaRequestId = media?.requestId
        value.imagePreview = imagePreview
        value.receivedSaveState = receivedSave?.state.rawValue
        value.receivedSaveError = receivedSave?.error
        if let clipboard { value.clipboardRecordId = clipboard.recordId; value.clipboardSourceDeviceId = clipboard.sourceDeviceId; value.clipboardRequestId = clipboard.downloadRequestId; value.clipboardPrivateOnly = clipboard.privateOnly == true }
        if let group {
            value.kind = "group"; value.groupHash = group.groupHash; value.entryCount = group.entryCount
            value.totalBytes = group.totalBytes; value.roots = group.roots; value.entries = group.entries
        }
        return value
    }
    var wireFields: [String: Any] { ["taskId": id, "attemptId": attemptId] }
    var wireDirection: String { direction == .outgoing ? "download" : "upload" }
}
struct FileFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "\(code)：\(message)" }
    static let io = FileFailure(code: "FILE_IO", message: "无法读写文件，请检查存储空间和访问权限")
}
let FILE_MAX_SIZE: Int64 = 134_217_728
let FILE_CHUNK_SIZE = 16_384
func fileID(_ input: Any?) -> String? {
    guard let value = input as? String else { return nil }
    if validHex(value, count: 32) { return value }
    if value.count == 36, UUID(uuidString: value)?.uuidString.lowercased() == value { return value }
    return nil
}
func fileName(_ input: Any?) -> String? {
    guard let value = input as? String, (1...255).contains(value.utf8.count), value != ".", value != "..",
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || "/\\:".unicodeScalars.contains($0) }) else { return nil }
    return value
}
func fileInteger(_ input: Any?, maximum: Int64 = FILE_MAX_SIZE) -> Int64? {
    guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
          n.doubleValue >= 0, n.doubleValue <= Double(maximum), n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
    return n.int64Value
}
func fileMessage(_ type: String, task: FileTask, extra: [String: Any] = [:]) -> [String: Any] {
    wire(type, task.wireFields.merging(extra) { _, new in new })
}

public struct FilePreparationView: Identifiable {
    public let id: String
    public let peerId: String
}
public struct FileTaskSelection: Codable {
    public let id: String
    public let attemptId: String
    public init(id: String, attemptId: String) { self.id = id; self.attemptId = attemptId }
}
public struct BatchExportItem: Codable, Identifiable {
    public let id: String
    public let name: String
    public let state: String
    public let savedRoots: Int
    public let message: String
}
public struct BatchExportView: Identifiable, Codable {
    public let id: String
    public var state: String
    public let total: Int
    public var completed: Int
    public var failed: Int
    public var cancelled: Bool
    public var message: String
    public var items: [BatchExportItem]
}
