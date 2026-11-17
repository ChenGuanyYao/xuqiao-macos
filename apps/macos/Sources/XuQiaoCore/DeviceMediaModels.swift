import Foundation
import CoreGraphics

public struct MediaAssetView: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var size: Int64
    public var width: Int
    public var height: Int
    public var mimeType: String
    public var preview: Data?
}
/// 仅包含当前授权中的不透明ID和安全显示信息，不含远端路径。
public struct DirectoryEntryView: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Int64
    public var downloadable: Bool
}
public struct DirectoryCrumbView: Identifiable, Equatable {
    public var id: String
    public var name: String
}
public struct DeviceMediaView: Identifiable {
    public var id: String { peerId }
    public var peerId: String
    public var capable = false
    public var screenCapable = false
    public var albumCapable = false
    public var filesCapable = false
    public var browserQueryCapable = false
    public var albumQuery = ""
    public var albumSort = "newest"
    public var filesQuery = ""
    public var filesSort = "name"
    public var filesGrantId = ""
    public var filesState = "idle"
    public var filesMessage = "自动读取接收文件及已保存的授权范围"
    public var filesRootName = ""
    public var filesFolderId = ""
    public var filesOffset = 0
    public var filesTotal = 0
    public var filesSkippedCount = 0
    public var filesEntries: [DirectoryEntryView] = []
    public var filesBreadcrumbs: [DirectoryCrumbView] = []
    public var filesDownloading = ""
    public var filesQueuedDownloads = 0
    public var screenId = ""
    public var screenState = "idle"
    public var screenMessage = "在手机确认后开始投屏"
    public var decodedFrames = 0
    public var grantId = ""
    public var albumState = "idle"
    public var albumMessage = "图库授权后自动读取图片和视频"
    public var albumKind = "image"
    public var albumTotal = 0
    public var albumOffset = 0
    public var assets: [MediaAssetView] = []
    public var downloading = ""
    public var queuedDownloads = 0
    public init(peerId: String) { self.peerId = peerId }
}
struct MediaBinding: Codable, Equatable {
    let peerId: String
    let trustGeneration: String
    let controlId: String
    let grantId: String
    let assetId: String
    let requestId: String
    var valid: Bool { validIdentifier(peerId) != nil && !trustGeneration.isEmpty && UUID(uuidString: controlId) != nil && [grantId,assetId,requestId].allSatisfy { validHex($0,count:32) } }
}
/// 每个设备/信任域只保留最新图像或清除标记；主线程繁忙时替换旧图，不积累逐帧闭包。
public final class ScreenImageHub {
    private struct PendingImage { let image:CGImage?; let revision:UInt64 }
    private let lock = NSLock()
    private var observers: [UUID: (String, (CGImage?) -> Void)] = [:]
    private var pending: [String:PendingImage] = [:]
    private var revisions: [String:UInt64] = [:]
    private var drainScheduled = false
    public init() {}
    @discardableResult public func observe(peerId: String, trustGeneration: String, _ callback: @escaping (CGImage?) -> Void) -> UUID {
        let id = UUID(); lock.lock(); observers[id] = (peerId+"|"+trustGeneration,callback); lock.unlock(); return id
    }
    public func remove(_ id: UUID) {
        lock.lock()
        if let removed=observers.removeValue(forKey:id),!observers.values.contains(where:{$0.0==removed.0}) {
            pending.removeValue(forKey:removed.0);revisions.removeValue(forKey:removed.0)
        }
        lock.unlock()
    }
    func publish(peerId: String, generation: String, image: CGImage?) {
        let key=peerId+"|"+generation
        lock.lock()
        guard observers.values.contains(where:{$0.0==key}) else {
            pending.removeValue(forKey:key);revisions.removeValue(forKey:key);lock.unlock();return
        }
        let revision=(revisions[key] ?? 0) &+ 1
        revisions[key]=revision;pending[key]=PendingImage(image:image,revision:revision)
        let schedule = !drainScheduled
        if schedule {drainScheduled=true}
        lock.unlock()
        // 队列闭包不捕获像素，只持有hub的弱引用，最多有一个待执行的drain。
        if schedule {DispatchQueue.main.async{[weak self] in self?.drain()}}
    }
    private func drain() {
        lock.lock()
        let batch=pending;pending.removeAll()
        let deliveries=observers.compactMap { id,value in batch[value.0].map{(id,value.0,$0)} }
        lock.unlock()
        for (id,key,item) in deliveries {
            // 执行前重新核对订阅与版本，已移除订阅、较新的清除/图像不能被旧批次覆盖。
            lock.lock()
            let callback = revisions[key]==item.revision && observers[id]?.0==key ? observers[id]?.1:nil
            lock.unlock()
            callback?(item.image)
        }
        lock.lock()
        let again = !pending.isEmpty
        if !again {drainScheduled=false}
        lock.unlock()
        if again {DispatchQueue.main.async{[weak self] in self?.drain()}}
    }
}
